//! L10 fault injection (specification/TESTING.md §5): `checkAllAllocationFailures` over
//! `compileSourceOpts`, `.lint` on one small positive fixture per chapter and
//! annex directory, `.build` through codegen on two. Each test fails the n-th
//! allocation for every n the clean compile makes. That is 17-23 sites per
//! compile (measured 2026-10-08): `BigArena` takes its small blocks from the
//! gpa in chunks, so a failure lands on whichever allocation grew the arena.
//!
//! Oracle: the induced failure surfaces as `error.OutOfMemory` (a success is
//! `SwallowedOutOfMemoryError`, a diagnostic turned refusal escapes as
//! `CompileFailed`), the failed compile frees everything it allocated
//! (`MemoryLeakDetected`), and no other error escapes. No file is written:
//! these run in-process, so "no partial file" is the CLI's half of L10.

const std = @import("std");
const vera = @import("vera");

/// `check.vh` lives here; every fixture below includes nothing else but the
/// built-in annex D files.
const include_dirs: []const []const u8 = &.{@import("repo_options").repo_root ++ "/tests/fixtures"};

fn compileOne(gpa: std.mem.Allocator, src: []const u8, target: vera.Target) !void {
    var bag: vera.diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var res = try vera.compileSourceOpts(gpa, src, target, .{
        .include_dirs = include_dirs,
        .diags = &bag,
        // `.emit` is the fixture testbench's mode, so `.build` reaches display codegen too.
        .display = if (target == .build) .emit else .drop,
    });
    defer res.deinit();
    if (target == .build) {
        _ = try res.generateDevice();
        if (res.device_has_compile_error) return error.CodegenRefused;
    }
}

fn oom(comptime path: []const u8, target: vera.Target) !void {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileOne, .{ @embedFile("fixtures/" ++ path), target });
}

test "OOM .lint ch01_intro" {
    try oom("ch01_intro/02_reference_ground.va", .lint);
}
test "OOM .lint ch02_lexical" {
    try oom("ch02_lexical/65_operator_arity.va", .lint);
}
test "OOM .lint ch03_data_types" {
    try oom("ch03_data_types/76_nature_compatibility_rules.va", .lint);
}
test "OOM .lint ch04_expressions" {
    try oom("ch04_expressions/parameter_reduction_and_arithmetic_shift.va", .lint);
}
test "OOM .lint ch05_analog_behavior" {
    try oom("ch05_analog_behavior/a02_06_port_flow_includes_the_reactive_part.va", .lint);
}
test "OOM .lint ch06_hierarchy" {
    try oom("ch06_hierarchy/paramset_selected_after_generate.va", .lint);
}
test "OOM .lint ch07_mixed_signal" {
    try oom("ch07_mixed_signal/lrm_7_2_4.va", .lint);
}
test "OOM .lint ch08_scheduling" {
    try oom("ch08_scheduling/shared_conservative_node.va", .lint);
}
test "OOM .lint ch09_system_tasks" {
    try oom("ch09_system_tasks/a05_05_control_default_filling.va", .lint);
}
test "OOM .lint ch10_directives" {
    try oom("ch10_directives/38_default_transition_ramp.va", .lint);
}
test "OOM .lint ch11_vpi" {
    try oom("ch11_vpi/vpi_design.va", .lint);
}
test "OOM .lint ch12_vpi_routines" {
    try oom("ch12_vpi_routines/p03_rc_ac.va", .lint);
}
test "OOM .lint annex_a_syntax" {
    try oom("annex_a_syntax/23_expression_primaries.va", .lint);
}
test "OOM .lint annex_b_keywords" {
    try oom("annex_b_keywords/21_escaped_keyword_port.va", .lint);
}
test "OOM .lint annex_c_analog_subset" {
    try oom("annex_c_analog_subset/37_compiler_directives.va", .lint);
}
test "OOM .lint annex_d_standard_definitions" {
    try oom("annex_d_standard_definitions/thermal_definitions.va", .lint);
}
test "OOM .lint annex_e_spice" {
    try oom("annex_e_spice/primitive_mesfet.va", .lint);
}
test "OOM .lint annex_f_resolution" {
    try oom("annex_f_resolution/resolveto_resolution.va", .lint);
}
test "OOM .lint annex_g_change_history" {
    try oom("annex_g_change_history/23_transition_fall_time_binding.va", .lint);
}
test "OOM .lint annex_h_glossary" {
    try oom("annex_h_glossary/06_node_port_terminal.va", .lint);
}
test "OOM .build ch05_analog_behavior (codegen)" {
    try oom("ch05_analog_behavior/a02_06_port_flow_includes_the_reactive_part.va", .build);
}
test "OOM .build annex_e_spice (codegen)" {
    try oom("annex_e_spice/primitive_mesfet.va", .build);
}
