const std = @import("std");

/// VerA builds one binary and exposes compiler and runtime modules.
///
/// The binary is `vera`: the Verilog-A compiler (src/cli.zig).
/// The modules are for an embedder — a simulator that wants to compile Verilog-A
/// in-process rather than shell out:
///
///   vera       the Verilog-A engine — `.va` in, device Zig out
///   contract   the ABI that generated device code imports
///   sim        event scheduler infrastructure (no HDL process execution yet)
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
    // Bottom of the compiler DAG: diagnostics depend on nothing but std, and
    // every stage depends on them. A module rather than a relative import so
    // `zig build test-diag` runs its 20 tests without the engine, and so the
    // layering is declared in the build graph instead of by convention.
    const diag_mod = b.addModule("diag", .{
        .root_source_file = b.path("src/diag.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Text -> AST. Depends on `diag` and nothing else in the engine; `ir/` and
    // `backend/` import it and never the reverse.
    const frontend_mod = b.addModule("frontend", .{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "diag", .module = diag_mod }},
    });

    // The emitted device-runtime kernels, as a DEPENDENCY (its test-root half
    // is wired separately below). `ir` takes it for rng only.
    const kernels_mod = b.addModule("kernels", .{
        .root_source_file = b.path("src/backend/kernels.zig"),
        .target = target,
        .optimize = optimize,
    });

    // AST -> proven MIR. One module around the lower/elaborate cycle, which is
    // deliberate: the two are halves of one transformation.
    const ir_mod = b.addModule("ir", .{
        .root_source_file = b.path("src/ir/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "frontend", .module = frontend_mod },
            .{ .name = "kernels", .module = kernels_mod },
        },
    });

    // MIR -> device. One module around the codegen/cg_* cycle, same reasoning
    // as `ir`: the boundary goes around the cycle rather than through it.
    const backend_mod = b.addModule("backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "frontend", .module = frontend_mod },
            .{ .name = "ir", .module = ir_mod },
            .{ .name = "kernels", .module = kernels_mod },
        },
    });

    // The facade. Re-export and pipeline driving only now — every stage it
    // sequences is a module of its own.
    const vera_mod = b.addModule("vera", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diag", .module = diag_mod },
            .{ .name = "frontend", .module = frontend_mod },
            .{ .name = "ir", .module = ir_mod },
            .{ .name = "backend", .module = backend_mod },
            .{ .name = "kernels", .module = kernels_mod },
        },
    });

    // The CLI takes the engine as a MODULE. It used to `@import("root.zig")`
    // by path, which compiled the entire engine a SECOND time into this
    // module's file set — 62k lines built twice per build.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = vera_mod }},
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

    // Scheduler infrastructure is independently testable without the compiler.
    const sim_mod = b.addModule("sim", .{
        .root_source_file = b.path("src/sim/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "frontend", .module = frontend_mod }, .{ .name = "diag", .module = diag_mod } },
    });
    cli_mod.addImport("sim", sim_mod);
    const sim_tests = b.addRunArtifact(b.addTest(.{ .root_module = sim_mod }));
    b.step("test-sim", "Run event scheduler tests").dependOn(&sim_tests.step);
    test_step.dependOn(&sim_tests.step);
    const digital_cli = b.addRunArtifact(exe);
    digital_cli.addArg("--run");
    digital_cli.addFileArg(b.path("tests/digital/scheduling.v"));
    digital_cli.expectStdOutEqual(@embedFile("tests/digital/scheduling.expected.txt"));
    const digital_step = b.step("test-digital", "Run shared-frontend digital source execution tests");
    digital_step.dependOn(&digital_cli.step);
    test_step.dependOn(&digital_cli.step);
    const expression_cli = b.addRunArtifact(exe);
    expression_cli.addArg("--run");
    expression_cli.addFileArg(b.path("tests/digital/expressions.v"));
    expression_cli.expectStdOutEqual(@embedFile("tests/digital/expressions.expected.txt"));
    digital_step.dependOn(&expression_cli.step);
    test_step.dependOn(&expression_cli.step);
    const control_cli = b.addRunArtifact(exe);
    control_cli.addArg("--run");
    control_cli.addFileArg(b.path("tests/digital/control.v"));
    control_cli.expectStdOutEqual(@embedFile("tests/digital/control.expected.txt"));
    digital_step.dependOn(&control_cli.step);
    test_step.dependOn(&control_cli.step);
    const concatenation_cli = b.addRunArtifact(exe);
    concatenation_cli.addArg("--run");
    concatenation_cli.addFileArg(b.path("tests/digital/concatenation.v"));
    concatenation_cli.expectStdOutEqual(@embedFile("tests/digital/concatenation.expected.txt"));
    digital_step.dependOn(&concatenation_cli.step);
    test_step.dependOn(&concatenation_cli.step);

    // Exercise generated state hooks against a host, not just emitted text.
    const limiter_gen = b.addRunArtifact(exe);
    limiter_gen.addArgs(&.{ "--emit-zig", "--allow=W0850", "-I" });
    limiter_gen.addDirectoryArg(b.path("tests/fixtures"));
    limiter_gen.addFileArg(b.path("tests/fixtures/ch09_system_tasks/179_limit_initialize_limiting.va"));
    limiter_gen.addArg("-o");
    const limiter_src = limiter_gen.addOutputFileArg("limiter.zig");
    const limiter_mod = b.createModule(.{
        .root_source_file = limiter_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract_mod }},
    });
    const limiter_test = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/limiter_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "device", .module = limiter_mod }},
    }) }));
    b.step("test-limiter-host", "Check generated limiter state against host calls").dependOn(&limiter_test.step);
    test_step.dependOn(&limiter_test.step);

    const table_snapshot_gen = b.addRunArtifact(exe);
    table_snapshot_gen.addArgs(&.{ "--emit-zig", "--allow=W0850", "-I" });
    table_snapshot_gen.addDirectoryArg(b.path("tests/fixtures"));
    table_snapshot_gen.addFileArg(b.path("tests/fixtures/ch09_system_tasks/187_table_snapshot.va"));
    table_snapshot_gen.addArg("-o");
    const table_snapshot_src = table_snapshot_gen.addOutputFileArg("table_snapshot.zig");
    const table_snapshot_mod = b.createModule(.{
        .root_source_file = table_snapshot_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract_mod }},
    });
    const table_snapshot_test = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/table_snapshot_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "device", .module = table_snapshot_mod }},
    }) }));
    b.step("test-table-snapshot-host", "Check first-call table snapshots across instances and rejected trials").dependOn(&table_snapshot_test.step);
    test_step.dependOn(&table_snapshot_test.step);

    const rng_effects_gen = b.addRunArtifact(exe);
    rng_effects_gen.addArg("--emit-zig");
    rng_effects_gen.addFileArg(b.path("tests/rng_effects.va"));
    rng_effects_gen.addArg("-o");
    const rng_effects_src = rng_effects_gen.addOutputFileArg("rng_effects.zig");
    const rng_effects_mod = b.createModule(.{
        .root_source_file = rng_effects_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract_mod }},
    });
    const rng_default_gen = b.addRunArtifact(exe);
    rng_default_gen.addArg("--emit-zig");
    rng_default_gen.addFileArg(b.path("tests/rng_default_domain.va"));
    rng_default_gen.addArg("-o");
    const rng_default_src = rng_default_gen.addOutputFileArg("rng_default_domain.zig");
    const rng_default_mod = b.createModule(.{
        .root_source_file = rng_default_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract_mod }},
    });
    const rng_effects = b.addExecutable(.{
        .name = "rng-effects",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rng_effects_host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "device", .module = rng_effects_mod },
                .{ .name = "default_device", .module = rng_default_mod },
            },
        }),
    });
    const rng_effects_step = b.step("test-rng-effects", "Check generated RNG domain errors retain conditional source effects");
    for (0..34) |case| {
        const rng_effect_test = b.addRunArtifact(rng_effects);
        rng_effect_test.addArg(b.fmt("{d}", .{case}));
        rng_effect_test.expectExitCode(0);
        rng_effects_step.dependOn(&rng_effect_test.step);
        test_step.dependOn(&rng_effect_test.step);
    }

    const literal_gen = b.addRunArtifact(exe);
    literal_gen.addArgs(&.{ "--emit-zig", "--display=emit", "-I" });
    literal_gen.addDirectoryArg(b.path("tests"));
    literal_gen.addFileArg(b.path("tests/literal_nul.va"));
    literal_gen.addArg("-o");
    const literal_src = literal_gen.addOutputFileArg("literal_nul.zig");
    const literal_mod = b.createModule(.{
        .root_source_file = literal_src,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract_mod }},
    });
    const literal_test = b.addRunArtifact(b.addExecutable(.{
        .name = "literal-nul",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/literal_nul_host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "device", .module = literal_mod }},
        }),
    }));
    literal_test.expectStdErrEqual(
        "literal=[A\x00B] direct=[A\x00B] stored=[AB] assigned=[CD] parameter=[PQ]\n" ++
            "edges=[\x00A\x00B\x00] octal=[ABC]\n" ++
            "raw=[\x00A\x00] conversion=[A\x00] numeric=[A\x00] padded=[  A\x00]\n" ++
            "packed=[410042] decimal=[4259906]\n" ++
            "macro-format=[M\x00N]\n" ++
            "macro-operand=[M\x00N]\n" ++
            "macro-stored=[MN]\n" ++
            "stored-format=[AB] numeric=[AB] width=[   AB] packed=[410042]\n" ++
            "stored-write=[ABCD]\n",
    );
    b.step("test-literal-output", "Check literal output bytes and string storage conversion").dependOn(&literal_test.step);
    test_step.dependOn(&literal_test.step);

    const run_va_test = b.addRunArtifact(b.addTest(.{ .root_module = vera_mod }));
    b.step("test-va", "Run the Verilog-A engine tests").dependOn(&run_va_test.step);
    test_step.dependOn(&run_va_test.step);

    // Diagnostics. Their tests leave `test-va`'s root the moment `diag` becomes
    // a module — a cross-module `_ = @import(...)` contributes zero — so this
    // step is what keeps the 20 of them running at all.
    const run_diag_test = b.addRunArtifact(b.addTest(.{ .root_module = diag_mod }));
    b.step("test-diag", "Run diagnostic rendering tests").dependOn(&run_diag_test.step);
    test_step.dependOn(&run_diag_test.step);

    // Same reason as `diag`: once frontend is a module its 72 tests leave
    // `test-va`'s root and only this step runs them.
    const run_frontend_test = b.addRunArtifact(b.addTest(.{ .root_module = frontend_mod }));
    b.step("test-frontend", "Run preprocessor/lexer/parser tests").dependOn(&run_frontend_test.step);
    test_step.dependOn(&run_frontend_test.step);

    // ir's 66 tests leave `test-va` the moment it is a module.
    const run_ir_test = b.addRunArtifact(b.addTest(.{ .root_module = ir_mod }));
    b.step("test-ir", "Run elaborate/lower/ssa/proof tests").dependOn(&run_ir_test.step);
    test_step.dependOn(&run_ir_test.step);

    // backend's 90 tests — 61 of them codegen's — leave `test-va` with it.
    const run_backend_test = b.addRunArtifact(b.addTest(.{ .root_module = backend_mod }));
    b.step("test-backend", "Run codegen/naming/tb/orchestrator tests").dependOn(&run_backend_test.step);
    test_step.dependOn(&run_backend_test.step);

    // The emitted device-runtime kernels. `test-va` does reach them, but only
    // through codegen.zig's `@import`s — so touching a kernel meant compiling
    // codegen and the whole IR to run its tests. Their own root makes that a
    // few seconds, which is the difference between tests that get written for
    // 1796 lines of hot arithmetic and tests that do not.
    // Same module `ir` depends on, not a second copy of the file.
    // Compile the independent IEEE C listing alongside the emitted RNG kernels.
    const rng_reference_mod = b.createModule(.{
        .root_source_file = b.path("tests/rng_reference.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "kernels", .module = kernels_mod }},
    });
    rng_reference_mod.addCSourceFile(.{
        .file = b.path("tests/rng_reference.c"),
        .flags = &.{"-ffp-contract=off"},
    });
    const rng_reference_test = b.addRunArtifact(b.addTest(.{ .root_module = rng_reference_mod }));
    const rng_step = b.step("test-rng-reference", "Compare RNG values and seeds with compiled IEEE C, and check runtime domains");
    rng_step.dependOn(&rng_reference_test.step);
    test_step.dependOn(&rng_reference_test.step);
    const rng_domains = b.addExecutable(.{
        .name = "rng-domains",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/rng_domains.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "kernels", .module = kernels_mod }},
        }),
    });
    for (0..40) |case| {
        const domain_test = b.addRunArtifact(rng_domains);
        domain_test.addArg(b.fmt("{d}", .{case}));
        domain_test.expectExitCode(0);
        rng_step.dependOn(&domain_test.step);
        test_step.dependOn(&domain_test.step);
    }

    const run_kernels_test = b.addRunArtifact(b.addTest(.{ .root_module = kernels_mod }));
    b.step("test-kernels", "Run the emitted device-runtime kernel tests")
        .dependOn(&run_kernels_test.step);
    test_step.dependOn(&run_kernels_test.step);

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
    // The two directories the SUITE is about, shared by both runners because
    // `tests/harness.zig` reads them and the harness is the shared judge: a
    // runner that could disagree about which fixtures to walk, or about which
    // LRM their `//! lrm` lines cite, would be grading a different suite under
    // the same verdict vocabulary. `docs` is read by `--coverage`, to diff the
    // cited clauses against the contents page — until it could, nothing checked
    // that a cite named a clause that exists.
    const suite_opts = b.addOptions();
    suite_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/fixtures"));
    suite_opts.addOption([]const u8, "docs_root", b.pathFromRoot("docs"));

    const torture_opts = b.addOptions();
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
    torture_mod.addOptions("suite_options", suite_opts);
    const run_torture = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-torture",
        .root_module = torture_mod,
    }));
    if (b.args) |a| run_torture.addArgs(a);
    b.step("torture", "Run the Verilog-A torture suite").dependOn(&run_torture.step);

    // The SAME runner over `tests/pending`, which is the approved-but-not-yet-
    // implemented suite. These fixtures are SUPPOSED to fail: each one encodes
    // behavior the standard requires and this compiler does not have yet, so a
    // nonzero exit is the expected state and this step is deliberately NOT on
    // `test` or on any gate. Its output is the number that matters during
    // implementation — how many of them have started passing — which until now
    // could not be obtained at all, because `fixture_root` was one hardcoded
    // path and nothing walked `tests/pending`.
    //
    // A separate options object and work_root rather than a `-Dfixture-root`
    // knob on the existing one: the 1323/1323 gate should keep meaning exactly
    // what it means today, and two runners writing testbenches for
    // same-named fixtures into one directory would race.
    const pending_suite_opts = b.addOptions();
    pending_suite_opts.addOption([]const u8, "fixture_root", b.pathFromRoot("tests/pending"));
    pending_suite_opts.addOption([]const u8, "docs_root", b.pathFromRoot("docs"));
    const pending_torture_opts = b.addOptions();
    pending_torture_opts.addOption([]const u8, "work_root", b.pathFromRoot(".zig-cache/vera-tb-pending"));
    pending_torture_opts.addOption([]const u8, "contract", contract_path);
    pending_torture_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    pending_torture_opts.addOption([]const u8, "fixture_optimize", "Debug");
    const pending_mod = b.createModule(.{
        .root_source_file = b.path("tests/torture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vera", .module = vera_mod }},
    });
    pending_mod.addOptions("torture_options", pending_torture_opts);
    pending_mod.addOptions("suite_options", pending_suite_opts);
    const run_pending = b.addRunArtifact(b.addExecutable(.{
        .name = "vera-torture-pending",
        .root_module = pending_mod,
    }));
    if (b.args) |a| run_pending.addArgs(a);
    b.step("torture-pending", "Run the approved-but-unimplemented suite (expected to fail)")
        .dependOn(&run_pending.step);

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
    external_mod.addOptions("suite_options", suite_opts);
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
    // The instrument. `zig build bench` prints one TSV line per (mode, case, n,
    // phase); see tests/bench.zig for what the four phases are and why the
    // sweep is a curve rather than a number.
    //
    // NOT in `test`, for the same reason `torture` is not: the 4096-point of
    // the sweep and the 1164-fixture batch are seconds each, times N=25. But
    // the bench's own unit tests ARE — the emitted-size table is a size
    // regression on the device, and a regression check that runs only when
    // someone remembers to run `bench` is not a check.
    //
    // RELEASEFAST IS THE NUMBER THAT MEANS ANYTHING — it is what ships. This
    // module takes the tree's `-Doptimize`, which defaults to Debug, and Debug
    // is ~8x slower (fixture-batch `lint`: 1959.5 ms Debug, 247.0 ms
    // ReleaseFast, same commit). An entire wave of figures was quoted in Debug
    // because the TSV did not say which mode it was, so the mode is now column
    // 1 of the timing table.
    //
    // This step deliberately does NOT force ReleaseFast on itself, despite the
    // default being a trap. `-O` is per MODULE (std.Build.Module appends one
    // per module), and the code being timed lives in `vera_mod`: overriding
    // only `bench_mod` would time a ReleaseFast harness driving a Debug engine
    // — a third number that is neither of the two anyone wants — and would make
    // `builtin.mode` inside bench.zig, which is what prints the label, describe
    // the harness rather than the engine. Doing it honestly means a second
    // `vera` module built at a different mode than everything else `zig build`
    // produces. Printing the mode costs one column and closes the same hole.
    //
    //   zig build bench -Doptimize=ReleaseFast              # what ships
    //   zig build bench                                     # Debug, ~8x slower
    //   zig build bench -Doptimize=ReleaseFast -- gen       # the sweep only
    //   zig build bench -Doptimize=ReleaseFast -- fixtures  # the 1164 fixtures
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
    b.step(
        "bench",
        "Time the four compile phases over a size sweep (USE -Doptimize=ReleaseFast: " ++
            "that is the shipping number; the default Debug is ~8x slower)",
    ).dependOn(&run_bench.step);

    const run_bench_test = b.addRunArtifact(b.addTest(.{ .root_module = bench_mod }));
    test_step.dependOn(&run_bench_test.step);

    // =======================================================================
    // The VPI (LRM clauses 11 and 12).
    //
    // A MODULE, like every other stage, because an embedder that wants the
    // object model wants it without the CLI. It takes `frontend` and `ir`
    // directly — its input is `Lower.module`, the elaborated top, and
    // `Lower.hier_names`, the §6.7 path table — and `vera` only so its own
    // tests can compile a design to hand itself.
    const vpi_mod = b.addModule("vpi", .{
        .root_source_file = b.path("src/vpi/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "frontend", .module = frontend_mod },
            .{ .name = "ir", .module = ir_mod },
            .{ .name = "vera", .module = vera_mod },
        },
    });
    const run_vpi_test = b.addRunArtifact(b.addTest(.{ .root_module = vpi_mod }));
    const vpi_step = b.step("test-vpi", "Run the VPI object model tests and the compiled C application against them");
    vpi_step.dependOn(&run_vpi_test.step);
    test_step.dependOn(&run_vpi_test.step);

    // The acceptance test, and the reason this step is not just another
    // `addTest`: a VPI implementation is only tested from C. `tests/vpi_app.c`
    // is compiled against `src/vpi/vpi_user.h` — so every constant it names is
    // the HEADER's number rather than the implementation's, and an assertion
    // like `vpi_get(vpiType, m) == vpiModule` is what keeps the two in step —
    // and linked against the `export fn`s in `src/vpi/root.zig`.
    //
    // `tests/vpi_host.zig` is the SIMULATOR half: it elaborates
    // `tests/vpi_design.va`, installs the object model, and calls §12.33.2's
    // `vlog_startup_routines`, which is the application's only entry point.
    // The census line is asserted as well as the exit code, because an exit
    // code alone cannot tell "every check passed" from "the startup table was
    // never called".
    const vpi_host_mod = b.createModule(.{
        .root_source_file = b.path("tests/vpi_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vera", .module = vera_mod },
            .{ .name = "vpi", .module = vpi_mod },
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
    // still exits 0, which is the failure this number is here to catch.
    vpi_app.expectStdOutEqual("vpi: scopes=5 ports=11 nets=6 regs=2 params=8 checks=711\n");
    vpi_step.dependOn(&vpi_app.step);
    test_step.dependOn(&vpi_app.step);
}
