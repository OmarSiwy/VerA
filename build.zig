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

    _ = b.addModule("contract", .{
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

    // =======================================================================
    // The torture suite — the ONE oracle over tests/fixtures/**/*.va
    //
    // It replaced `conformance`, `exhaustive`, `sema.sh` and `ledger`, which
    // disagreed about what a fixture is and needed three sidecar file formats
    // between them. Every fixture now states its own expected behavior in the
    // .va: `//! reject <substring>` to demand a diagnostic, or a `CHECK` from
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
}
