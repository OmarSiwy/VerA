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
    // analog devices already run, so both engines print one way.
    .{ .name = "sim", .path = "src/sim/root.zig", .imports = &.{ "diag", "frontend", "kernels" } },
    .{ .name = "vpi", .path = "src/vpi/root.zig", .imports = &.{ "frontend", "ir", "vera" } },
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
    const vpi_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/vpi_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vera", .module = byName(mods, "vera") },
            .{ .name = "vpi", .module = byName(mods, "vpi") },
        },
    });
    vpi_host_mod.addCSourceFile(.{
        .file = b.path("tests/vpi_app.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Werror" },
    });
    vpi_host_mod.addIncludePath(b.path("src/vpi"));
    const vpi_app = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-vpi-app",
        .root_module = vpi_host_mod,
    }));
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
    b.top_level_steps.get("test-vpi").?.step.dependOn(&vpi_app.step);
}

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
