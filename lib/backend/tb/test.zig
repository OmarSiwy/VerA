//! Tests for directive parsing and runner generation.
//! LRM: §2.6, §3.4.1, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.6, §5.2.1, §5.4.2, §5.6,
//! §5.8, §5.10.2, §6.5.2.

const std = @import("std");
const tb = @import("../tb.zig");
const tb_directive = @import("directive.zig");
const tb_runner = @import("runner.zig");
const Analysis = tb.Analysis;

/// Shorthand for `std.testing`.
pub const testing = std.testing;

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
    try testing.expect(std.mem.indexOf(u8, tied, "var forced: [n_u]?f64 = @splat(0.0);") != null);
    try testing.expect(std.mem.indexOf(u8, tied, "set(&x, &forced, \"p\", 0.5);") != null);

    // With `solve`, only what a directive names stays pinned.
    const d = try tb_directive.parse(arena, "//! bias V(ctrl) = 1.5\n//! solve\n");
    try testing.expect(d.solve_free);
    const free = try tb_runner.renderRunner(arena, "066_free", d);
    try testing.expect(std.mem.indexOf(u8, free, "var forced: [n_u]?f64 = @splat(null);") != null);
    try testing.expect(std.mem.indexOf(u8, free, "set(&x, &forced, \"ctrl\", 1.5);") != null);
    // The solve runs before the model prints (§5.6: semantics at a solution).
    const solve_at = std.mem.indexOf(u8, free, "solve(&x, &forced").?;
    try testing.expect(solve_at < std.mem.indexOf(u8, free, "point(0, &x").?);

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

    // A space inside the parentheses still parses.
    const spaced = try tb_directive.parse(arena, "//! noise thermal(p, n)#0 name=x\n");
    try testing.expectEqualStrings("thermal(p, n)#0", spaced.noise[0].topo);

    // An unknown key is refused, since nothing would check it.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 whte=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 name\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 interp=spline\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 points=1.0\n"));
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
        const source = try std.fmt.allocPrint(arena, "//! plusargs {s}\n", .{bad});
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
        const source = try std.fmt.allocPrint(arena, "//! checks {s}\n", .{bad});
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
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, src, "        stepPost(&model"));
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
    try testing.expect(std.mem.indexOf(u8, src, "point(5, &x") != null);
}

test "§5.10.2 global events mark the first and last point of each analysis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dc sweep is one analysis: events on its first and last step only.
    const swept = try tb_runner.renderRunner(arena, "062_sweep", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1, 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "sim_state.final_step = true;"));
    try testing.expect(std.mem.indexOf(u8, swept, "sim_state.initial_step = true;\n        sim_state.final_step = false;\n        sim_state.analog_initial = true;\n        const solved0 = solve(&x, &forced, &model, &inst);\n        point(0,") != null);
    try testing.expect(std.mem.indexOf(u8, swept, "sim_state.initial_step = false;\n        sim_state.final_step = true;\n        sim_state.analog_initial = true;\n        const solved2 = solve(&x, &forced, &model, &inst);\n        point(2,") != null);
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
    const z = try arena.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(testing.allocator, z, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
    // The sweep really did become two straight-line blocks.
    try testing.expect(std.mem.indexOf(u8, src, "point(0, &x") != null);
    try testing.expect(std.mem.indexOf(u8, src, "point(1, &x") != null);
    // §3.4.1/§4.2.1.1: card values go through `cardValue`, which rounds for
    // an `integer` parameter.
    try testing.expect(std.mem.indexOf(u8, src, "model.g = cardValue(@TypeOf(model.g), 0.002)") != null);
}
