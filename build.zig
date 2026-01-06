const std = @import("std");

/// VerA builds one binary and exposes two modules.
///
/// The binary is `vera`: the Verilog-A compiler (src/cli.zig).
/// The modules are for an embedder — a simulator that wants to compile Verilog-A
/// in-process rather than shell out:
///
///   vera       the Verilog-A engine — `.va` in, device Zig out
///   contract   the ABI that generated device code imports
///
/// `contract` is public as a MODULE and reachable as a PATH
/// (`dep.path("tools/contract.zig")`), because the CLI hands it to
/// `zig build-obj` on the command line while an embedder imports it. Same file
/// both ways, which is the point of it living here.
///
/// It sits in `tools/` and not in `src/` because nothing in the compiler imports
/// it: every reference is either a string inside generated code or a path handed
/// to a child `zig`. It is a shipped artifact compiled into DEVICES, never into
/// `vera`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const contract_mod = b.addModule("contract", .{
        .root_source_file = b.path("tools/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vera_mod = b.addModule("vera", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "vera", .root_module = cli_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the vera CLI").dependOn(&run_cmd.step);

    // =======================================================================
    // Tests
    //
    // One root PER MODULE: `zig test` collects tests only from the root module's
    // own file set, so a cross-module `_ = @import(...)` silently contributes
    // zero tests. `src/root.zig` ends in a `test { _ = <sibling>; }`
    // aggregator, which is what pulls the whole engine in from one root.
    //
    // The CLI module carries no tests of its own, so it gets no step.
    // =======================================================================

    const test_step = b.step("test", "Run every test suite");

    const run_va_test = b.addRunArtifact(b.addTest(.{ .root_module = vera_mod }));
    b.step("test-va", "Run the Verilog-A engine tests").dependOn(&run_va_test.step);
    test_step.dependOn(&run_va_test.step);

    // `contract` is a module root of its own and NOTHING in this build imports it
    // — generated device code does, at its own build time — so `test-va` collects
    // zero of its tests. They ran nowhere until this step existed, which is how a
    // stale `num_ports` guard survived two waves of the engine growing past it.
    const run_contract_test = b.addRunArtifact(b.addTest(.{ .root_module = contract_mod }));
    const contract_step = b.step("test-contract", "Run the device-contract and source-tree guards");
    contract_step.dependOn(&run_contract_test.step);
    test_step.dependOn(&run_contract_test.step);

    // The source-tree guards ride the same step and are a SEPARATE module on
    // purpose: `contract_mod` is compiled into every generated device, so it may
    // not import build options and may not assume a source tree exists. See
    // tools/source_guards.zig's header.
    const guard_opts = b.addOptions();
    guard_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    guard_opts.addOption([]const u8, "src_root", b.pathFromRoot("src"));
    const guard_mod = b.createModule(.{
        .root_source_file = b.path("tools/source_guards.zig"),
        .target = target,
        .optimize = optimize,
    });
    guard_mod.addOptions("guard_options", guard_opts);
    const run_guard_test = b.addRunArtifact(b.addTest(.{ .root_module = guard_mod }));
    contract_step.dependOn(&run_guard_test.step);
    test_step.dependOn(&run_guard_test.step);

    // =======================================================================
    // The conformance suite over tests/fixtures/**/*.va, run against TWO
    // compilers by two runners sharing one judge:
    //
    //   tests/harness.zig    the fixture format, the verdict algebra, the report
    //   tests/torture.zig    VerA          `zig build torture`
    //   tests/external.zig   OpenVAF, …    `zig build conformance`
    //
    // Sharing the judge is the point: "OpenVAF scores X and VerA scores Y" only
    // means something if both were scored by the same code. What the runners
    // differ by is depth, and only that — VerA is compiled in-process and its
    // device is BUILT AND RUN, so the fixtures' own `ok=` assertions are
    // evaluated; a foreign compiler is a subprocess that can only accept or
    // refuse, and its report says so.
    //
    // Every fixture states its own expected behavior in the .va: `//! reject
    // <substring>` to demand a diagnostic, or a `CHECK` from
    // tests/fixtures/check.vh whose `ok=1` column is the assertion.
    //
    // An EXECUTABLE, not a `test` block, on purpose: a failing fixture must
    // print the whole failing set in one run instead of aborting at the first
    // assert.
    //
    // NOT in `test`: it spawns a `zig build-exe` per fixture, seconds rather
    // than milliseconds. Run it explicitly:
    //
    //   zig build torture              # every fixture, one per core
    //   zig build torture -- ch04      # only paths matching `ch04`
    //   zig build torture -- --strict  # unasserted fixtures FAIL instead of warn
    //   zig build torture -- -j1       # sequential and streaming; for debugging
    const contract_path = b.option(
        []const u8,
        "contract",
        "Root of the `contract` module the generated devices import",
    ) orelse b.pathFromRoot("tools/contract.zig");
    const torture_opts = b.addOptions();
    torture_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    torture_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-tb"));
    torture_opts.addOption([]const u8, "contract", contract_path);
    torture_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    // `-Doptimize` builds the RUNNER; this builds the per-fixture testbench
    // binaries the runner spawns a `zig build-exe` for. Two different programs,
    // so two different knobs. Debug is right for the fixtures and stays the
    // default — see the `//! fixture-opt` note in tests/torture.zig.
    //
    // Passed as the tag NAME, not the enum: `addOption` emits its own copy of
    // any enum type, which is then a different type from `std.builtin.
    // OptimizeMode` on the other side. The `b.option` call still validates the
    // spelling here, at build time.
    torture_opts.addOption([]const u8, "fixture_optimize", @tagName(b.option(
        std.builtin.OptimizeMode,
        "fixture-optimize",
        "Optimize mode for the per-fixture testbench binaries (default Debug)",
    ) orelse .Debug));
    const torture_mod = b.createModule(.{
        .root_source_file = b.path("tests/torture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = vera_mod }},
    });
    torture_mod.addOptions("torture_options", torture_opts);
    const run_torture = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-torture",
        .root_module = torture_mod,
    }));
    if (b.args) |a| run_torture.addArgs(a);
    b.step("torture", "Run the Verilog-A torture suite").dependOn(&run_torture.step);

    // The runner's own unit tests (the assertion lint, the verdict tally) DO
    // belong in `test`: they are milliseconds and they are what stops a fixture
    // from asserting nothing while looking like it asserts something.
    const run_torture_test = b.addRunArtifact(b.addTest(.{ .root_module = torture_mod }));
    test_step.dependOn(&run_torture_test.step);

    // The same fixtures against a FOREIGN compiler — the conformance question
    // the suite was rewritten to be able to ask. The default is OpenVAF, which
    // `nix develop .#conformance` puts on PATH; `-Dconformance-cc` takes any
    // compiler that accepts a .va path and exits nonzero when it refuses one,
    // and being a whole command line is also where a timeout goes.
    //
    //   zig build conformance
    //   zig build -Dconformance-cc="timeout 30 openvaf-r --dry-run" conformance -- ch04
    const external_opts = b.addOptions();
    external_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    external_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-conformance"));
    external_opts.addOption([]const u8, "cc", b.option(
        []const u8,
        "conformance-cc",
        "The compiler `zig build conformance` holds to the fixtures (default `openvaf-r --dry-run`)",
    ) orelse "openvaf-r --dry-run");
    const external_mod = b.createModule(.{
        .root_source_file = b.path("tests/external.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = vera_mod }},
    });
    external_mod.addOptions("external_options", external_opts);
    const run_external = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-conformance",
        .root_module = external_mod,
    }));
    if (b.args) |a| run_external.addArgs(a);
    b.step("conformance", "Run the fixtures against another Verilog-A compiler")
        .dependOn(&run_external.step);

    // Same reason `test-contract` exists: this module was built ONLY as the
    // `conformance` executable, and `conformance` needs OpenVAF on PATH, so its
    // tests ran on no machine that had not installed a foreign compiler. A test
    // that only runs behind an optional dependency is a test that rots.
    const run_external_test = b.addRunArtifact(b.addTest(.{ .root_module = external_mod }));
    test_step.dependOn(&run_external_test.step);

    // =======================================================================
    // The instrument. `zig build bench` prints one TSV line per (case, n,
    // phase); see tests/bench.zig for what the four phases are and why the
    // sweep is a curve rather than a number.
    //
    // NOT in `test`, for the same reason `torture` is not: the 4096-point of
    // the sweep and the 1152-fixture batch are seconds each, times N=25. But
    // the bench's own unit tests ARE — the emitted-size table is a size
    // regression on the device, and a regression check that runs only when
    // someone remembers to run `bench` is not a check.
    //
    //   zig build bench                # the sweep and the fixture batch
    //   zig build bench -- gen         # the generated sweep only
    //   zig build bench -- fixtures    # the 1152 fixtures as one batch
    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    bench_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-bench"));
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = vera_mod }},
    });
    bench_mod.addOptions("bench_options", bench_opts);
    const run_bench = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-bench",
        .root_module = bench_mod,
    }));
    if (b.args) |a| run_bench.addArgs(a);
    b.step("bench", "Time the four compile phases over a size sweep").dependOn(&run_bench.step);

    const run_bench_test = b.addRunArtifact(b.addTest(.{ .root_module = bench_mod }));
    test_step.dependOn(&run_bench_test.step);
}
