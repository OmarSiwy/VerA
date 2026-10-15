//! Tests for directive parsing and runner generation: fixture text in,
//! verdicts on the parsed `tb.Directives` and the rendered runner out.
//! LRM: §2.6, §3.4.1, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.6, §5.2.1, §5.4.2, §5.6,
//! §5.8, §5.10.2, §6.5.2, §7.3.1, §9.15.
//!
//! The plan, as bug class, then oracle, then where:
//!   - a malformed line checks nothing: the grammar `tb.zig` documents;
//!     directive.zig's per-keyword test and the refusals here.
//!   - a number reads differently from the model's own literal: §2.6's table
//!     and Zig's literals; directive.zig's `test number`.
//!   - a rendered testbench does not build: AstGen, the compiler's own front
//!     half, over generated directive sets ("every directive set ...").
//!   - a value reaches the testbench changed: Zig's literal reader;
//!     runner.zig's `test fmtF64`.
//!   - the build command is wrong: argv derived by hand; exe.zig's tests.
//! The emitted solver and gates execute only in the fixture suite (`zig
//! build benchmark`), which builds and runs a testbench per fixture.

const std = @import("std");
const tb = @import("../tb.zig");
const tb_directive = @import("directive.zig");
const tb_runner = @import("runner.zig");
const Analysis = tb.Analysis;

const testing = std.testing;

/// Asserts that `src` parses and passes AstGen: every check a testbench
/// build makes before it resolves `device` and `contract` (unused or
/// never-mutated locals, undeclared names, shadowing). Prints `src` on
/// failure, since a generator chose it.
pub fn expectAstGen(src: []const u8) !void {
    const gpa = testing.allocator;
    const z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .{ .mode = .zig });
    defer tree.deinit(gpa);
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    if (tree.errors.len == 0 and !zir.hasCompileErrors()) return;
    std.debug.print("{s}\n", .{src});
    return error.TestUnexpectedResult;
}

/// A mixed-signal plan with every naming hazard `renderMixed` escapes: a
/// quote and a backslash in the source, an `x`/`z` input, a three-word `reg`,
/// a `Z` (the escape marker) in a name, an event and an inserted module.
const sample_mixed: tb.Mixed = .{
    .source = "module m(a); \"quoted\" \\ endmodule\n",
    .top = "m",
    .unit = 1e-9,
    .precision = 1e-12,
    .inputs = &.{ "clk", "bus", "Zq" },
    .xz = &.{"clk"},
    .wide = &.{"bus"},
    .words = &.{3},
    .snaps = &.{"go"},
    .events = &.{.{ .name = "go", .edge = .posedge, .param = "go__ev" }},
    .inserts = &.{.{ .path = "m.i", .inst = "i", .port = "p", .module = "cm", .name = "cm0", .upper_port = "a", .lower_port = "d" }},
};

test "directives: defaults when the source has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try tb_directive.parse(arena_state.allocator(), "module m; endmodule\n");
    try testing.expectEqual(@as(usize, 0), d.sweeps.len);
    try testing.expectEqual(@as(usize, 0), d.params.len);
    try testing.expectEqual(@as(f64, 300.15), d.temp);
    try testing.expectEqual(Analysis.dc, d.analysis);
    try testing.expect(d.print_residual);
    try testing.expect(!d.solve_free);
}

test "§5.6 `//! solve` unties the unknowns nothing else names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Default netlist: every unknown tied to the reference, so `//! bias V(p)`
    // on a two-terminal device is the potential across it.
    const tied = try tb_runner.renderRunner(arena, "065_tied", try tb_directive.parse(arena, "//! bias V(p) = 0.5\n"));
    try testing.expect(std.mem.find(u8, tied, "var forced: [n_u]?f64 = @splat(0.0);") != null);
    try testing.expect(std.mem.find(u8, tied, "set(&x, &forced, \"p\", 0.5);") != null);

    // With `solve`, only what a directive names stays pinned.
    const d = try tb_directive.parse(arena, "//! bias V(ctrl) = 1.5\n//! solve\n");
    try testing.expect(d.solve_free);
    const free = try tb_runner.renderRunner(arena, "066_free", d);
    try testing.expect(std.mem.find(u8, free, "var forced: [n_u]?f64 = @splat(null);") != null);
    try testing.expect(std.mem.find(u8, free, "set(&x, &forced, \"ctrl\", 1.5);") != null);
    // The solve runs before the model prints (§5.6: semantics at a solution).
    const solve_at = std.mem.find(u8, free, "solve(&x, &forced").?;
    try testing.expect(solve_at < std.mem.find(u8, free, "point(0, &x").?);

    // It takes no operand.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! solve V(p)\n"));
}

test "directives: every form, including the §2.6 suffixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try tb_directive.parse(arena_state.allocator(),
        \\//! param is = 1e-14, n = 1.05
        \\//! bias V(c) = 0
        \\//! sweep V(a) = 0, 0.3, 0.6
        \\//! temp 350
        \\//! time 0, 1n
        \\//! analysis tran
        \\//! print none
        \\module m(a, c); endmodule
    );
    try testing.expectEqual(@as(usize, 2), d.params.len);
    try testing.expectEqualStrings("is", d.params[0].name);
    try testing.expectEqual(@as(f64, 1e-14), d.params[0].value);
    try testing.expectEqualStrings("c", d.bias[0].name);
    try testing.expectEqualStrings("a", d.sweeps[0].name);
    try testing.expectEqual(@as(usize, 3), d.sweeps[0].values.len);
    try testing.expectEqual(@as(f64, 0.6), d.sweeps[0].values[2]);
    try testing.expectEqual(@as(f64, 350), d.temp);
    try testing.expectEqual(@as(f64, 1e-9), d.times[1]);
    try testing.expectEqual(Analysis.tran, d.analysis);
    try testing.expect(!d.print_residual);
}

test "§5.10.3.1 an unwritten analysis is tran under a time grid, dc without one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(Analysis.tran, (try tb_directive.parse(a, "//! time 0, 1n\n")).analysis);
    try testing.expectEqual(Analysis.dc, (try tb_directive.parse(a, "//! time 0\n")).analysis);
    try testing.expectEqual(Analysis.dc, (try tb_directive.parse(a, "//! time 0, 1n\n//! analysis dc\n")).analysis);
}

test "§5.4.2 `I(...)` names the flow unknown, not the node potential" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const d = try tb_directive.parse(arena_state.allocator(),
        \\//! bias V(a) = 1.0
        \\//! bias I(b) = 0.125
        \\//! sweep I(<c>) = 0, 1
        \\//! sweep I(a,b) = 0.25
        \\//! bias V(d[1]) = 2.0
        \\module m(a, b, c); endmodule
    );
    // `V(a)` is the node; the `I` forms are flow unknowns, sanitized as codegen
    // spells them.
    try testing.expectEqualStrings("a", d.bias[0].name);
    try testing.expectEqualStrings("flowZ28bZ2cgndZ29", d.bias[1].name);
    try testing.expectEqualStrings("flowZ28Z3ccZ3eZ29", d.sweeps[0].name);
    // §5.4.2's two-terminal branch flow and a §6.5.2 vector element `b[i]`
    // must land on the members `emitTopology` prints (codegen's "the `U` block
    // is the SPELLING contract" test pins the other end).
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d.sweeps[1].name);
    try testing.expectEqualStrings("dZ5b1Z5d", d.bias[2].name);
    // `parseBindings` splits on top-level commas, so `I(a,b)` works in `bias`
    // as it does in `sweep`.
    const d2 = try tb_directive.parse(arena_state.allocator(), "//! bias I(a,b) = 0.25, V(z) = 3\n");
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d2.bias[0].name);
    try testing.expectEqual(@as(f64, 0.25), d2.bias[0].value);
    try testing.expectEqualStrings("z", d2.bias[1].name);
    // A binding with no `=` is still an error.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena_state.allocator(), "//! bias I(a,b)\n"));
}

test "directives: a typo is an error, not a silently skipped test" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.UnknownDirective, tb_directive.parse(arena_state.allocator(), "//! sweeep V(a) = 1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena_state.allocator(), "//! sweep V(a)\n"));
    try testing.expectError(error.BadNumber, tb_directive.parse(arena_state.allocator(), "//! temp warm\n"));
}

test "directives: an lrm cite is a section, and an xfail points either way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! lrm 4.5.11\n//! lrm A.8.3\n//! reject E0130\n//! xfail VerA accepts it\n");
    try testing.expectEqual(@as(usize, 2), d.lrm.len);
    try testing.expectEqualStrings("4.5.11", d.lrm[0]);
    try testing.expectEqualStrings("A.8.3", d.lrm[1]);
    try testing.expectEqualStrings("VerA accepts it", d.xfail.?);

    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm §5.8\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm 5.\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm Z.1\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm\n"));

    // An IEEE 1364 clause never reaches `lrm`, and `lrm` refuses one.
    const inh = try tb_directive.parse(arena, "//! inherited IEEE 1364-2005 18.1 ($dumpfile)\n//! inherited IEEE 1364-2005 8.1.4,8.2\n");
    try testing.expectEqual(@as(usize, 0), inh.lrm.len);
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm inherited IEEE 1364-2005 18.1\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited 18.1\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited IEEE 1364-2005 §18\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited IEEE 1364-2005\n"));

    // On a run fixture too: VerA cannot yet build a legal example.
    const run = try tb_directive.parse(arena, "//! xfail no array formals in analog functions\n");
    try testing.expectEqual(@as(usize, 0), run.reject.len);
    try testing.expectEqualStrings("no array formals in analog functions", run.xfail.?);
    // A reason is required.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! xfail\n"));
}

test "directives: a sentence cite names one normative sentence of a clause" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! lrm 5.6.1.3:2\n//! lrm A.6.4:12\n//! inherited IEEE 1364-2005 9.2.2:1\n");
    try testing.expectEqualStrings("5.6.1.3:2", d.lrm[0]);
    try testing.expectEqualStrings("A.6.4:12", d.lrm[1]);
    // Sentences count from 1, and the ordinal is a number.
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm 5.6.1.3:0\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm 5.6.1.3:\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm 5.6.1.3:2a\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm :2\n"));
}

test "directives: reject-only refuses alone, and a neighbour belongs to a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! reject-only E0310\n//! neighbour legal_twin.va\n");
    try testing.expect(d.reject_only);
    try testing.expectEqualStrings("E0310", d.reject[0]);
    try testing.expectEqualStrings("legal_twin.va", d.neighbours[0]);
    // A plain reject is not exclusive.
    try testing.expect(!(try tb_directive.parse(arena, "//! reject E0310\n")).reject_only);
    // `reject-only` is still a reject: no check count, no warnings.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject-only E0310\n//! checks 1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject-only\n"));
    // A neighbour on a positive fixture has nothing to be the neighbour of.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! neighbour legal_twin.va\n"));
    // One path per line, no spaces.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject E1\n//! neighbour a.va b.va\n"));
}

test "directives: reject-run is a refusal the run makes, with a failing status" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! reject-run E0816\n//! neighbour legal.va\n//! checks 1\n");
    try testing.expectEqualStrings("E0816", d.reject_run[0]);
    try testing.expectEqual(@as(usize, 0), d.reject.len);
    // The run compiles and may assert before it is refused.
    try testing.expectEqual(@as(?usize, 1), d.expected_checks);
    // The status every run-time `error[...]` exits with, unless named.
    try testing.expectEqual(1, d.expected_exit);
    try testing.expectEqual(3, (try tb_directive.parse(arena, "//! exit 3\n//! reject-run E0601\n")).expected_exit);
    // A refusal that exits 0 is not one.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject-run E0601\n//! exit 0\n"));
    // Refused by the compiler or by the run, never both; and never unnamed.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject-run E0601\n//! reject E0601\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! reject-run\n"));
}

test "§4.6.4.6 `//! noise` states a correlation coefficient with another row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! noise thermal(a,b)#0 corr=1:-1 corr=2:0\n");
    const w = d.noise[0];
    try testing.expectEqual(@as(usize, 2), w.corrs.len);
    try testing.expectEqual(@as(u16, 1), w.corrs[0].with);
    try testing.expectEqual(@as(f64, -1), w.corrs[0].rho);
    try testing.expectEqual(@as(f64, 0), w.corrs[1].rho);
    // A coefficient may depend on the bias, so it is read at a point.
    try testing.expect(w.needsPoint());
    for ([_][]const u8{ "corr=1", "corr=:1", "corr=x:1", "corr=1:", "corr=-1:1" }) |bad| {
        // BadSyntax or BadNumber: either way the line asserts nothing silently.
        if (tb_directive.parse(arena, try arena.print("//! noise thermal(a,b)#0 {s}\n", .{bad}))) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "§2.9.2 `//! meta` states one published desc/units row, in a fixed spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena,
        \\//! meta parameter res units="Ohms" desc="Resistance"
        \\//! meta variable cgs desc="gate-source capacitance"
        \\//! meta net d   desc="drain terminal"
        \\
    );
    try testing.expect(d.asserts_meta);
    // `desc` before `units`, one space apart, whatever order the line used.
    try testing.expectEqualStrings("parameter res desc=\"Resistance\" units=\"Ohms\"", d.meta[0]);
    try testing.expectEqualStrings("variable cgs desc=\"gate-source capacitance\"", d.meta[1]);
    try testing.expectEqualStrings("net d desc=\"drain terminal\"", d.meta[2]);
    const none = try tb_directive.parse(arena, "//! meta none\n");
    try testing.expect(none.asserts_meta and none.meta.len == 0);
    for ([_][]const u8{ "port p desc=\"x\"", "net", "net d desc=x", "net d desc=\"x", "net d note=\"x\"", "net d desc=\"a\" desc=\"b\"" }) |bad| {
        try testing.expectError(error.BadSyntax, tb_directive.parse(arena, try arena.print("//! meta {s}\n", .{bad})));
    }
}

test "renderRunner emits the meta and correlation checks as parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena,
        \\//! noise thermal(a,b)#0 corr=1:-1
        \\//! noise thermal(c,d)#0
        \\//! meta parameter r desc="R" units="Ohm"
        \\
    );
    const src = try tb_runner.renderRunner(arena, "corr_meta", d);
    const z = try arena.dupeSentinel(u8, src, 0);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .{ .mode = .zig });
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    try testing.expect(std.mem.find(u8, src, "noise[0].corr[1] got=") != null);
    try testing.expect(std.mem.find(u8, src, "\"parameter r desc=\\\"R\\\" units=\\\"Ohm\\\"\"") != null);
}

test "§2.6 a scale factor is an exponent, not a multiplier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Bit equality with the same spelling in the model (`Lexer.scaleExp`):
    // `200 * 1e-6` is a different double from `200e-6`.
    const d = try tb_directive.parse(arena, "//! time 0, 200u, 1n, 2.5m, 1K\n");
    try testing.expectEqual(@as(f64, 0.0), d.times[0]);
    try testing.expectEqual(@as(f64, 200e-6), d.times[1]);
    try testing.expectEqual(@as(f64, 1e-9), d.times[2]);
    try testing.expectEqual(@as(f64, 2.5e-3), d.times[3]);
    try testing.expectEqual(@as(f64, 1e3), d.times[4]);
    // The product must be computed at run time: comptime float arithmetic is
    // exact, so a literal `200.0 * 1e-6` would already be correctly rounded.
    var two_hundred: f64 = 200;
    _ = &two_hundred;
    const multiplied = two_hundred * 1e-6;
    try testing.expect(d.times[1] == 200e-6);
    try testing.expect(multiplied != 200e-6);
    try testing.expect(d.times[1] != multiplied);

    // A bare suffix is not a number, and neither is a suffix on nothing.
    try testing.expectError(error.BadNumber, tb_directive.parse(arena, "//! temp u\n"));
    // A plain float still goes straight through.
    const plain = try tb_directive.parse(arena, "//! temp 300.15\n");
    try testing.expectEqual(@as(f64, 300.15), plain.temp);
}

test "§5.4.2 a branch potential is not a solver unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `V(a,c)` is a potential difference, derived from two unknowns; refused
    // at parse time rather than failing the testbench build.
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! bias V(a,c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! bias V(a, c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! sweep V(a,c) = 0, 1\n"));

    // A branch flow is an unknown (§5.4.2), spelled through `naming.sanitize`
    // as codegen spells its `U` member.
    const flow = try tb_directive.parse(arena, "//! bias I(a,c) = 0.25\n");
    try testing.expectEqualStrings("flowZ28aZ2ccZ29", flow.bias[0].name);

    // Whitespace inside the access function is not part of the name.
    const spaced = try tb_directive.parse(arena, "//! bias V( a ) = 0.5\n");
    try testing.expectEqualStrings("a", spaced.bias[0].name);
}

test "§4.6.4 `//! noise` states the exported generator table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! noise thermal(a,b)#0\n//! noise flicker(d,s)#null\n");
    try testing.expect(d.asserts_noise);
    try testing.expectEqual(@as(usize, 2), d.noise.len);
    try testing.expectEqualStrings("thermal(a,b)#0", d.noise[0].topo);
    try testing.expectEqualStrings("flicker(d,s)#null", d.noise[1].topo);
    // A line with no `key=value` tail asserts the topology only.
    try testing.expect(d.noise[0].name == null);
    try testing.expect(d.noise[0].white == null);
    try testing.expect(!d.noise[0].needsPoint());

    // `none` asserts an empty table, unlike an absent directive.
    const none = try tb_directive.parse(arena, "//! noise none\n");
    try testing.expect(none.asserts_noise);
    try testing.expectEqual(@as(usize, 0), none.noise.len);

    const silent = try tb_directive.parse(arena, "//! analysis dc\n");
    try testing.expect(!silent.asserts_noise);

    // A misspelled kind is caught at parse time.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise pink(a,b)#0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal a,b\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a)#0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(,b)#0\n"));
    // The §4.6.4.6 source id (digits or `null`) is mandatory.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#x\n"));
    // A node name is not checked: the unknowns are not known at parse time.
    const odd = try tb_directive.parse(arena, "//! noise shot(nosuchnode,b)#3\n");
    try testing.expectEqual(@as(usize, 1), odd.noise.len);
}

test "§4.6.4 a `//! noise` line states the row's contents as well as its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena,
        \\//! noise thermal(p,n)#0 name=thermal white=4e-18
        \\//! noise flicker(p,n)#1 name=flicker flicker=1e-20 ef=1.25 rtol=1e-4
        \\//! noise table(p,n)#2 name=tbl interp=log points=1.0:1e-18,1e3:1e-21
        \\
    );
    try testing.expectEqual(@as(usize, 3), d.noise.len);

    // The fields are a tail; the topology string is unchanged.
    try testing.expectEqualStrings("thermal(p,n)#0", d.noise[0].topo);
    try testing.expectEqualStrings("thermal", d.noise[0].name.?);
    try testing.expectEqual(@as(f64, 4e-18), d.noise[0].white.?);
    try testing.expectEqual(@as(f64, 1e-12), d.noise[0].rtol); // the default
    try testing.expect(d.noise[0].needsPoint());

    try testing.expectEqual(@as(f64, 1e-20), d.noise[1].flicker.?);
    try testing.expectEqual(@as(f64, 1.25), d.noise[1].ef.?);
    try testing.expectEqual(@as(f64, 1e-4), d.noise[1].rtol);

    // `interp`/`points` are comptime table data and need no bias.
    try testing.expectEqualStrings("log", d.noise[2].interp.?);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1.0, 1e-18 }, .{ 1e3, 1e-21 } }, d.noise[2].points.?);
    try testing.expect(!d.noise[2].needsPoint());

    // `psd` is the same pair syntax, densities at frequencies, and also needs
    // no bias: it reads the table, not `noisePsd`.
    const with_psd = try tb_directive.parse(arena, "//! noise table(p,n)#0 psd=4e3:1.7e-17,1.0:9e-18\n");
    try testing.expectEqualSlices([2]f64, &.{ .{ 4e3, 1.7e-17 }, .{ 1.0, 9e-18 } }, with_psd.noise[0].psd.?);
    try testing.expect(with_psd.noise[0].points == null);
    try testing.expect(!with_psd.noise[0].needsPoint());

    // A space inside the parentheses still parses.
    const spaced = try tb_directive.parse(arena, "//! noise thermal(p, n)#0 name=x\n");
    try testing.expectEqualStrings("thermal(p, n)#0", spaced.noise[0].topo);

    // An unknown key is refused, since nothing would check it.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 whte=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 name\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 interp=spline\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 points=1.0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 psd=\n"));
}

test "§9.17.3 `//! seed` and `//! limit` state the published cold start and clamp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena,
        \\//! seed V(si) = -0.7, V(b) = -1.7
        \\//! seed V(g) = 0
        \\//! limit V(b) = 0 -> V(b) = 0.1, converged = 0
        \\//! limit -> V(b) = 1.5
        \\
    );
    try testing.expect(d.asserts_seed);
    try testing.expectEqual(@as(usize, 3), d.seeds.len);
    try testing.expectEqualStrings("b", d.seeds[1].name);
    try testing.expectEqual(@as(usize, 2), d.limits.len);
    try testing.expectEqual(@as(usize, 1), d.limits[0].old.len);
    try testing.expectEqualStrings("converged", d.limits[0].want[1].name);
    try testing.expectEqual(@as(usize, 0), d.limits[1].old.len);

    const none = try tb_directive.parse(arena, "//! seed none\n");
    try testing.expect(none.asserts_seed and none.seeds.len == 0);
    // No `->` names no output, and no output is no assertion.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! limit V(b) = 0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! limit V(b) = 0 ->\n"));
}

test "§4.6.3 `//! acstim` states the exported stimulus table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena,
        \\//! acstim (p,n) name=ac mag=2.0 phase=1.0471975511965976
        \\//! acstim (q, n) mag=1.0 phase=1.5707963267948966 rtol=1e-6
        \\
    );
    try testing.expect(d.asserts_acstim);
    try testing.expectEqual(@as(usize, 2), d.acstim.len);
    try testing.expectEqualStrings("(p,n)", d.acstim[0].topo);
    try testing.expectEqualStrings("ac", d.acstim[0].name.?);
    try testing.expectEqual(@as(f64, 2.0), d.acstim[0].mag.?);
    try testing.expectEqual(@as(f64, 1e-12), d.acstim[0].rtol); // the default
    try testing.expectEqual(@as(f64, 1e-6), d.acstim[1].rtol);
    try testing.expect(d.acstim[0].needsPoint());

    // Canonicalised to the device's spelling.
    try testing.expectEqualStrings("(q,n)", d.acstim[1].topo);
    // `name=` is optional; §4.6.3 defaults `analysis_name` to "ac".
    try testing.expect(d.acstim[1].name == null);

    // `none` asserts an empty table.
    const none = try tb_directive.parse(arena, "//! acstim none\n");
    try testing.expect(none.asserts_acstim);
    try testing.expectEqual(@as(usize, 0), none.acstim.len);

    // An unknown key is refused.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a,b) magnitude=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a,b) mag\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim a,b mag=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a) mag=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (,b) mag=1\n"));
}

test "`//! acdyn` names a slot, a frequency and the complex term" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try tb_directive.parse(arena, "//! acdyn (out, in) f=125M re=0.5 im=-0.5 tol=1e-9\n");
    try testing.expectEqual(@as(usize, 1), d.acdyn.len);
    try testing.expectEqualStrings("out", d.acdyn[0].row);
    try testing.expectEqualStrings("in", d.acdyn[0].col);
    try testing.expectEqual(@as(f64, 125e6), d.acdyn[0].f);
    try testing.expectEqual(@as(f64, -0.5), d.acdyn[0].im);
    try testing.expectEqual(@as(f64, 1e-9), d.acdyn[0].tol);
    // f, re and im are each required; an unknown key is refused.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acdyn (out,in) re=1 im=0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acdyn (out,in) f=1 im=0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acdyn (out,in) f=1 re=1 im=0 phase=0\n"));
}

test "analysis takes an optional §9.15 analysis_name after the kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const named = try tb_directive.parse(arena, "//! analysis dc mydc\n");
    try testing.expectEqual(.dc, named.analysis);
    try testing.expectEqualStrings("mydc", named.analysis_name);
    try testing.expectEqualStrings("", (try tb_directive.parse(arena, "//! analysis tran\n")).analysis_name);
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! analysis dc two words\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! analysis nosuch\n"));
}

test "plusargs preserves tokens, duplicate arguments and repeated-line order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "//! plusargs +HELLO\t+gain=7 +gain=8\r\n//! plusargs +HELLO +empty= +literal=$HOME;*\n");
    const want = [_][]const u8{ "+HELLO", "+gain=7", "+gain=8", "+HELLO", "+empty=", "+literal=$HOME;*" };
    try testing.expectEqual(want.len, d.plusargs.len);
    for (want, d.plusargs) |expected, actual| try testing.expectEqualStrings(expected, actual);
    // Existing defaults are unaffected; metacharacters above are literal bytes.
    try testing.expectEqual(0, d.expected_exit);
    try testing.expectEqual(null, d.expected_checks);
    try testing.expect(d.print_residual);
    try testing.expectEqual(0, (try tb_directive.parse(arena, "//! checks 2\n")).plusargs.len);
}

test "plusargs rejects malformed operands rather than dropping them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "", "+", "HELLO", "+ok missingplus", "+s=\"hello\"", "+s='hello'", "+s=\\value", "+s=\x00", "+s=\x7f", "+s=\x80", "+a\r+b" }) |bad| {
        const source = try arena.print("//! plusargs {s}\n", .{bad});
        try testing.expectError(error.BadSyntax, tb_directive.parse(arena, source));
    }
}

test "expected process exit status is explicit and bounded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(0, (try tb_directive.parse(arena, "")).expected_exit);
    try testing.expectEqual(1, (try tb_directive.parse(arena, "//! exit 1\n")).expected_exit);
    try testing.expectEqual(255, (try tb_directive.parse(arena, "//! exit 255\n")).expected_exit);
    try testing.expectError(error.BadNumber, tb_directive.parse(arena, "//! exit 256\n"));
    try testing.expectError(error.BadNumber, tb_directive.parse(arena, "//! exit -1\n"));
}

test "expected runtime check count is positive, unique and not a rejection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, (try tb_directive.parse(arena, "")).expected_checks);
    try testing.expectEqual(@as(?usize, 215), (try tb_directive.parse(arena, "//! checks 215\n")).expected_checks);
    for ([_][]const u8{ "", "0", "-1", "+1", "1.0", "1_0", "two" }) |bad| {
        const source = try arena.print("//! checks {s}\n", .{bad});
        try testing.expectError(error.BadNumber, tb_directive.parse(arena, source));
    }
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! checks 1\n//! checks 2\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! checks 1\n//! reject E0208\n"));
}

test "warn is a named substring on a compiling fixture; nowarn stands alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "//! warn W0853\n//! warn not applied at this call\n");
    try testing.expectEqual(@as(usize, 2), d.warn.len);
    try testing.expectEqualStrings("not applied at this call", d.warn[1]);
    try testing.expect((try tb_directive.parse(arena, "//! nowarn\n")).nowarn);
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! warn\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! nowarn W0853\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! warn W0853\n//! nowarn\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! warn W0853\n//! reject E0208\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! nowarn\n//! reject E0208\n"));
}

test "sweep expansion is the cartesian product, last fastest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena,
        \\//! sweep V(a) = 0, 1
        \\//! sweep V(b) = 10, 20, 30
    );
    const pts = try tb_runner.expand(arena, d);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 10 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 20 }, pts[1]);
    try testing.expectEqualSlices(f64, &.{ 0, 30 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 10 }, pts[3]);
    try testing.expectEqualSlices(f64, &.{ 1, 30 }, pts[5]);
}

test "sweep expansion stops at max_points, counting the product" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vals = try arena.alloc(f64, tb.max_points + 1);
    for (vals, 0..) |*v, i| v.* = @floatFromInt(i);
    const at_cap: tb.Directives = .{ .sweeps = &.{.{ .name = "a", .values = vals[0..tb.max_points] }} };
    try testing.expectEqual(tb.max_points, (try tb_runner.expand(arena, at_cap)).len);
    const over: tb.Directives = .{ .sweeps = &.{.{ .name = "a", .values = vals }} };
    try testing.expectError(error.TooManyPoints, tb_runner.expand(arena, over));
    // 64 x 65 is past the cap, though neither column is.
    const product: tb.Directives = .{
        .sweeps = &.{.{ .name = "a", .values = vals[0..64] }},
        .psweeps = &.{.{ .name = "r", .values = vals[0..65] }},
    };
    try testing.expectError(error.TooManyPoints, tb_runner.expand(arena, product));
    // Unknown columns first, then parameter columns, the parameter fastest.
    const both: tb.Directives = .{
        .sweeps = &.{.{ .name = "a", .values = vals[0..2] }},
        .psweeps = &.{.{ .name = "r", .values = vals[5..8] }},
    };
    const pts = try tb_runner.expand(arena, both);
    try testing.expectEqual(@as(usize, 6), pts.len);
    try testing.expectEqualSlices(f64, &.{ 0, 5 }, pts[0]);
    try testing.expectEqualSlices(f64, &.{ 0, 7 }, pts[2]);
    try testing.expectEqualSlices(f64, &.{ 1, 5 }, pts[3]);
    // No sweep is one point with no columns.
    const one = try tb_runner.expand(arena, .{});
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 0), one[0].len);
}

test "a wave is per-timepoint and holds its last value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena,
        \\//! time 0, 1n, 2n, 3n
        \\//! wave V(in) = 0, 1
        \\//! bias V(out) = 0
    );
    try testing.expectEqual(@as(usize, 4), d.times.len);
    try testing.expectEqualStrings("in", d.waves[0].name);
    try testing.expectEqual(@as(usize, 2), d.waves[0].values.len);

    const src = try tb_runner.renderRunner(arena, "060_wave", d);
    // Four points, `in` = 1 after the first, and one `stepPost` per point so
    // operator state advances.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        if (stepPost(&model"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= newState("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "set(&x, &forced, \"in\", 1);"));
}

test "each sweep point starts its transient from a fresh State" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena,
        \\//! sweep V(a) = 0, 1, 2
        \\//! time 0, 1n
    );
    const src = try tb_runner.renderRunner(arena, "061_reset", d);
    // Three sweep points x two times, one `newState` per sweep point.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "= newState("));
    // Point numbers are global, so no two transcript blocks share a label.
    try testing.expect(std.mem.find(u8, src, "point(5, &x") != null);
    // §4.6.2 a dc sweep is one analysis: its points share one `State`.
    const dc = try tb_runner.renderRunner(arena, "061_dc", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1, 2"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dc, "= newState("));
}

test "§5.10.2 global events mark the first and last point of each analysis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dc sweep is one analysis: events on its first and last step only.
    const swept = try tb_runner.renderRunner(arena, "062_sweep", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1, 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.final_step = true;"));
    try testing.expect(std.mem.find(u8, swept, "sim_state.initial_step = true;\n        sim_state.final_step = false;\n        sim_state.analog_initial = true;\n        const solved0 = solve(&x, &forced, &model, &inst);\n        point(0,") != null);
    try testing.expect(std.mem.find(u8, swept, "sim_state.initial_step = false;\n        sim_state.final_step = true;\n        sim_state.analog_initial = true;\n        const solved2 = solve(&x, &forced, &model, &inst);\n        point(2,") != null);
    // §5.2.1 `analog initial` re-runs per sub-task: all three points, while
    // the global event fires at one.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, swept, "sim_state.analog_initial = true;"));

    // With `//! time` each sweep block is its own transient analysis.
    const tran = try tb_runner.renderRunner(arena, "063_tran", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n, 2n\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.final_step = true;"));
    // Two blocks, so two sub-tasks: one analog-initial pass each, at dt = 0.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "sim_state.analog_initial = true;"));

    // The single-point default is the Table 5-1 DCOP column: both events fire.
    const op = try tb_runner.renderRunner(arena, "064_op", .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "sim_state.final_step = true;"));
}

test "renderRunner emits parseable Zig" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena,
        \\//! param g = 2m
        \\//! sweep V(p) = 0, 1
        \\//! bias V(n) = 0
    );
    const src = try tb_runner.renderRunner(arena, "001_demo", d);
    const z = try arena.dupeSentinel(u8, src, 0);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .{ .mode = .zig });
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // The sweep really did become two straight-line blocks.
    try testing.expect(std.mem.find(u8, src, "point(0, &x") != null);
    try testing.expect(std.mem.find(u8, src, "point(1, &x") != null);
    // §3.4.1/§4.2.1.1: card values go through `cardValue`, which rounds for
    // an `integer` parameter.
    try testing.expect(std.mem.find(u8, src, "model.g = cardValue(@TypeOf(model.g), 0.002)") != null);
}

test "every directive set that parses renders to Zig that passes AstGen" {
    // A structured generator: draws from lines that each parse alone, so
    // most sets parse and together they reach every emitter. The compile
    // facts a caller fills in are toggled per draw too. Seeded: a failure
    // replays, and prints the text it rendered.
    const pool = [_][]const u8{
        "//! param g = 2m, is = 1e-14",
        "//! param n = -0",
        "//! bias V(n) = 0",
        "//! bias I(a,b) = 0.25",
        "//! sweep V(p) = 0, 1",
        "//! sweep I(<c>) = 1e23, -1",
        "//! wave V(in) = 0, 1, 0.5",
        "//! psweep r = 1, 2",
        "//! temp 350",
        "//! time 0, 1n, 2n",
        "//! solve",
        "//! analysis tran",
        "//! analysis dc mydc",
        "//! analysis noise",
        "//! noise thermal(a,b)#0 name=th white=4e-18 corr=1:-1",
        "//! noise flicker(c, d)#1 flicker=1e-20 ef=1.25 rtol=1e-4",
        "//! noise table(p,n)#null name=t interp=log points=1:1e-18,1e3:1e-21 psd=10:2e-18",
        "//! noise none",
        "//! acstim (p, n) name=ac mag=2 phase=1.5",
        "//! acstim (q,n)",
        "//! acstim none",
        "//! acdyn (out, in) f=1k re=0.5 im=-0.5 tol=1e-9",
        "//! qsite g+ s- lte",
        "//! qsite none",
        "//! seed V(a) = -0.7, V(b) = 1",
        "//! seed none",
        "//! meta parameter r desc=\"R \\ ohm\" units=\"Ohm\"",
        "//! meta none",
        "//! abstol V(a) = 1e-6, I(a,b) = 1e-12",
        "//! limit V(b) = 0 -> V(b) = 0.1, converged = 0",
        "//! limit -> V(a) = 1.5",
        "//! print none",
        "//! tran 1n, 10n",
        "//! onoise V(out) = 1, 10",
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x7b0fd1);
    const r = prng.random();
    var rendered: usize = 0;
    for (0..64) |_| {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var src: std.ArrayList(u8) = .empty;
        for (0..1 + r.uintLessThan(usize, 8)) |_| {
            try src.appendSlice(arena, pool[r.uintLessThan(usize, pool.len)]);
            try src.append(arena, '\n');
        }
        var d = tb_directive.parse(arena, src.items) catch continue;
        d.op_states = if (r.boolean()) &.{ 0, 3 } else &.{};
        d.validate_contract = r.boolean();
        d.certify = r.boolean();
        d.finite_proved = r.boolean();
        const fixed = tb_runner.renderRunner(arena, "gen \"t\" \\", d) catch |e| switch (e) {
            error.BadSyntax, error.TooManyPoints => continue,
            else => return e,
        };
        try expectAstGen(fixed);
        try expectAstGen(try tb_runner.renderVpiLib(arena, "gen", d));
        var dm = d;
        dm.mixed = sample_mixed;
        try expectAstGen(try tb_runner.renderRunner(arena, "gen", dm));
        rendered += 1;
    }
    // Most draws are compatible lines; a run that renders few has stopped
    // testing anything.
    try testing.expect(rendered >= 16);
}

test "`//! seed none` renders a testbench that passes AstGen" {
    // `want` stays all null, so it must not be a `var` nothing writes.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectAstGen(try tb_runner.renderRunner(arena, "seed_none", try tb_directive.parse(arena, "//! seed none\n")));
}

test "no rendered testbench uses a name Zig 0.17 deprecates" {
    // Deprecated in 0.17 and removed after it. A testbench is compiled by
    // whatever Zig the host has, so one of these breaks every fixture at once.
    const deprecated = [_][]const u8{ "@intFromEnum(", "@enumFromInt(", "std.mem.indexOf", "std.mem.lastIndexOf" };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "//! noise thermal(a,b)#0\n//! acstim (a,b)\n//! seed V(a) = 1\n//! abstol V(a) = 1e-6\n");
    var dm = d;
    dm.mixed = sample_mixed;
    const texts = [_][]const u8{
        try tb_runner.renderRunner(arena, "dep", d),
        try tb_runner.renderRunner(arena, "dep", dm),
        try tb_runner.renderVpiLib(arena, "dep", d),
        try tb_runner.renderRunner(arena, "dep", try tb_directive.parse(arena, "//! solve\n//! onoise V(out) = 1\n")),
    };
    for (texts) |src| for (deprecated) |name| {
        if (std.mem.find(u8, src, name)) |at| {
            std.debug.print("`{s}` at byte {d}\n", .{ name, at });
            return error.TestUnexpectedResult;
        }
    };
}

test "a `//! time` grid strictly increases" {
    // `dt` is the step from the previous time (§4.5.3), and `sim.mixed.run`
    // takes the same list ascending: a repeated or backward time is a typo.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "0, 2n, 1n", "0, 1n, 1n", "1n, 0" }) |bad| {
        try testing.expectError(error.BadSyntax, tb_directive.parse(arena, try arena.print("//! time {s}\n", .{bad})));
    }
    try testing.expectEqual(@as(usize, 1), (try tb_directive.parse(arena, "//! time 5n\n")).times.len);
    try testing.expectEqual(@as(usize, 3), (try tb_directive.parse(arena, "//! time 0, 1n, 1.5n\n")).times.len);
}

test "an exit status is plain decimal digits, as a check count is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "+1", "1_0", "0x1", "1 2" }) |bad| {
        try testing.expectError(error.BadNumber, tb_directive.parse(arena, try arena.print("//! exit {s}\n", .{bad})));
    }
}

test "a binding whose access function names nothing is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        "//! bias V() = 1\n",
        "//! bias I(a, ) = 1\n",
        "//! seed V() = 1\n",
        "//! abstol x[] = 1e-6\n",
        "//! limit V() = 0 -> V(a) = 1\n",
    }) |line| try testing.expectError(error.BadSyntax, tb_directive.parse(arena, line));
}

test "§8.2 each psweep point is its own card, derived and set up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = try tb_runner.renderRunner(arena, "ps", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1\n//! psweep r = 1, 2, 3\n"));
    try expectAstGen(src);
    // 2 x 3 points, the parameter column fastest.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        var pm = model;\n"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        if (comptime @hasDecl(D, \"derive\")) D.derive(Val, &pm);\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        pm.r = cardValue(@TypeOf(pm.r), 3);\n"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "solve(&x, &forced, &pm, &inst);"));
}

test "a SPICE deck renders one sim.spice call and leaves every unknown to it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tran = try tb_runner.renderRunner(arena, "deck", try tb_directive.parse(arena, "//! solve\n//! tran 1n, 10n\n"));
    try expectAstGen(tran);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, tran, "    @import(\"sim\").spice.deck.runTran(D, title, &model, &inst, 0.000000001, 0.00000001);\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, tran, "        point("));
    const noise = try tb_runner.renderRunner(arena, "deck", try tb_directive.parse(arena, "//! solve\n//! onoise V(out) = 1, 1k\n"));
    try expectAstGen(noise);
    try testing.expect(std.mem.find(u8, noise, "ix(\"out\")") != null);
    try testing.expect(std.mem.find(u8, noise, "&.{ 1, 1000 });\n") != null);
    // `sim.spice` solves every unknown, so a deck pins, sweeps and frees none.
    for ([_][]const u8{
        "//! tran 1n, 10n\n",
        "//! solve\n//! tran 1n, 10n\n//! bias V(a) = 1\n",
        "//! solve\n//! tran 1n, 10n\n//! psweep r = 1\n",
        "//! solve\n//! tran 1n, 10n\n//! onoise V(out) = 1\n",
    }) |deck| try testing.expectError(error.BadSyntax, tb_runner.renderRunner(arena, "deck", try tb_directive.parse(arena, deck)));
}

test "the mixed runner hands each point to sim.mixed and refuses the device-table checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = try tb_directive.parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n\n//! wave V(in) = 0, 1\n//! noise none\n");
    d.mixed = sample_mixed;
    const src = try tb_runner.renderRunner(arena, "mx", d);
    try expectAstGen(src);
    // A sweep point is an analysis; the time grid is `sim.mixed.run`'s.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        runMixed(&model, &inst, &x, &forced, &state, &n);\n"));
    try testing.expect(std.mem.find(u8, src, "are not read by the mixed-signal runner") != null);
    try testing.expect(std.mem.find(u8, src, "const mixed_timescale: ?Timescale = .{ .unit = 0.000000001, .precision = 0.000000000001 };\n") != null);
    try testing.expect(std.mem.find(u8, src, "        set(a.x, a.forced, \"in\", pwl(&wave_0, t));\n") != null);
    // §7.3.1 a three-word `reg` is three ports, words 0 to 2.
    try testing.expect(std.mem.find(u8, src, ".word = 2 }") != null);
    try testing.expect(std.mem.find(u8, src, ".word = 3 }") == null);
}

test "the VPI library takes the card, the bias and the waves into its exports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "//! param g = 2m\n//! bias V(n) = 0\n//! time 0, 1n\n//! wave V(in) = 0, 1\n");
    const src = try tb_runner.renderVpiLib(arena, "vpi", d);
    try expectAstGen(src);
    for ([_][]const u8{
        "    g_model.g = cardValue(@TypeOf(g_model.g), 0.002);\n",
        "    set(&g_x, &g_forced, \"n\", 0);\n",
        "    set(&g_x, &g_forced, \"in\", pwl(&wave_0, t));\n",
        "const times = [_]f64{ 0, 0.000000001 };\n",
        "const wave_0 = [_]f64{ 0, 1 };\n",
    }) |want| try testing.expect(std.mem.find(u8, src, want) != null);
    // The host owns the time walk: the library declares no operating point.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, src, "        point("));
}

test "§4.5.2 an operator unknown is never forced, even when every other one is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = try tb_directive.parse(arena, "//! sweep V(a) = 0, 1\n");
    d.op_states = &.{ 2, 5 };
    const src = try tb_runner.renderRunner(arena, "ops", d);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "        forced[5] = null;\n"));
    // After the tie-everything default, before the directives' own pins.
    const untie = std.mem.find(u8, src, "forced[2] = null;").?;
    try testing.expect(std.mem.find(u8, src, "var forced: [n_u]?f64 = @splat(0.0);").? < untie);
    try testing.expect(untie < std.mem.find(u8, src, "set(&x, &forced, \"a\", 0);").?);
}

test "the compile facts a caller sets reach the runner's head" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const off = try tb_runner.renderRunner(arena, "f", .{});
    const on = try tb_runner.renderRunner(arena, "f", .{ .validate_contract = true, .certify = true, .finite_proved = true });
    try testing.expect(std.mem.find(u8, off, "pub const vera_validate_contract = false;\n") != null);
    try testing.expect(std.mem.find(u8, off, "const fd_certify = false;\n") != null);
    try testing.expect(std.mem.find(u8, off, "const finite_proved = false;\n") != null);
    try testing.expect(std.mem.find(u8, on, "pub const vera_validate_contract = true;\n") != null);
    try testing.expect(std.mem.find(u8, on, "const fd_certify = true;\n") != null);
    try testing.expect(std.mem.find(u8, on, "const finite_proved = true;\n") != null);
}

test "§9.15 analysis_name is the kind's spelling unless the line names one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tran = try tb_runner.renderRunner(arena, "an", try tb_directive.parse(arena, "//! time 0, 1n\n"));
    try testing.expect(std.mem.find(u8, tran, "const analysis_name = \"tran\";\n") != null);
    try testing.expect(std.mem.find(u8, tran, "    sim_state = .{ .kind = .tran };\n") != null);
    const named = try tb_runner.renderRunner(arena, "an", try tb_directive.parse(arena, "//! analysis dc mydc\n"));
    try testing.expect(std.mem.find(u8, named, "const analysis_name = \"mydc\";\n") != null);
    try testing.expect(std.mem.find(u8, named, "    sim_state = .{ .kind = .dc };\n") != null);
}

test "`//! spice` lines join into one netlist in source order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "//! spice R1 a b 1k\n//! spice + tc1=0\n//! lrm 5.8\n//! spice C1 b 0 1p\n");
    try testing.expectEqualStrings("R1 a b 1k\n+ tc1=0\nC1 b 0 1p", d.spice);
    try testing.expectEqualStrings("", (try tb_directive.parse(arena, "")).spice);
}

test "the directive line rule: indentation, CRLF and a marker with no space" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const d = try tb_directive.parse(arena, "  //! temp 310\r\n\t//!lrm 5.8\r\n// ! temp 999\n//!\n//!   \n");
    try testing.expectEqual(@as(f64, 310), d.temp);
    try testing.expectEqualStrings("5.8", d.lrm[0]);
    // `//!!` opens with the word `!`, which no directive is.
    try testing.expectError(error.UnknownDirective, tb_directive.parse(arena, "//!! lrm 5.8\n"));
}

test "an lrm cite's annex is one letter, A to H" {
    for ("ABCDEFGH") |letter| {
        const cite = [1]u8{letter};
        try testing.expect(tb_directive.validSection(&cite));
    }
    for ("IJZah") |letter| {
        const cite = [1]u8{letter};
        try testing.expect(!tb_directive.validSection(&cite));
    }
    try testing.expect(tb_directive.validSection("H.2:3"));
}
