//! VerA builds one binary and exposes compiler and runtime modules.
//!
//! The binary is `vera`: `src/main.zig`, which compiles Verilog-A through the
//! `lib/` modules and runs digital Verilog through `src/sim`.
//! The modules are for an embedder — a simulator that wants to compile
//! Verilog-A in-process rather than shell out. `lib/` is the compiler and
//! `src/` is everything that runs after it; see `module_specs`.
//!
//! TWO TABLES AND THREE LOOPS, which is the whole file:
//!
//!   module_specs   the module graph, written down once
//!   the `test` step, which is every module's own test artifact plus the above
//!
//! THERE IS ONE SUITE STEP, `benchmark`, and it is a run of `tests/bench.zig`
//! with the `vera` binary's path and `b.args`. It was four — torture,
//! torture-pending, conformance, benchmark — over that same one executable with
//! a mode argument, which meant four ways for "the same fixtures, judged the
//! same way" to stop being true. The differences between them are flags now:
//! `--fixture-root=tests/pending`, `--against-openvaf`, `--strict`.
//!
//! WHAT IS NOT HERE, deliberately: anything whose input is the OUTPUT of the
//! `vera` binary. Generated devices, the hosts that call into them, the CLI
//! goldens — those are a subprocess pipeline, and expressing one as build-graph
//! artifacts costs ten lines of plumbing per case in a language that cannot read
//! a file. They are `tests/bench.zig devices`, which gets the binary's path from
//! `run.addArtifactArg(exe)` and spawns it itself.
//!
//! `tools/contract.zig` is not build-script material either, in the opposite
//! direction: it is compiled into every generated DEVICE and into no part of
//! the compiler, which is why it sits in `tools/` and is a module here.

const std = @import("std");

const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8 = &.{},
};

/// Order is the dependency order: a module may only import ones declared above
/// it. `defineModules` panics otherwise, so a cycle is a build error and not a
/// review note.
const module_specs = [_]ModuleSpec{
    .{ .name = "contract", .path = "tools/contract.zig" },

    // lib/ — the compiler. `vera` is its facade and what an embedder takes.
    .{ .name = "diag", .path = "lib/diag.zig" },
    .{ .name = "frontend", .path = "lib/frontend/root.zig", .imports = &.{"diag"} },
    .{ .name = "kernels", .path = "lib/backend/kernels.zig" },
    .{ .name = "ir", .path = "lib/ir/root.zig", .imports = &.{ "diag", "frontend", "kernels" } },
    .{ .name = "backend", .path = "lib/backend/root.zig", .imports = &.{ "diag", "frontend", "ir", "kernels" } },
    .{ .name = "vera", .path = "lib/root.zig", .imports = &.{ "diag", "frontend", "ir", "backend", "kernels" } },

    // src/ — what runs AFTER compilation. `sim` takes only the frontend: it is
    // an interpreter over the shared AST, not a consumer of the pipeline. It
    // takes `kernels` (std-only leaves) for the §9.4.3 C real conversion the
    // analog devices already run, so both engines print one way — and its
    // §17.2 files go through `file_kernels` too, or through the device's own
    // table when a mixed simulation shares one (`contract.FileIo`, VAMS §9.5.1.2).
    .{ .name = "sim", .path = "src/sim/root.zig", .imports = &.{ "contract", "diag", "frontend", "kernels" } },
    .{ .name = "vpi", .path = "src/vpi/root.zig", .imports = &.{ "frontend", "ir", "vera", "sim" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mods = defineModules(b, target);

    // The CLI takes the engine as MODULES. It used to `@import("root.zig")` by
    // path, which compiled the entire engine a SECOND time into this module's
    // file set — 62k lines built twice per build.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = mods,
    });
    const exe = b.addExecutable(.{ .name = "vera", .root_module = cli_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the vera CLI").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run every test suite");

    // ONE TEST ARTIFACT PER MODULE, and not one artifact over `test_all.zig`:
    // `zig test` collects tests only from the ROOT module's own file set, so a
    // cross-module `_ = @import(...)` contributes ZERO tests. A module's tests
    // run in a build of that module, or they do not run. Each gets a step of its
    // own too, so `zig build test-ir` runs 66 tests without building the backend.
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
    // The CLI has no tests of its own; what `test` owes it is that it COMPILES.
    // A test artifact over main.zig analysed nothing (Zig is lazy and there was
    // no test to reach it), so the dependency is on the executable itself.
    test_step.dependOn(&exe.step);
    // `tests/test_all.zig` is the one compilation that has every module at once,
    // and it owns the claims that span two of them.
    const all_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = mods,
    });
    // ONE PATH, because the exhaustiveness guard (`tests/exhaustive.zig`) reads
    // `lib/` and `src/` as SOURCE at test time and the test's cwd is wherever
    // `zig build` was typed. It is absolute for the reason `fixture_root` is.
    const repo = b.addOptions();
    repo.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    all_mod.addOptions("repo_options", repo);
    test_step.dependOn(testRun(b, "test_all", all_mod, runner));

    // The suite runner's options are the FOUR PATHS it cannot compute itself,
    // and nothing else. Every one is absolute and so needs `b.pathFromRoot` or
    // `b.graph.zig_exe`; anything that was merely a default (the foreign
    // compiler's command line, the fixture optimize mode) is a constant in the
    // runner, where it is one edit instead of an option plumbed through two
    // files. The two directories the SUITE is about are here because a runner
    // that could disagree about which fixtures to walk, or about which LRM
    // their `//! lrm` lines cite, would be grading a different suite under the
    // same verdict vocabulary.
    const o = b.addOptions();
    o.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    o.addOption([]const u8, "docs_root", b.pathFromRoot("docs"));
    o.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-suite"));
    o.addOption([]const u8, "contract", b.pathFromRoot("tools/contract.zig"));
    // The `.c` fixtures are compiled against the SHIPPED header, not a copy, so
    // the directory is named here for the same reason `fixture_root` is: a
    // runner that could disagree about which `vpi_user.h` it means would be
    // grading a different ABI.
    o.addOption([]const u8, "vpi_include", b.pathFromRoot("src/vpi"));
    // Which `.c` fixtures RUN (`vpi_runs` below): `--coverage` counts a `.c`
    // fixture's `//! lrm` tags only for these, because compiling is not
    // runtime evidence. Passed, not copied, so the two cannot disagree.
    o.addOption([]const []const u8, "vpi_runs", &vpi_run_paths);
    o.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    const suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = byName(mods, "vera") }},
    });
    suite_mod.addOptions("suite_options", o);
    // An executable and not a `test` block on purpose: a failing fixture must
    // print the whole failing set in one run instead of aborting at the first
    // assert. Its own unit tests (the assertion lint, the verdict tally, the
    // emitted-size table) DO go on `test` — they are milliseconds, and they are
    // what stops a fixture from asserting nothing while looking like it does.
    const suite_exe = b.addExecutable(.{ .name = "vera-suite", .root_module = suite_mod });
    test_step.dependOn(testRun(b, "suite", suite_mod, runner));

    // THE suite step. No mode argument: the runner takes the `vera` path and
    // then whatever the user wrote after `--`.
    const bench = b.addRunArtifact(suite_exe);
    bench.addArtifactArg(exe);
    if (b.args) |a| bench.addArgs(a);
    b.step(
        "benchmark",
        "Run every fixture through VerA — compile, build, run, judge — and time it " ++
            "(`-- --against-openvaf` for the head-to-head; USE -Doptimize=ReleaseFast: " ++
            "that is the shipping number, and the default Debug is several times slower)",
    ).dependOn(&bench.step);

    // The other run of the same executable: `vera --run` over every `.v` under
    // `tests/fixtures/digital/` that has a committed transcript beside it.
    // `addArtifactArg` is what makes the built `vera` a dependency of this run,
    // so it cannot race the compiler it is testing.
    //
    // NOT ON `test`, and that changed when `tests/pending` merged into the
    // fixture tree: 62 of these 66 cases are D03 strengths, D06 delays, D08
    // gates and D09 timing — approved behaviour this compiler does not have
    // yet. They belong beside the clause they pin, and a red `zig build test`
    // that is red on purpose is a gate nobody reads. `test` is the milliseconds
    // that must be green; the suite is where the debt is counted.
    //
    // NO `expectExitCode`, deliberately: a Run step with a stdio check becomes
    // cacheable, and every real input of this one — the `.v` sources, the
    // committed transcripts — is read at RUN time and invisible to the build
    // graph, so a cached pass would be a pass for a golden nobody compared.
    const dev = b.addRunArtifact(suite_exe);
    dev.addArtifactArg(exe);
    dev.addArg("devices");
    b.step("test-devices", "Run `vera --run` over the digital fixtures and diff their transcripts")
        .dependOn(&dev.step);

    // The 26 `.c` fixtures. `harness.zig:collect` walks `.va` and `.v`; these
    // are neither, and are not VerA source at all — a VPI fixture is a C
    // translation unit, and the question it asks is whether the ABI exists with
    // the shape Clause 11 and Clause 12 describe. A C compiler is what asks it,
    // for the same reason `vpi_app.c` below is C and not a Zig test.
    //
    // It COMPILES them and reports a census; it does not link or run them.
    // Running needs a simulator host per design — `p02_design.v` through the
    // digital path, five `.va` designs through the analog one — and the
    // routines themselves. That is P02 and P03, `ROADMAP.md` v0.9.0.
    //
    // NOT on `test`, for the reason `test-devices` gives above: 13 of the 26 do
    // not compile today, because `src/vpi/vpi_user.h` declares the eleven P01
    // object-model routines and nothing of §12.16's value access, §12.20's
    // callbacks, the systf registration or the mcd family. A red `zig build
    // test` that is red on purpose is a gate nobody reads.
    //
    // No `expectExitCode` here either, and for the same cacheability reason:
    // every real input — the `.c` sources, the two shared headers,
    // `src/vpi/vpi_user.h` — is read at RUN time by a spawned compiler and is
    // invisible to the build graph.
    const vpi_fx = b.addRunArtifact(suite_exe);
    vpi_fx.addArtifactArg(exe);
    vpi_fx.addArg("vpi");
    b.step("test-vpi-fixtures", "Compile the 26 .c VPI fixtures against src/vpi/vpi_user.h")
        .dependOn(&vpi_fx.step);

    // The 7 `.sp` decks. Also not VerA source: a SPICE netlist naming a model
    // through `.hdl`, plus instance cards and an analysis card, paired with an
    // `.expected.json` holding an analytic oracle.
    //
    // NOT executed, and not because of a missing release: running a deck needs
    // a circuit simulator to link the compiled device and turn the Newton loop,
    // and that simulator is ARPice, which is not in this repository
    // (`ROADMAP.md §6`). The step checks the half that IS here — the deck has
    // an oracle, every model it names resolves, every model compiles — and
    // says plainly in its own output that it ran no circuit.
    const spice = b.addRunArtifact(suite_exe);
    spice.addArtifactArg(exe);
    spice.addArg("spice");
    b.step("test-spice", "Check the 7 .sp decks pair with an oracle and name models that compile")
        .dependOn(&spice.step);

    // The VPI acceptance test, and the reason `test-vpi` is not just the module
    // loop's `addTest`: a VPI implementation is only tested FROM C. The loop
    // above already gave `vpi` its Zig tests, and a Zig test calling these
    // functions checks that VerA agrees with itself. `tests/vpi_app.c` is a real
    // C translation unit compiled against `src/vpi/vpi_user.h` — so every
    // constant it names is the HEADER's number rather than the implementation's,
    // and an assertion like `vpi_get(vpiType, m) == vpiModule` is what keeps the
    // two in step — and linked against the `export fn`s in `src/vpi/root.zig`.
    // That is the only way the ABI — the constant VALUES, the parameter types,
    // the `char *` lifetimes — is under test at all.
    //
    // `tests/vpi_host.zig` is the SIMULATOR half: it elaborates
    // `tests/vpi_design.va`, installs the object model, and calls §12.33.2's
    // `vlog_startup_routines`, which is the application's only entry point.
    //
    // All three files were deleted by `2cc1c08`, a DOCS commit, and restored
    // here from `2cc1c08^`. Nothing else in the tree had been updated to reflect
    // their absence, which is why `src/vpi/root.zig` never stopped citing them.
    //
    // The host is built ONCE, as a static library exporting C's `main`, and
    // each application is one C file linked against it: a Zig executable per
    // application would compile the whole engine once per application.
    // Where an analog application's device library is built (§12.31.3 needs
    // a solver in this process: `vera.tb.renderVpiLib`), with what, and the
    // `contract` it imports. The host runs with the cache as its cwd, so
    // every path here is absolute.
    const host_opts = b.addOptions();
    host_opts.addOption([]const u8, "contract", b.pathFromRoot("tools/contract.zig"));
    host_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    host_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-vpi"));
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
            },
        }),
    });
    const test_vpi = &b.top_level_steps.get("test-vpi").?.step;
    const vpi_app = vpiApp(b, target, optimize, vpi_host, "tests/vpi_app.c", "tests");
    vpi_app.expectExitCode(0);
    // The counts are the design's own shape (tests/vpi_design.va: three levels,
    // two instances of one definition), and `checks` is how many assertions the
    // application reached — a walk that returned early counts fewer of them and
    // still exits 0, which is the failure this number is here to catch. The
    // census line is asserted as well as the exit code, because an exit code
    // alone cannot tell "every check passed" from "the startup table was never
    // called".
    vpi_app.expectStdOutEqual("vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=711\n");
    test_step.dependOn(&vpi_app.step);
    // `test-vpi` is a top-level step the module loop already created; this is
    // the C half joining it, rather than a second step with the same name.
    test_vpi.dependOn(&vpi_app.step);

    // The C fixtures that RUN: each is paired with the design it was written
    // against, executed on `src/sim`'s engine by `vpi.run.simulate`, and
    // asserted by exit code and its exact stdout (and, where the fixture
    // reports there, stderr). `test-vpi-fixtures` compiles all of them; these
    // are the ones whose routines, design and engine exist end to end.
    for (vpi_runs) |f| {
        const r = vpiApp(b, target, optimize, vpi_host, f.c, std.fs.path.dirname(f.c).?);
        r.addFileArg(b.path(f.design));
        // An analog design's application names its analyses in its own
        // banner (`*! analysis`); the host reads them there.
        if (std.mem.endsWith(u8, f.design, ".va")) r.addFileArg(b.path(f.c));
        // Channels a fixture opens (§12.26) land in the cwd, which is the
        // cache and not the source tree.
        r.setCwd(b.path(".zig-cache"));
        r.expectExitCode(0);
        r.expectStdOutEqual(f.stdout);
        if (f.stderr) |e| r.expectStdErrEqual(e);
        test_step.dependOn(&r.step);
        test_vpi.dependOn(&r.step);
    }
}

/// A C application at `c`, compiled against src/vpi/vpi_user.h (and its own
/// directory, for a fixture's shared header) with `vpi_app.c`'s flags, linked
/// against the host library, and run.
fn vpiApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    host: *std.Build.Step.Compile,
    c: []const u8,
    dir: []const u8,
) *std.Build.Step.Run {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path(c), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
    mod.addIncludePath(b.path("src/vpi"));
    mod.addIncludePath(b.path(dir));
    mod.linkLibrary(host);
    const name = std.fs.path.stem(c);
    return b.addRunArtifact(b.addExecutable(.{ .name = b.fmt("vpi-{s}", .{name}), .root_module = mod }));
}

/// One runnable VPI application: its C file, the design it runs against, and
/// the exact output it must produce. The `checks=N` counts are read off the
/// first green run, as `vpi_app.c`'s `checks=711` was: a run that returns
/// early reaches fewer checks and still exits 0.
const VpiRun = struct { c: []const u8, design: []const u8, stdout: []const u8, stderr: ?[]const u8 = null };

/// NOT here, each for a reason outside the routine it exercises:
///   p02_10  a $systf call in digital code — the engine has no user-systf call
///   p02_11  an analog $systf — needs an analog solver in this process
///   p03_07/90, p02_11  an analog system TASK whose calltf writes an output
///           argument (§12.22.2's $resistor): the device calls user system
///           FUNCTIONS only (`contract.SystfHost` returns one value)
///   p03_09  an `ac` analysis — no small-signal solve runs in this process
///   audit_builtin_override, audit_lazy_arguments — a user $systf call,
///           as p02_10
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
        .stdout = "p02 printf 7 ok\np02: 09_printf_mcd checks=27\np02_design: t=20 reached\n",
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
        .stdout = "p02: 01_get_value_formats checks=48\np02_design: t=20 reached\n",
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
        .stdout = "p02: 05_cb_time_regions checks=76\np02_design: t=20 reached\n",
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
        .stdout = "p02: p04_05_vlog_info checks=29\n",
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
        .stdout = "p02: p04_09_systf_build checks=62\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_10_primitives.c",
        .design = "tests/fixtures/ch11_vpi/p04_prims.v",
        .stdout = "p02: p04_10_primitives checks=93\n",
    },
    .{
        .c = "tests/fixtures/ch11_vpi/p04_11_instance_scopes.c",
        .design = "tests/fixtures/ch11_vpi/p04_scopes.v",
        .stdout = "p02: p04_11_instance_scopes checks=23\n",
    },
};

/// `vpi_runs`' C paths, for the suite's `--coverage` (see `vpi_runs` option).
const vpi_run_paths = blk: {
    var paths: [vpi_runs.len][]const u8 = undefined;
    for (vpi_runs, &paths) |r, *p| p.* = r.c;
    break :blk paths;
};

/// Create every module in `module_specs`, resolving each spec's imports against
/// the ones already created. `addModule` and not `createModule` because an
/// embedder takes the engine from here; the order of the table is the layering,
/// and a forward reference is a panic rather than a silently different graph.
fn defineModules(b: *std.Build, target: std.Build.ResolvedTarget) []const std.Build.Module.Import {
    var created: std.ArrayList(std.Build.Module.Import) = .empty;
    for (module_specs) |spec| {
        var deps: std.ArrayList(std.Build.Module.Import) = .empty;
        for (spec.imports) |dep_name| {
            const found = for (created.items) |c| {
                if (std.mem.eql(u8, c.name, dep_name)) break c;
            } else @panic("module imported before it was defined: check module_specs order");
            deps.append(b.allocator, found) catch @panic("OOM");
        }
        const mod = b.addModule(spec.name, .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .imports = deps.items,
        });
        created.append(b.allocator, .{ .name = spec.name, .module = mod }) catch @panic("OOM");
    }
    return created.items;
}

fn byName(mods: []const std.Build.Module.Import, name: []const u8) *std.Build.Module {
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.module;
    }
    @panic("no such module: check module_specs");
}

/// One test artifact over `mod`, run. `CLICOLOR_FORCE` is what makes zrunner's
/// report colored when the build captures its output.
fn testRun(
    b: *std.Build,
    name: []const u8,
    mod: *std.Build.Module,
    runner: std.Build.Step.Compile.TestRunner,
) *std.Build.Step {
    const r = b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = mod,
        .test_runner = runner,
    }));
    r.setEnvironmentVariable("CLICOLOR_FORCE", "true");
    return &r.step;
}
