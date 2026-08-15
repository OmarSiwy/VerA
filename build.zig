const std = @import("std");

/// VerA builds one binary and exposes three modules.
///
/// The binary is `vera`: both frontends behind an extension check (src/main.zig).
/// The modules are for an embedder — a simulator that wants to compile Verilog-A
/// in-process rather than shell out:
///
///   va         the Verilog-A engine — `.va` in, device Zig out
///   vf         the Verilog family — shells out to verilator/sv2v/ghdl
///   contract   the ABI that generated device code imports
///
/// `contract` is public as a MODULE and reachable as a PATH
/// (`dep.path("src/contract.zig")`), because the CLI hands it to `zig build-obj`
/// on the command line while an embedder imports it. Same file both ways, which
/// is the point of it living here.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("contract", .{
        .root_source_file = b.path("src/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Public so an embedder can compile Verilog-A in-process instead of
    // shelling out to the binary. No aggregate facade over the two: every
    // consumer so far wants one frontend or the other, never both.
    const va_mod = b.addModule("va", .{
        .root_source_file = b.path("src/va/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vf_mod = b.addModule("vf", .{
        .root_source_file = b.path("src/vf/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =======================================================================
    // The binary
    // =======================================================================

    // src/main.zig reaches both frontends with relative `@import`s, so the whole
    // CLI is one module and there is nothing to wire.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
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
    // zero tests. Each root.zig ends in a `test { _ = <sibling>; }` aggregator,
    // which is what pulls a whole frontend in from one root.
    // =======================================================================

    const test_step = b.step("test", "Run every test suite");


    for ([_]struct { name: []const u8, desc: []const u8, mod: *std.Build.Module }{
        .{ .name = "test-va", .desc = "Run the Verilog-A engine tests", .mod = va_mod },
        .{ .name = "test-vf", .desc = "Run the Verilog frontend tests", .mod = vf_mod },
        // The CLI carries its own tests (argv routing, module-name readback) and
        // is not reachable from either frontend root.
        .{ .name = "test-cli", .desc = "Run the vera CLI tests", .mod = cli_mod },
    }) |suite| {
        const run = b.addRunArtifact(b.addTest(.{ .root_module = suite.mod }));
        b.step(suite.name, suite.desc).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // Verilog conformance: translate each fixture, compile it against the real
    // contract, then EXECUTE it against hand-written truth-table vectors. A
    // static shape check would happily accept an `and2` that emits `a | b`.
    const vf_conf_opts = b.addOptions();
    vf_conf_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    vf_conf_opts.addOption([]const u8, "contract_path", b.pathFromRoot("src/contract.zig"));
    const vf_conf_mod = b.createModule(.{
        .root_source_file = b.path("tests/vf/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zvf", .module = vf_mod }},
    });
    vf_conf_mod.addOptions("conf_opts", vf_conf_opts);
    const run_vf_conf = b.addRunArtifact(b.addTest(.{ .root_module = vf_conf_mod }));
    b.step("conformance-vf", "Run the Verilog fixture conformance suite").dependOn(&run_vf_conf.step);
    test_step.dependOn(&run_vf_conf.step);

    // =======================================================================
    // Verilog-A oracles
    //
    // EXECUTABLES, not `test` blocks, on purpose: a failing fixture must print
    // the whole failing set in one run instead of aborting at the first assert.
    // =======================================================================

    // The BEHAVIORAL oracle: every tests/va/fixtures/**/*.va through
    // compileSource, checked against its sibling `.expected-error.txt`.
    const va_conf_opts = b.addOptions();
    va_conf_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/va/fixtures"));
    const va_conf_mod = b.createModule(.{
        .root_source_file = b.path("tests/va/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = va_mod }},
    });
    va_conf_mod.addOptions("conformance_options", va_conf_opts);
    const run_va_conf = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-conformance",
        .root_module = va_conf_mod,
    }));
    b.step("conformance", "Run the Verilog-A fixture conformance suite").dependOn(&run_va_conf.step);
    test_step.dependOn(&run_va_conf.step);

    // The SEMANTIC oracle: every tests/va/fixtures/exhaustive/*.va becomes a
    // native testbench binary (ch9 display tasks on, plus the `//!` operating
    // points) whose transcript is diffed against the committed `.expected.txt`.
    //
    // NOT in `test`: it spawns a `zig build-exe` per fixture, seconds rather
    // than milliseconds. Run it explicitly:
    //
    //   zig build exhaustive              # check every transcript
    //   zig build exhaustive -- 04_       # only fixtures matching `04_`
    //   zig build exhaustive -- --bless   # (re)write them, then READ the diff
    const contract_path = b.option(
        []const u8,
        "contract",
        "Root of the `contract` module the generated devices import",
    ) orelse b.pathFromRoot("src/contract.zig");
    const exh_opts = b.addOptions();
    exh_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/va/fixtures/exhaustive"));
    exh_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-tb"));
    exh_opts.addOption([]const u8, "contract", contract_path);
    exh_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const exh_mod = b.createModule(.{
        .root_source_file = b.path("tests/va/exhaustive.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fastvaf", .module = va_mod }},
    });
    exh_mod.addOptions("exhaustive_options", exh_opts);
    const run_exh = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-exhaustive",
        .root_module = exh_mod,
    }));
    if (b.args) |a| run_exh.addArgs(a);
    b.step("exhaustive", "Run the Verilog-A testbench transcripts").dependOn(&run_exh.step);
}
