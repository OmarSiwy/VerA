//! Builds `vera` (src/main.zig), the `module_specs` module graph an embedder
//! imports, one test artifact per module, and the suite steps, which all run
//! tests/bench.zig with the built `vera` path and the passthru args.
//!
//! Anything whose input is `vera`'s output (generated devices, transcripts,
//! VPI applications) is spawned by the suite runner, not modelled as artifacts,
//! except the `host_tests` devices, which a test artifact imports.

const std = @import("std");

const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8 = &.{},
    /// A C file compiled into the module, against the headers in its directory.
    c: ?[]const u8 = null,
};

/// The module graph in dependency order: a module may import only ones
/// declared above it, and `defineModules` panics otherwise.
const module_specs = [_]ModuleSpec{
    .{ .name = "contract", .path = "tools/contract.zig" },

    // lib/ — the compiler. `vera` is its facade and what an embedder takes.
    .{ .name = "diag", .path = "lib/diag.zig" },
    // Opening an `--emit-so` artifact: the one OS-bound file (its header).
    .{ .name = "dynlib", .path = "lib/dynlib.zig" },
    // `contract`: the compile-time folds and the prover's bounds use the
    // devices' exp/log/pow (`contract.gm`), so a folded constant is the bits
    // the device would compute (§9.14: `$exp` and `exp` are one function).
    .{ .name = "frontend", .path = "lib/frontend/root.zig", .imports = &.{ "diag", "contract" } },
    .{ .name = "kernels", .path = "lib/backend/kernels.zig", .imports = &.{"contract"} },
    .{ .name = "ir", .path = "lib/ir/root.zig", .imports = &.{ "diag", "frontend", "kernels", "contract" } },
    .{ .name = "backend", .path = "lib/backend/root.zig", .imports = &.{ "diag", "dynlib", "frontend", "ir", "kernels" } },
    .{ .name = "vera", .path = "lib/root.zig", .imports = &.{ "diag", "frontend", "ir", "backend", "kernels" } },

    // src/: what runs after compilation. `sim` is an interpreter over the
    // shared AST, not a consumer of the pipeline. It takes `kernels` so the
    // §9.4.3 real conversion and §17.2 file I/O match the analog devices
    // (`contract.FileIo`, LRM §9.5.1.2).
    .{ .name = "sim", .path = "src/sim/root.zig", .imports = &.{ "contract", "diag", "frontend", "kernels" } },
    // `c`: the variadic routines, which Zig cannot define on every target.
    .{ .name = "vpi", .path = "src/vpi/root.zig", .imports = &.{ "frontend", "ir", "vera", "sim" }, .c = "src/vpi/varargs.c" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mods = defineModules(b, target, true);

    // `verilog` is an IEEE 1364-2005 tool: default `--std=1364-2005`, and the
    // analog pipeline (lowering, codegen, tb, orchestrator) is never analysed,
    // so it is not in the binary. The module graph is the same either way.
    const Language = enum { verilog, ams };
    const language = b.option(Language, "language", "verilog: an IEEE 1364-2005 `vera` without the analog backend; ams (default): the Verilog-AMS compiler") orelse .ams;
    const exe = cliExe(b, target, optimize, mods, "vera", language == .ams);
    b.installArtifact(exe);
    // The ABI a host's `dyn` module and device driver compile against.
    b.installFile("tools/contract.zig", "share/vera/contract.zig");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the vera CLI").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run every test suite");
    // The cross-platform gate: every artifact `test` builds, compiled for
    // `-Dtarget` and run nowhere, since a foreign binary cannot run here. Its
    // generated devices come from `gen_exe`, a `vera` for the build host.
    const all_step = b.step("build-all", "Compile every artifact for -Dtarget without running one");
    all_step.dependOn(&exe.step);
    const gen_exe = if (target.query.isNative()) exe else cliExe(b, b.graph.host, optimize, defineModules(b, b.graph.host, false), "vera-gen", true);

    const fmt = b.addFmt(.{
        .paths = b.pathList(&.{ "lib", "src", "tests", "tools", "build.zig" }),
        .check = true,
    });
    b.step("fmt-check", "Fail on any file `zig fmt` would change").dependOn(&fmt.step);
    test_step.dependOn(&fmt.step);

    // One test artifact per module: `zig test` collects tests only from the
    // root module's own file set, so a cross-module `_ = @import(...)`
    // contributes none. Each also gets a step, so `zig build test-ir` runs
    // without building the backend.
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("tools/zrunner.zig"),
        .mode = .simple,
    };
    for (mods) |m| {
        const r = testRun(b, m.name, m.module, runner);
        test_step.dependOn(r);
        b.step(b.fmt("test-{s}", .{m.name}), b.fmt("Run the {s} module tests only", .{m.name}))
            .dependOn(r);
    }
    // The CLI has no tests, so `test` depends on the executable compiling, in
    // both languages since only main.zig reads the option. A test artifact over
    // main.zig would analyse nothing.
    test_step.dependOn(&exe.step);
    const other_exe = cliExe(b, target, optimize, mods, if (language == .ams) "vera-verilog" else "vera-ams", language != .ams);
    test_step.dependOn(&other_exe.step);
    all_step.dependOn(&other_exe.step);
    // `tests/test_all.zig` is the one compilation that has every module at once,
    // and it owns the claims that span two of them.
    const all_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = mods,
    });
    // `tests/exhaustive.zig` reads `lib/` and `src/` as source at test time,
    // from whatever cwd `zig build` was typed in, so the path is absolute.
    // Those reads are invisible to the cache, so the run is never cached: a
    // new file with an OS call does not change the test binary.
    const repo = b.addOptions();
    repo.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    all_mod.addOptions("repo_options", repo);
    const all_run: *std.Build.Step.Run = @fieldParentPtr("step", testRun(b, "test_all", all_mod, runner));
    all_run.has_side_effects = true;
    test_step.dependOn(&all_run.step);

    // The suite runner's options are only the absolute paths it cannot compute
    // itself; defaults (the foreign compiler's command line, the fixture
    // optimize mode) are constants in the runner. Fixing the fixture and LRM
    // roots here keeps every runner grading the same suite.
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", pathFromRoot(b, "tests/fixtures"));
    o.addOption([]const u8, "repo_root", pathFromRoot(b, "."));
    o.addOption([]const u8, "docs_root", pathFromRoot(b, "docs"));
    o.addOption([]const u8, "work_root", pathFromRoot(b, ".zig-cache/vera-suite"));
    o.addOption([]const u8, "contract", pathFromRoot(b, "tools/contract.zig"));
    // The `.c` fixtures compile against the shipped header, not a copy.
    o.addOption([]const u8, "vpi_include", pathFromRoot(b, "src/vpi"));
    // `--coverage` counts a `.c` fixture's `//! lrm` tags only for those in
    // `vpi_runs`, since compiling is not runtime evidence.
    o.addOption([]const []const u8, "vpi_runs", &vpi_run_paths);
    o.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    const suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vera", .module = byName(mods, "vera") },
        },
    });
    suite_mod.addOptions("suite_options", o);
    // An executable, not a `test` block, so one run prints every failing
    // fixture instead of stopping at the first. Its own unit tests (assertion
    // lint, verdict tally, emitted-size table) do go on `test`.
    const suite_exe = b.addExecutable(.{ .name = "vera-suite", .root_module = suite_mod });
    all_step.dependOn(&suite_exe.step);
    test_step.dependOn(testRun(b, "suite", suite_mod, runner));

    // The suite step: the runner takes the `vera` path, then whatever follows
    // `--`.
    const bench = b.addRunArtifact(suite_exe);
    bench.addArtifactArg2(exe, .{});
    bench.addPassthruArgs();
    b.step(
        "benchmark",
        "Run every fixture through VerA — compile, build, run, judge — and time it " ++
            "(USE -Doptimize=ReleaseFast: " ++
            "that is the shipping number, and the default Debug is several times slower)",
    ).dependOn(&bench.step);

    // `vera --run` over every `.v` under `tests/fixtures/ieee1364/` and
    // `tests/fixtures/digital/` with a committed transcript beside it.
    // `addArtifactArg2` makes the built `vera` a dependency of this run.
    //
    // Not on `test`: `test` is the fast gate that must be green, and the suite
    // is where unimplemented behaviour is counted.
    //
    // No `expectExitCode`: a Run step with a stdio check becomes cacheable, and
    // its real inputs (the `.v` sources and transcripts) are read at run time,
    // invisible to the build graph, so a cached pass would compare nothing.
    const dev = b.addRunArtifact(suite_exe);
    dev.addArtifactArg2(exe, .{});
    dev.addArg("devices");
    dev.addPassthruArgs();
    b.step("test-devices", "Run `vera --run` over ieee1364/ and digital/ and diff their transcripts")
        .dependOn(&dev.step);

    // The two suites by language. `test-1364` is `tests/fixtures/ieee1364/`
    // alone (`-- --coverage` prints its clause inventory instead); `test-ams`
    // is `benchmark -- --strict`.
    const v1364 = b.addRunArtifact(suite_exe);
    v1364.addArtifactArg2(exe, .{});
    v1364.addArg("ieee1364");
    v1364.addPassthruArgs();
    b.step("test-1364", "Run the IEEE 1364-2005 transcript suite (`-- --coverage`: its clause inventory; `-- --native`: through `vera --emit-exe`)")
        .dependOn(&v1364.step);
    const ams = b.addRunArtifact(suite_exe);
    ams.addArtifactArg2(exe, .{});
    ams.addArg("--strict");
    ams.addPassthruArgs();
    b.step("test-ams", "Run the Verilog-AMS fixture suite strictly (= `benchmark -- --strict`)")
        .dependOn(&ams.step);

    // Every `.c` VPI fixture, compiled by a C compiler against
    // `src/vpi/vpi_user.h` (LRM clauses 11 and 12) with a census reported; the
    // ones that also run are `vpi_runs`, under `test`. No `expectExitCode`,
    // for the cacheability reason `test-devices` gives.
    const vpi_fx = b.addRunArtifact(suite_exe);
    vpi_fx.addArtifactArg2(exe, .{});
    vpi_fx.addArg("vpi");
    b.step("test-vpi-fixtures", "Compile the .c VPI fixtures against src/vpi/vpi_user.h")
        .dependOn(&vpi_fx.step);

    // The `.sp` decks: SPICE netlists naming models through `.hdl`, each
    // paired with an `.expected.json` analytic oracle. The step checks the
    // oracle exists and every named model resolves and compiles, then runs
    // each deck on `sim.spice`, ESPice's solver (`//! tran`, `//! onoise`), and grades
    // it against the oracle; a deck needing what the runner lacks is NOT RUN.
    const spice = b.addRunArtifact(suite_exe);
    spice.addArtifactArg2(exe, .{});
    spice.addArg("spice");
    b.step("test-spice", "Run the .sp decks on sim.spice and grade each against its oracle")
        .dependOn(&spice.step);

    // What vera says about every fixture, snapshotted so a refactor phase can
    // prove it changed nothing (AGENTS.md §4): `-- before`, `-- after`, then
    // `-- diff`. No check on the step, for the cacheability reason
    // `test-devices` gives: the fixtures are read at run time.
    const golden = b.addRunArtifact(suite_exe);
    golden.addArtifactArg2(exe, .{});
    golden.addArg("golden");
    golden.addPassthruArgs();
    b.step("golden", "Snapshot `vera --emit-zig` on every fixture (`-- <tag>`), or compare two (`-- diff [a b]`)")
        .dependOn(&golden.step);

    // docs/UNITS.md and the architecture map in AGENTS.md, read from the code.
    const map = b.addRunArtifact(suite_exe);
    map.addArtifactArg2(exe, .{});
    map.addArg("archmap");
    map.addPassthruArgs();
    b.step("archmap", "Regenerate docs/UNITS.md and the AGENTS.md architecture map (`-- <file.md>`: another file)")
        .dependOn(&map.step);

    // The VPI acceptance test. A VPI implementation is only tested from C:
    // `tests/fixtures/ch11_vpi/vpi_app.c` compiles against `src/vpi/vpi_user.h`, so every constant
    // it names is the header's number, and links against the `export fn`s in
    // `src/vpi/root.zig`, which puts the ABI itself under test.
    // `tests/vpi_host.zig` is the simulator half; it calls the application's
    // `vlog_startup_routines` (LRM §12.33.2).
    //
    // The host is built once, as a static library exporting C's `main`, and
    // each application links against it, so the engine compiles once. The
    // options say where an analog application's device library is built
    // (`vera.tb.renderVpiLib`) and with what; the host runs with the cache as
    // its cwd, so every path is absolute.
    const host_opts = b.addOptions();
    host_opts.addOption([]const u8, "contract", pathFromRoot(b, "tools/contract.zig"));
    host_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    host_opts.addOption([]const u8, "work_root", pathFromRoot(b, ".zig-cache/vera-vpi"));
    const vpi_host = b.addLibrary(.{
        .name = "vera-vpi-host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vpi_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vera", .module = byName(mods, "vera") },
                .{ .name = "vpi", .module = byName(mods, "vpi") },
                .{ .name = "sim", .module = byName(mods, "sim") },
                .{ .name = "vpi_host_options", .module = host_opts.createModule() },
                .{ .name = "dynlib", .module = byName(mods, "dynlib") },
            },
        }),
    });
    all_step.dependOn(&vpi_host.step);
    const test_vpi = &b.top_level_steps.get("test-vpi").?.step;
    const vpi_app = vpiApp(b, target, optimize, vpi_host, "tests/fixtures/ch11_vpi/vpi_app.c", "tests/fixtures/ch11_vpi");
    vpi_app.expectExitCode(0);
    // The counts are tests/fixtures/ch11_vpi/vpi_design.va's shape, and `checks` is how many
    // assertions the application reached: a walk that returns early, or a
    // startup table never called, still exits 0.
    vpi_app.expectStdOutEqual("vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=711\n");
    test_step.dependOn(&vpi_app.step);
    // `test-vpi` is a top-level step the module loop already created; this is
    // the C half joining it, rather than a second step with the same name.
    test_vpi.dependOn(&vpi_app.step);

    // The C fixtures that run: each against its design, asserted by exit code
    // and exact stdout (and stderr where the fixture reports there).
    for (vpi_runs) |f| {
        const r = vpiApp(b, target, optimize, vpi_host, f.c, std.fs.path.dirname(f.c).?);
        r.addFileArg(b.path(f.design));
        // An analog design's application names its analyses in its own
        // banner (`*! analysis`); the host reads them there.
        if (std.mem.endsWith(u8, f.design, ".va")) r.addFileArg(b.path(f.c));
        // Channels a fixture opens (§12.26) land in the cwd, which is the
        // cache and not the source tree.
        r.setCwd(b.path(".zig-cache"));
        if (f.xfail orelse f.refuse) |m| {
            r.expectExitCode(1);
            r.expectStdErrMatch(m);
            if (f.refuse != null) r.expectStdOutEqual(f.stdout);
        } else {
            r.expectExitCode(0);
            r.expectStdOutEqual(f.stdout);
            if (f.stderr) |e| r.expectStdErrEqual(e);
        }
        test_step.dependOn(&r.step);
        test_vpi.dependOn(&r.step);
    }

    // Only the AMS `vera` emits devices.
    if (language != .ams) return;
    const contract = byName(mods, "contract");
    const test_timers = b.step("test-timers", "Run emitted-device timer scheduling tests");
    const test_paramsets = b.step("test-paramsets", "Run emitted-device paramset binding and host shape tests");
    for (host_tests) |h| {
        const gen = b.addRunArtifact(gen_exe);
        gen.addArgs(&.{ "--emit-zig", "-I" });
        gen.addDirectoryArg2(b.path("tests/fixtures"), .{});
        gen.addFileArg(b.path(h.va));
        gen.addArg("-o");
        const device = gen.addOutputFileArg2("device.zig", .{});
        _ = gen.captureStdErr(.{}); // the fixture's warnings are not this test's
        const host = b.createModule(.{
            .root_source_file = b.path(h.host),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "contract", .module = contract },
                .{ .name = "device", .module = b.createModule(.{
                    .root_source_file = device,
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "contract", .module = contract }},
                }) },
            },
        });
        const run_host = testRun(b, std.fs.path.stem(h.host), host, runner);
        test_step.dependOn(run_host);
        if (std.mem.eql(u8, h.host, "tests/timer_host.zig")) test_timers.dependOn(run_host);
        if (std.mem.eql(u8, h.host, "tests/paramset_host.zig")) test_paramsets.dependOn(run_host);
        // §9.7.3 the status channel on the GPU targets a device also builds
        // for: AMDGCN to an object; NVPTX to LLVM IR only, because `@export`
        // of a `callconv(.kernel)` function is an LLVM alias the NVPTX
        // backend refuses (a host rewrites the IR first, as Gompute does).
        if (std.mem.eql(u8, h.host, "tests/status_host.zig")) for ([_][2][]const u8{
            .{ "nvptx64-cuda", "sm_70" },
            .{ "amdgcn-amdhsa", "gfx906" },
        }) |gpu| {
            const gt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = gpu[0], .cpu_features = gpu[1] }) catch unreachable);
            const gc = b.createModule(.{ .root_source_file = b.path("tools/contract.zig"), .target = gt, .optimize = .fast });
            const obj = b.addObject(.{ .name = "status-gpu", .root_module = b.createModule(.{
                .root_source_file = b.path("tests/status_gpu.zig"),
                .target = gt,
                .optimize = .fast,
                .strip = true,
                .imports = &.{
                    .{ .name = "contract", .module = gc },
                    .{ .name = "device", .module = b.createModule(.{
                        .root_source_file = device,
                        .target = gt,
                        .optimize = .fast,
                        .imports = &.{.{ .name = "contract", .module = gc }},
                    }) },
                },
            }) });
            const out = if (gt.result.cpu.arch == .nvptx64) obj.getEmittedLlvmIr() else obj.getEmittedBin();
            test_step.dependOn(&b.addCheckFile(out, .{ .expected_matches = &.{"status_ops_kernel"} }).step);
        };
    }

    // `.v` contract devices (`rt.Device`) under a mock analog host, each
    // imported by its design's name; the designs a device refuses, and W1155.
    const vdev_host = b.createModule(.{
        .root_source_file = b.path("tests/vdev_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract }},
    });
    // Three of them also built by `vera --emit-so` against the prebuilt
    // engine, which `tests/vdev_so_host.zig` compares with the whole one.
    const vdev_dyn = b.createModule(.{
        .root_source_file = b.path("tests/vdev_dyn.zig"),
        .imports = &.{.{ .name = "contract", .module = contract }},
    });
    const so_opts = b.addOptions();
    const vdev_so_host = b.createModule(.{
        .root_source_file = b.path("tests/vdev_so_host.zig"),
        .target = target,
        .optimize = optimize,
        // `dlopen`: the device keeps thread-local allocator state.
        .link_libc = true,
        .imports = &.{ .{ .name = "vdev_dyn", .module = vdev_dyn }, .{ .name = "vdev_so_options", .module = so_opts.createModule() }, .{ .name = "dynlib", .module = byName(mods, "dynlib") } },
    });
    for ([_][]const u8{ "v_inv", "v_buf", "v_count", "v_a2d", "v_edge", "v_any", "v_wide", "v_huge", "v_say" }) |name| {
        const gen = b.addRunArtifact(gen_exe);
        gen.addArg("--emit-zig");
        gen.addFileArg(b.path(b.fmt("tests/fixtures/ch07_mixed_signal/{s}.v", .{name})));
        gen.addArg("-o");
        const device = gen.addOutputFileArg2(b.fmt("{s}.zig", .{name}), .{});
        const dev_mod = b.createModule(.{
            .root_source_file = device,
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "contract", .module = contract }, .{ .name = "sim", .module = byName(mods, "sim") } },
        });
        vdev_host.addImport(name, dev_mod);
        if (std.mem.eql(u8, name, "v_count") or std.mem.eql(u8, name, "v_a2d") or std.mem.eql(u8, name, "v_buf")) {
            vdev_so_host.addImport(name, dev_mod);
            const so = b.addRunArtifact(gen_exe);
            so.addArgs(&.{ "--emit-so", "--contract" });
            so.addFileArg(b.path("tools/contract.zig"));
            so.addArg("--dyn");
            so.addFileArg(b.path("tests/vdev_dyn.zig"));
            so.addArg("--work-dir");
            const wd = so.addOutputDirectoryArg2(name, .{});
            so.addFileArg(b.path(b.fmt("tests/fixtures/ch07_mixed_signal/{s}.v", .{name})));
            const host = &b.graph.host.result; // `gen_exe` names it for the build host
            so_opts.addOptionPath(name, wd.path(b, b.fmt("{s}{s}.1{s}", .{ host.libPrefix(), name, host.dynamicLibSuffix() })));
        }
    }
    test_step.dependOn(testRun(b, "vdev_host", vdev_host, runner));
    test_step.dependOn(testRun(b, "vdev_so_host", vdev_so_host, runner));
    for ([_]struct { args: []const []const u8, file: []const u8, exit: u8, says: []const u8 }{
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_inout.v", .exit = 1, .says = "error[E1103]: design cannot be a contract device: module `v_inout`: an inout port" },
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_integer.v", .exit = 1, .says = "error[E1103]: design cannot be a contract device: module `v_integer`: an integer or time port" },
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_pins.v", .exit = 1, .says = "error[E1103]: design cannot be a contract device: module `v_pins`: more than 65535 pins" },
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_tran.v", .exit = 1, .says = "error[E1103]: design cannot be a contract device: module `v_tran`: a §7.6 pass switch" },
        .{ .args = &.{ "--emit-zig", "--state=auto" }, .file = "tests/fixtures/ch07_mixed_signal/v_inv.v", .exit = 1, .says = "error[E1103]: design cannot be a contract device: a contract device is 4-state: --state=auto" },
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_sv.sv", .exit = 2, .says = "error[E1104]: a SystemVerilog source is not supported" },
        .{ .args = &.{"--emit-zig"}, .file = "tests/fixtures/ch07_mixed_signal/v_seconds.v", .exit = 0, .says = "warning[W1155]: device digital tick is 1 s" },
    }) |r| {
        const run = b.addRunArtifact(exe);
        run.addArgs(r.args);
        run.addFileArg(b.path(r.file));
        run.expectExitCode(r.exit);
        run.addCheck(.{ .expect_stderr_match = r.says });
        test_step.dependOn(&run.step);
    }
    // The fixed-grid runner's W0750 obeys the same lint levels as compiler
    // diagnostics. Allowed/warned neighbours build over the binary's own
    // contract; --run also proves the §5.10.3.1 event actually fires.
    const grid_events = b.step("test-grid-events", "Check fixed-grid testbench diagnostics and execution");
    test_step.dependOn(grid_events);
    for ([_][]const u8{ "--run", "--emit-exe" }) |mode| for ([_][]const u8{ "allow", "warn", "deny", "forbid" }) |level| {
        const rejected = std.mem.eql(u8, level, "deny") or std.mem.eql(u8, level, "forbid");
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ mode, b.fmt("--{s}=W0750", .{level}), "--allow=W0650", "-I" });
        run.addDirectoryArg2(b.path("tests/fixtures"), .{});
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("tb", .{});
        run.addFileArg(b.path("tests/fixtures/ch05_analog_behavior/event_cross_fires_on_a_time_grid.va"));
        run.expectExitCode(if (rejected) 1 else 0);
        if (rejected) {
            run.expectStdOutEqual(""); // No artifact path on a refusal.
            run.addCheck(.{ .expect_stderr_match = "error[W0750]" });
        } else {
            if (std.mem.eql(u8, mode, "--run"))
                run.addCheck(.{ .expect_stderr_match = "one rising clk edge is one event got=1 want=1 ok=1" });
            if (std.mem.eql(u8, level, "warn"))
                run.addCheck(.{ .expect_stderr_match = "warning[W0750]" })
            else if (std.mem.eql(u8, mode, "--emit-exe"))
                run.expectStdErrEqual("");
        }
        grid_events.dependOn(&run.step);
    };
    // --emit-verilog over AnalogIOC's golden models (tests/beh_verilog/). `test`
    // pins each module's delays and its USE_POWER_PINS port list;
    // `test-beh-verilog` also compiles every module clean in iverilog and
    // `verilator --lint-only -Wall`, with and without the supply pins, and
    // runs its testbench in iverilog (both need to be on PATH).
    const beh_step = b.step("test-beh-verilog", "Simulate --emit-verilog modules in iverilog and lint them in verilator");
    const vdd_vss = "`ifdef USE_POWER_PINS\n    , vdd\n    , vss\n`endif\n);";
    for ([_]struct { va: []const u8, args: []const []const u8, says: []const u8, supplies: []const u8 = vdd_vss }{
        .{ .va = "strongarm", .args = &.{ "--digital-pins", "clk,outp,outn" }, .says = "parameter real vera_fall_fp = 0.500000; // ns" },
        .{ .va = "async_ctrl", .args = &.{ "--digital-pins", "go adc_done xbar_rst adc_go latch_out done" }, .says = "parameter real vera_rise_s = 48.000000; // ns" },
        .{ .va = "tq_chain", .args = &.{ "--digital-pins", "in,tap1,tap2,tap3,tap4" }, .says = "parameter real vera_rise_m1 = 7.100000; // ns" },
        .{ .va = "attrs", .args = &.{}, .says = "parameter real vera_rise_z = 3.000000; // ns", .supplies = "`ifdef USE_POWER_PINS\n    , pwr\n    , gnd0\n`endif\n);" },
    }) |f| {
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        gen.addArgs(f.args);
        gen.addFileArg(b.path(b.fmt("tests/beh_verilog/{s}.va", .{f.va})));
        gen.addArg("-o");
        const v = gen.addOutputFileArg(b.fmt("{s}.v", .{f.va}));
        gen.expectExitCode(0);
        test_step.dependOn(&gen.step);
        const pinned = b.addRunArtifact(exe);
        pinned.addArgs(&.{ "--emit-verilog", "--power-pins", "--allow=W0650" });
        pinned.addArgs(f.args);
        pinned.addFileArg(b.path(b.fmt("tests/beh_verilog/{s}.va", .{f.va})));
        pinned.addCheck(.{ .expect_stdout_match = f.says });
        pinned.addCheck(.{ .expect_stdout_match = f.supplies });
        test_step.dependOn(&pinned.step);
        for ([_][]const []const u8{ &.{}, &.{"-DUSE_POWER_PINS"} }) |def| {
            const lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wall", "--timing" });
            lint.addArgs(def);
            lint.addFileArg(v);
            lint.expectExitCode(0);
            beh_step.dependOn(&lint.step);
            const comp = b.addSystemCommand(&.{ "iverilog", "-Wall" });
            comp.addArgs(def);
            comp.addArg("-o");
            const vvp = comp.addOutputFileArg(b.fmt("tb_{s}.vvp", .{f.va}));
            comp.addFileArg(v);
            comp.addFileArg(b.path(b.fmt("tests/beh_verilog/tb_{s}.v", .{f.va})));
            comp.expectExitCode(0);
            const sim = b.addSystemCommand(&.{ "vvp", "-n" });
            sim.addFileArg(vvp);
            sim.addCheck(.{ .expect_stdout_match = b.fmt("PASS tb_{s}", .{f.va}) });
            beh_step.dependOn(&sim.step);
        }
    }
    // --emit-so skips the preflight type check and runs it only after a failed
    // build, so a device that does not compile is still reported against its
    // .va. A contract that refuses to compile stands in for an engine bug.
    {
        const wf = b.addWriteFiles();
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "--emit-so", "--allow=W0650", "--contract" });
        run.addFileArg(wf.add("contract.zig", "comptime {\n    @compileError(\"broken contract\");\n}\n"));
        run.addArg("--dyn");
        run.addFileArg(wf.add("dyn.zig", "pub fn exportDevice(comptime D: type, comptime name: []const u8) void {\n    _ = D;\n    _ = name;\n}\n"));
        run.addArg("--work-dir");
        _ = run.addOutputDirectoryArg2("so", .{});
        run.addFileArg(b.path("tests/fixtures/ch11_vpi/vpi_design.va"));
        run.expectExitCode(1);
        run.expectStdOutEqual("");
        run.addCheck(.{ .expect_stderr_match = "vpi_design.va: codegen produced Zig that does not compile" });
        run.addCheck(.{ .expect_stderr_match = "broken contract" });
        test_step.dependOn(&run.step);
    }
    // E1013's 64 MiB cap on the source and on a `--spice` netlist. /dev/zero
    // never ends, so no file that size is committed or written.
    if (b.graph.host.result.os.tag != .windows) for ([_][]const []const u8{
        &.{ "--lint", "/dev/zero" },
        &.{ "--lint", "--spice", "/dev/zero", "tests/fixtures/ch02_lexical/28_identifier_1024_chars.va" },
    }) |args| {
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.addArgs(args);
        run.expectExitCode(2);
        run.addCheck(.{ .expect_stderr_match = "error[E1013]: `/dev/zero` is larger than 67108864 bytes" });
        test_step.dependOn(&run.step);
    };
}

/// A host driver and the `.va` its `device` import is emitted from: device
/// hooks called in an order the fixture directives cannot express.
const host_tests = [_]struct { host: []const u8, va: []const u8 }{
    .{ .host = "tests/paramset_host.zig", .va = "tests/fixtures/ch06_hierarchy/paramset_outer_defparam_shape.va" },
    .{ .host = "tests/integer_param_host.zig", .va = "tests/fixtures/ch03_data_types/integer_param_low32.va" },
    .{ .host = "tests/fixtures/ch09_system_tasks/bound_step_infinite_host.zig", .va = "tests/fixtures/ch09_system_tasks/bound_step_infinite_is_no_bound.va" },
    .{ .host = "tests/fixtures/ch03_data_types/nodeset_metadata_host.zig", .va = "tests/fixtures/ch03_data_types/a08_nodeset_02_nodeset_bus_null_element.va" },
    .{ .host = "tests/fixtures/ch04_expressions/a04_rollback_rollback_host.zig", .va = "tests/fixtures/ch04_expressions/a04_rollback_a04_rollback_ops.va" },
    .{ .host = "tests/fixtures/ch04_expressions/a04_idt_hold_revert_host.zig", .va = "tests/fixtures/ch04_expressions/a04_idt_hold_revert.va" },
    .{ .host = "tests/revert_host.zig", .va = "tests/fixtures/ch04_expressions/revert_ops.va" },
    .{ .host = "tests/fixtures/ch09_system_tasks/bound_step_smallest_host.zig", .va = "tests/fixtures/ch09_system_tasks/bound_step_smallest_active_wins.va" },
    .{ .host = "tests/status_host.zig", .va = "tests/fixtures/ch09_system_tasks/status_ops.va" },
    .{ .host = "tests/port_mask_host.zig", .va = "tests/fixtures/ch09_system_tasks/port_mask.va" },
    .{ .host = "tests/table_status_host.zig", .va = "tests/fixtures/ch09_system_tasks/table_status.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_fixed.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_dynamic.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_reg_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_clog2_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_array_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_index_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_function_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_context_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_array_function_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_effect_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_constant_effect_controls.va" },
    .{ .host = "tests/timer_host.zig", .va = "tests/fixtures/ch05_analog_behavior/timer_body_precomputed_controls.va" },
    .{ .host = "tests/fixtures/ch04_expressions/absdelay_ac_phase_host.zig", .va = "tests/fixtures/ch04_expressions/absdelay_ac_phase.va" },
    .{ .host = "tests/ac_dyn_host.zig", .va = "tests/fixtures/ch04_expressions/absdelay_ac_phase.va" },
    .{ .host = "tests/ac_dyn_host.zig", .va = "tests/fixtures/ch04_expressions/laplace_ac_response.va" },
    .{ .host = "tests/ac_dyn_host.zig", .va = "tests/fixtures/ch04_expressions/zi_ac_response.va" },
};

/// The `vera` CLI. It imports the engine as modules; an `@import` by path
/// would compile the engine a second time into its file set.
fn cliExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    mods: []const std.Build.Module.Import,
    name: []const u8,
    ams: bool,
) *std.Build.Step.Compile {
    const o = b.addOptions();
    o.addOption(bool, "ams", ams);
    // Every module but `vpi`: the CLI is not a VPI host, and the module's
    // `varargs.c` would link against exports nothing here analyses.
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    for (mods) |m| if (!std.mem.eql(u8, m.name, "vpi")) imports.append(b.allocator, m) catch @panic("OOM");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports.items,
    });
    mod.addOptions("build_options", o);
    mod.addImport("sim_sources", simSources(b));
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// The `sim_sources` module: `files`, every source `sim` compiles from (the
/// `@import`/`@embedFile` closure of its `module_specs` row and that row's
/// imports), as `.{ path, bytes }`. `vera --emit-exe design.v` writes them
/// out and builds the design's executable over them, so it needs no tree.
fn simSources(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var root: std.Io.Writer.Allocating = .init(b.allocator);
    root.writer.writeAll("pub const files = [_][2][]const u8{\n") catch @panic("OOM");
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (module_specs) |spec| if (std.mem.eql(u8, spec.name, "sim")) {
        seen.put(b.allocator, spec.path, {}) catch @panic("OOM");
        for (spec.imports) |dep| for (module_specs) |d| if (std.mem.eql(u8, d.name, dep)) seen.put(b.allocator, d.path, {}) catch @panic("OOM");
    };
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const path = seen.keys()[i];
        const text = b.root.root_dir.handle.readFileAlloc(io, path, b.allocator, .unlimited) catch |e| std.debug.panic("{s}: {t}", .{ path, e });
        // The configuration is cached: an edited `@import` re-runs this walk.
        b.dependOnFileContents(b.path(path));
        var it = std.mem.tokenizeAny(u8, text, "\"");
        var before: []const u8 = "";
        while (it.next()) |tok| : (before = tok) {
            if (!(std.mem.endsWith(u8, before, "@import(") or std.mem.endsWith(u8, before, "@embedFile("))) continue;
            if (std.mem.indexOfScalar(u8, tok, '.') == null) continue; // a module name
            // `/` on every host: `resolveAllocPosix` collapses `..` only across
            // `/`, and a native `\\` join on Windows grew the path forever.
            const dep = b.fmt("{s}/{s}", .{ std.fs.path.dirnamePosix(path) orelse ".", tok });
            const norm = std.fs.path.resolveAllocPosix(b.allocator, &.{dep}) catch @panic("OOM");
            // A path in prose, not code: nothing to ship.
            b.root.root_dir.handle.access(io, norm, .{}) catch continue;
            seen.put(b.allocator, norm, {}) catch @panic("OOM");
        }
        _ = wf.addCopyFile(b.path(path), path);
        root.writer.print("    .{{ \"{s}\", @embedFile(\"{s}\") }},\n", .{ path, path }) catch @panic("OOM");
    }
    root.writer.writeAll("};\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = wf.add("sim_sources.zig", root.written()) });
}

/// A C application at `c`, compiled against src/vpi/vpi_user.h (and its own
/// directory, for a fixture's shared header) with `vpi_app.c`'s flags, linked
/// against the host library, and run.
fn vpiApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    host: *std.Build.Step.Compile,
    c: []const u8,
    dir: []const u8,
) *std.Build.Step.Run {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
    mod.addIncludePath(b.path("src/vpi"));
    mod.addIncludePath(b.path(dir));
    mod.linkLibrary(host);
    const app = b.addExecutable(.{ .name = b.fmt("vpi-{s}", .{std.fs.path.stem(c)}), .root_module = mod });
    b.top_level_steps.get("build-all").?.step.dependOn(&app.step);
    return b.addRunArtifact(app);
}

/// One runnable VPI application: its C file, the design it runs against, and
/// the exact output it must produce. The `checks=N` count catches a run that
/// returns early and still exits 0. `xfail` is a known VerA gap instead: the
/// run exits 1 with this text in its stderr, so the run that stops failing
/// fails the step until the marker is removed. `refuse` is the same check
/// for a design the host must refuse (a rejection the application itself
/// cannot observe).
const VpiRun = struct {
    c: []const u8,
    design: []const u8,
    stdout: []const u8 = "",
    stderr: ?[]const u8 = null,
    xfail: ?[]const u8 = null,
    refuse: ?[]const u8 = null,
};

/// Not here, each for a reason outside the routine it exercises:
///   p03_07/90, p02_11  an analog system TASK whose calltf writes an output
///           argument (§12.22.2's $resistor): the device calls user system
///           FUNCTIONS only (`contract.SystfHost` returns one value)
///   p03_09  an `ac` analysis: no small-signal solve runs in this process
const vpi_runs = [_]VpiRun{
    .{
        .c = "tests/fixtures/ch11_vpi/p06_01_specify_objects.c",
        .design = "tests/fixtures/ch11_vpi/p06_specify.v",
        .stdout = "p02: p06_01_specify_objects checks=59\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p05_01_put_delays.c",
        .design = "tests/fixtures/ch11_vpi/p05_delays.v",
        .stdout = "p05-01: w=2/12/32 y=3/11/33\np02: p05_01_put_delays checks=27\n",
    },
    // §12.31.3's analyses: the host builds the design's analog library and
    // runs the `*! analysis` lines of the application's banner.
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_01_time_delta_freq_at_zero.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_dc_divider.va",
        .stdout = "p03-01: t0=0 dt0=0 f0=0 initial=1 final=1 later_pos=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_02_accepted_point_sequence.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-02: initial=1 final=1 t_final=0.005 monotone=1 delta_ok=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_03_forced_solution_points.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-03: abs_t=0.0025 abs_v=2.5 el1=0.0015 v1=1.5 el2=0.003 v2=3 accepted=3\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_04_remove_cb_during_dispatch.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-04: at1=1 at2=1 at3=0 at4=1 rm_future=1 rm_self=1 rm_same=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_05_convergence_test_rejection.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-05: rejected=1 backed_up=1 ct_before_ap=1 t_final=0.005\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_12_sim_control_reject_step.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-12: rejected=1 backed_up=1 t_final=0.005\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_08_analog_value_formats.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_dc_divider.va",
        .stdout = "p03-08: v=1.25 i=0.0025 vexp=1.250000e+00 vdec=1.25 vg=1.25 fmt_reset=1 sep_buf=1 overwritten=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_10_repeated_analyses.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_ramp_load.va",
        .stdout = "p03-10: initial=2 final=2 t0=0 v_final=2 late_t=0.0015 late_v=1.5 late_hits=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_11_registration_roundtrip.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_dc_divider.va",
        .stdout = "p03-11: systf_roundtrip=1 cb_roundtrip=1 dup_rejected=1 probe_hits=1 probe_t=0.0025\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_06_sampler_plugin.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_sampnhold.va",
        .stdout = "p03-06: samples=6 first=0 last=5 hold_2p5=2 hold_4p25=4\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_93_get_real_in_calltf.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_env_probe.va",
        .stdout = "p03-93: start=0 end=0.001 max_step=0.0001 refused_per_call=2 v_b=1\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_94_function_partials.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_square_law.va",
        .stdout = "p03-94: v_q=1.732050808 dfdx=3.464101615 refused_per_call=2\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_92_reject_analog_callback_times.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_dc_divider.va",
        .stdout = "p03-92: control_hits=1 control_t=0.0005 refused=4 errs=4\n",
    },
    .{
        .c = "tests/fixtures/ch12_vpi_routines/p03_91_reject_stale_callback_handle.c",
        .design = "tests/fixtures/ch12_vpi_routines/p03_dc_divider.va",
        .stdout = "p03-91: first=1 second=0 null=0 wrongtype=0 info_err=1 errs=4 fired=0\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_vpi_invalid_time_callback.c",
        .design = "tests/fixtures/ieee_pli/audit_vpi_invalid_time_callback.v",
        .stdout = "vpi-invalid-time-callback=ok\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_12_systf_domains.c",
        .design = "tests/fixtures/ch11_vpi/p02_analog.va",
        .stdout = "p02: 12_systf_domains checks=26\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_09_printf_mcd.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02 printf 7 ok\np02: 09_printf_mcd checks=29\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_06_cb_value_change.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 06_cb_value_change checks=62\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_end_compile_objects.c",
        .design = "tests/fixtures/ieee_pli/audit_end_compile_objects.v",
        .stdout = "",
        .stderr = "pli-end-compile type=vpiModule\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_01_get_value_formats.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 01_get_value_formats checks=50\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_02_get_value_unknown.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 02_get_value_unknown checks=21\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_03_put_value_delays.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 03_put_value_delays checks=64\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_04_force_release.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 04_force_release checks=39\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_05_cb_time_regions.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 05_cb_time_regions checks=82\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_07_cb_remove_and_info.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 07_cb_remove_and_info checks=38\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_08_cb_action_sim_control.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: 08_cb_action_sim_control checks=24\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_array_object_kinds.c",
        .design = "tests/fixtures/ieee_pli/audit_array_object_kinds.v",
        .stdout = "",
        .stderr = "pli-array-kinds reg-words=2 real-selects=2\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_13_get_time_scaling.c",
        .design = "tests/fixtures/digital/p02_scales.v",
        .stdout = "p02: 13_get_time_scaling checks=15\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_module_array.c",
        .design = "tests/fixtures/ieee_pli/audit_module_array.v",
        .stdout = "",
        .stderr = "pli-module-array members=2 indices=0,1\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_vpi_value_formats.c",
        .design = "tests/fixtures/ieee_pli/audit_vpi_value_formats.v",
        .stdout = "vpi-value-formats=ok\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_vpi_event_handles.c",
        .design = "tests/fixtures/ieee_pli/audit_vpi_event_handles.v",
        .stdout = "vpi-event-handles=ok\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_01_object_traversal.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: p04_01_object_traversal checks=98\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_02_object_refusals.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: p04_02_object_refusals checks=118\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_03_value_time_refusals.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: p04_03_value_time_refusals checks=70\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_04_callback_systf_refusals.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: p04_04_callback_systf_refusals checks=83\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_05_vlog_info.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: p04_05_vlog_info checks=30\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_06_analog_objects.c",
        .design = "tests/fixtures/ch11_vpi/p04_analog.va",
        .stdout = "p02: p04_06_analog_objects checks=139\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_07_behaviour_objects.c",
        .design = "tests/fixtures/ch11_vpi/p04_behaviour.v",
        .stdout = "p02: p04_07_behaviour_objects checks=240\np04_behaviour: d=12\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_08_analog_behaviour.c",
        .design = "tests/fixtures/ch11_vpi/p04_analog.va",
        .stdout = "p02: p04_08_analog_behaviour checks=76\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_09_systf_build.c",
        .design = "tests/fixtures/ch11_vpi/p04_analog.va",
        .stdout = "p02: p04_09_systf_build checks=58\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_10_primitives.c",
        .design = "tests/fixtures/ch11_vpi/p04_prims.v",
        .stdout = "p02: p04_10_primitives checks=96\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_11_instance_scopes.c",
        .design = "tests/fixtures/ch11_vpi/p04_scopes.v",
        .stdout = "p02: p04_11_instance_scopes checks=23\n",
    },
    // IEEE 1364-2005 §20, §26, §27 and Annex G (measure B). An `xfail N.N:`
    // line in `stdout` is a requirement VerA does not meet yet (b_check.h).
    .{
        .c = "tests/fixtures/ieee_pli/b_20_4_timing_checks.c",
        .design = "tests/fixtures/ch11_vpi/p06_specify.v",
        .stdout = "p02: b_20_4_timing_checks checks=7\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_20_3_task_as_function.c",
        .design = "tests/fixtures/ieee_pli/b_20_3_task_as_function.v",
        .refuse = "vpi_host: `$random` is registered as a system task and called as a function (IEEE 1364-2005 §20.3)",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_1_systf.c",
        .design = "tests/fixtures/ieee_pli/b_26_1_systf.v",
        .stdout = "p02: b_26_1_systf checks=45\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_2_4_startup_phase.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "b264 eoc\np02: b_26_2_4_startup_phase checks=27\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_3_5_protected.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: b_26_3_5_protected checks=43\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p02_10_systf_digital.c",
        .design = "tests/fixtures/digital/p02_systf.v",
        .stdout = "p02: 10_systf_digital checks=92\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_builtin_override.c",
        .design = "tests/fixtures/ieee_pli/audit_builtin_override.v",
        .stdout = "first=8000000001 second=8000000001\n",
        .stderr = "pli-override calls=2 size=40\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_lazy_arguments.c",
        .design = "tests/fixtures/ieee_pli/audit_lazy_arguments.v",
        .stdout = "unread=0\nread=1\n",
        .stderr = "pli-lazy-arguments calls=2 reads=1\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_19_lazy_arguments.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_19_lazy_arguments.v",
        .stdout = "root_calls=10\n",
        .stderr = "pli-lazy-scopes calls=3 nested=2 retained=2\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_structure.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_structure.v",
        .stdout = "p02: b_26_6_structure checks=313\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_behaviour.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_behaviour.v",
        .stdout = "p02: b_26_6_behaviour checks=298\nd=12 c=1 q=9 p2=0101\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_prim_review.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_prim_review.v",
        .stdout = "b26_prim_review: active drivers, UDP symbols and strengths ok\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_primitives.c",
        .design = "tests/fixtures/ch11_vpi/p04_prims.v",
        .stdout = "p02: b_26_6_primitives checks=65\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_specify.c",
        .design = "tests/fixtures/ch11_vpi/p06_specify.v",
        .stdout = "p02: b_26_6_specify checks=58\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_41_timeformat.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_41_timeformat.v",
        .stdout = "b26_timeformat: active call follows execution ok\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_39_callbacks.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_39_callbacks.v",
        .stdout = "b26_callbacks: traversal and delivery ok\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_18_subroutines.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_18_subroutines.v",
        .stdout = "b26_subroutines: metadata and runtime ok\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_20_frames.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_20_frames.v",
        .stdout = "p02: b_26_6_20_frames checks=14\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_11_event_array.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_11_event_array.v",
        .stdout = "p02: b_26_6_11_event_array checks=271\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_31_repeat_control.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_31_repeat_control.v",
        .stdout = "p02: b_26_6_31_repeat_control checks=13\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_42_attributes.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_42_attributes.v",
        .stdout = "p02: b_26_6_42_attributes checks=630\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_26_6_42_analog_attributes.c",
        .design = "tests/fixtures/ieee_pli/b_26_6_42_analog_attributes.va",
        .stdout = "p02: b_26_6_42_analog_attributes checks=132\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_objects.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "p02: b_27_objects checks=83\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_values.c",
        .design = "tests/fixtures/ieee_pli/b_27_values.v",
        .stdout = "xfail 27.14: a time variable as vpiObjTypeVal is not vpiTimeVal 5000000000\np02: b_27_values checks=140\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_33_callbacks.c",
        .design = "tests/fixtures/digital/p02_design.v",
        .stdout = "p02: b_27_33_callbacks checks=82\np02_design: t=20 reached\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/audit_stmt_registration_during_call.c",
        .design = "tests/fixtures/ieee_pli/audit_stmt_registration_during_call.v",
        .stdout = "stmt-registration: before=0,1,3 final=4\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_mcd.c",
        .design = "tests/fixtures/ieee_pli/b_27_mcd.v",
        .stdout = "b27 printf 7 ok\nb27 mcd1\np02: b_27_mcd checks=34\n",
        .stderr = "",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_delays.c",
        .design = "tests/fixtures/ch11_vpi/p05_delays.v",
        .stdout = "p02: b_27_delays checks=25\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_27_utilities.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "b27v 5\np02: b_27_utilities checks=33\n",
    },
    .{
        .c = "tests/fixtures/ieee_pli/b_G_vpi_user.c",
        .design = "tests/fixtures/ch11_vpi/p04_objects.v",
        .stdout = "xfail G: 85 of Annex G's 441 constant names are not defined\np02: b_G_vpi_user checks=359\n",
    },
};

/// `vpi_runs`' C paths, for the suite's `--coverage` (see `vpi_runs` option).
const vpi_run_paths = blk: {
    var paths: [vpi_runs.len][]const u8 = undefined;
    for (vpi_runs, &paths) |r, *p| p.* = r.c;
    break :blk paths;
};

/// Creates every module in `module_specs` with `addModule` (`exported`), so an
/// embedder can import it, else with `createModule`, resolving imports against
/// modules already created. Panics on a forward reference.
fn defineModules(b: *std.Build, target: std.Build.ResolvedTarget, exported: bool) []const std.Build.Module.Import {
    var created: std.ArrayList(std.Build.Module.Import) = .empty;
    for (module_specs) |spec| {
        var deps: std.ArrayList(std.Build.Module.Import) = .empty;
        for (spec.imports) |dep_name| {
            const found = for (created.items) |c| {
                if (std.mem.eql(u8, c.name, dep_name)) break c;
            } else @panic("module imported before it was defined: check module_specs order");
            deps.append(b.allocator, found) catch @panic("OOM");
        }
        const opts: std.Build.Module.CreateOptions = .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .imports = deps.items,
        };
        const mod = if (exported) b.addModule(spec.name, opts) else b.createModule(opts);
        if (spec.c) |c| {
            mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
            mod.addIncludePath(b.path(std.fs.path.dirname(c).?));
        }
        created.append(b.allocator, .{ .name = spec.name, .module = mod }) catch @panic("OOM");
    }
    return created.items;
}

/// An absolute path under the build root: the `b.pathFromRoot` Zig 0.17
/// removed. The root's path is absolute whenever `zig build` finds build.zig.
fn pathFromRoot(b: *std.Build, sub_path: []const u8) []u8 {
    return b.pathResolve(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, sub_path });
}

fn byName(mods: []const std.Build.Module.Import, name: []const u8) *std.Build.Module {
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.module;
    }
    @panic("no such module: check module_specs");
}

/// One test artifact over `mod`, run, and compiled under `build-all`. `CLICOLOR_FORCE` is what makes zrunner's
/// report colored when the build captures its output.
fn testRun(
    b: *std.Build,
    name: []const u8,
    mod: *std.Build.Module,
    runner: std.Build.Step.Compile.TestRunner,
) *std.Build.Step {
    const t = b.addTest(.{
        .name = name,
        .root_module = mod,
        .test_runner = runner,
    });
    b.top_level_steps.get("build-all").?.step.dependOn(&t.step);
    const r = b.addRunArtifact(t);
    r.setEnvironmentVariable("CLICOLOR_FORCE", "true");
    return &r.step;
}
