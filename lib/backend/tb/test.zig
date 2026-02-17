//! Testbench self-checks.
//!
//! Run on std.testing.allocator.
//!
//! LRM clauses this file's code cites: §2.6, §3.4.1, §4.2.1.1, §4.6.3, §4.6.4, §4.6.4.6, §5.2.1, §5.4.2, §5.6, §5.8, §5.10.2, §6.5.2.
//!
//! Cut verbatim from `tb.zig`.

const std = @import("std");
const tb = @import("../tb.zig");
const tb_directive = @import("directive.zig");
const tb_runner = @import("runner.zig");
const Analysis = tb.Analysis;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

    // The DEFAULT netlist: every unknown tied to the reference. 100 fixtures
    // read a rule off `//! bias V(p) = …` on a two-terminal device, and mean the
    // potential ACROSS it — which is only true because the far terminal is
    // grounded and not left open.
    const tied = try tb_runner.renderRunner(arena, "065_tied", try tb_directive.parse(arena, "//! bias V(p) = 0.5\n"));
    try testing.expect(std.mem.indexOf(u8, tied, "var forced: [n_u]?f64 = @splat(0.0);") != null);
    try testing.expect(std.mem.indexOf(u8, tied, "set(&x, &forced, \"p\", 0.5);") != null);

    // With the line, only what a directive names stays pinned — so `bias` and
    // `solve` compose, and a fixture can ground one terminal and solve another.
    const d = try tb_directive.parse(arena, "//! bias V(ctrl) = 1.5\n//! solve\n");
    try testing.expect(d.solve_free);
    const free = try tb_runner.renderRunner(arena, "066_free", d);
    try testing.expect(std.mem.indexOf(u8, free, "var forced: [n_u]?f64 = @splat(null);") != null);
    try testing.expect(std.mem.indexOf(u8, free, "set(&x, &forced, \"ctrl\", 1.5);") != null);
    // And the solve runs BEFORE the model prints: §5.6 semantics are defined at
    // a solution, so a `$strobe` must not see a half-iterated x.
    const solve_at = std.mem.indexOf(u8, free, "solve(&x, &forced").?;
    try testing.expect(solve_at < std.mem.indexOf(u8, free, "point(0, &x").?);

    // It takes no operand: `//! solve V(p)` would suggest a per-unknown list
    // that `bias` already covers from the other side.
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
    // `V(a)` is the node; the two `I` forms are the unknowns lower.zig's
    // `flowUnknown`/`portFlowUnknown` intern, sanitized as codegen spells them.
    try testing.expectEqualStrings("a", d.bias[0].name);
    try testing.expectEqualStrings("flowZ28bZ2cgndZ29", d.bias[1].name);
    try testing.expectEqualStrings("flowZ28Z3ccZ3eZ29", d.sweeps[0].name);
    // The other two spellings a fixture has to be able to write down: §5.4.2's
    // two-terminal branch, which is the ONLY unknown with no source spelling at
    // all, and a §6.5.2 vector element, whose name is `vecElem`'s `b[i]` and
    // never an invented `b__i`. Both must land on the member `emitTopology`
    // prints — see codegen.zig's "the `U` block is the SPELLING contract" test,
    // which pins the other end of the same two strings.
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d.sweeps[1].name);
    try testing.expectEqualStrings("dZ5b1Z5d", d.bias[2].name);
    // Wave 10 pinned this as `error.BadSyntax` — `bias`/`param` split on commas
    // before anything else, so the comma inside `I(a,b)` cut the binding in half
    // and the one unknown with no source spelling was unwritable on two of the
    // three directives that take one. Wave 11 decided it rather than documenting
    // it: `parseBindings` splits on TOP-LEVEL commas, so the same access
    // function means the same thing on every directive.
    const d2 = try tb_directive.parse(arena_state.allocator(), "//! bias I(a,b) = 0.25, V(z) = 3\n");
    try testing.expectEqualStrings("flowZ28aZ2cbZ29", d2.bias[0].name);
    try testing.expectEqual(@as(f64, 0.25), d2.bias[0].value);
    try testing.expectEqualStrings("z", d2.bias[1].name);
    // A binding with no `=` is still an error, and the top-level split must not
    // have swallowed that check with the comma.
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

    // An IEEE 1364 clause is not a clause of this LRM, so it never reaches
    // `lrm` — and `lrm` still refuses one spelled as if it were.
    const inh = try tb_directive.parse(arena, "//! inherited IEEE 1364-2005 18.1 ($dumpfile)\n//! inherited IEEE 1364-2005 8.1.4,8.2\n");
    try testing.expectEqual(@as(usize, 0), inh.lrm.len);
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! lrm inherited IEEE 1364-2005 18.1\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited 18.1\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited IEEE 1364-2005 §18\n"));
    try testing.expectError(error.BadLrmSection, tb_directive.parse(arena, "//! inherited IEEE 1364-2005\n"));

    // On a RUN fixture too: "the LRM prints this example and VerA cannot build
    // it yet" is the more common gap, and it has to be sayable.
    const run = try tb_directive.parse(arena, "//! xfail no array formals in analog functions\n");
    try testing.expectEqual(@as(usize, 0), run.reject.len);
    try testing.expectEqualStrings("no array formals in analog functions", run.xfail.?);
    // A reason is still required — a bare marker names no gap.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! xfail\n"));
}

test "§2.6 a scale factor is an exponent, not a multiplier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The claim is BIT equality with the same spelling written in the model,
    // which is what `Lexer.scaleExp` produces. `200 * 1e-6` rounds twice and is
    // a different double from `200e-6`; a directive that used the first spelled
    // a time no `$abstime < 200u` in a model could ever reach.
    const d = try tb_directive.parse(arena, "//! time 0, 200u, 1n, 2.5m, 1K\n");
    try testing.expectEqual(@as(f64, 0.0), d.times[0]);
    try testing.expectEqual(@as(f64, 200e-6), d.times[1]);
    try testing.expectEqual(@as(f64, 1e-9), d.times[2]);
    try testing.expectEqual(@as(f64, 2.5e-3), d.times[3]);
    try testing.expectEqual(@as(f64, 1e3), d.times[4]);
    // The one that actually regressed: not merely close, EQUAL. The old
    // spelling has to be built at RUNTIME to reproduce it — Zig's comptime
    // float arithmetic is arbitrary-precision, so `200.0 * 1e-6` written as a
    // literal is already the correctly rounded answer and would prove nothing.
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

    // `V(a)` names the net `a`; `V(a,c)` names a POTENTIAL DIFFERENCE, which is
    // derived from two unknowns and is not one. Diagnosed at parse time rather
    // than sanitized into an identifier: `a, c` used to become `aZ2cZ20c` and
    // surface as a testbench that would not build, which the runner reports as
    // an engine bug rather than as the fixture's typo it is.
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! bias V(a,c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! bias V(a, c) = 0.6\n"));
    try testing.expectError(error.BadUnknownName, tb_directive.parse(arena, "//! sweep V(a,c) = 0, 1\n"));

    // A branch FLOW is an unknown and keeps working — §5.4.2 gives it a row.
    // Its name is sanitized because `flow(a,c)` is not a Zig identifier and the
    // `U` member codegen emits for it is not either; the two go through the
    // same `naming.sanitize`, which is what makes the directive and the emitted
    // enum agree on one spelling.
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
    // A line with no `key=value` tail asserts the topology and NOTHING else,
    // which is what keeps every pre-existing `//! noise` line meaning what it
    // meant: an absent field is not an assertion that the field is empty.
    try testing.expect(d.noise[0].name == null);
    try testing.expect(d.noise[0].white == null);
    try testing.expect(!d.noise[0].needsPoint());

    // `none` is a CLAIM that the table is empty. It has to be distinguishable
    // from an absent directive, or a fixture could not say "this model declares
    // no generator" — which is the assertion that catches a source leaking into
    // a device that should have none.
    const none = try tb_directive.parse(arena, "//! noise none\n");
    try testing.expect(none.asserts_noise);
    try testing.expectEqual(@as(usize, 0), none.noise.len);

    const silent = try tb_directive.parse(arena, "//! analysis dc\n");
    try testing.expect(!silent.asserts_noise);

    // A misspelled KIND can never match, and its failure would say nothing
    // about the model, so it is caught here instead.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise pink(a,b)#0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal a,b\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a)#0\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(,b)#0\n"));
    // The §4.6.4.6 source id is mandatory (a digit string or `null`): a line
    // without one asserts nothing about correlation, which is half of what the
    // directive exists to pin.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#x\n"));
    // A node name is NOT checked: nothing here has been told what unknowns the
    // module has, and a wrong one is the assertion working rather than a typo.
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

    // The topology is what it always was — the fields are a TAIL, so the same
    // string still reaches `noise_gens`'s compare.
    try testing.expectEqualStrings("thermal(p,n)#0", d.noise[0].topo);
    try testing.expectEqualStrings("thermal", d.noise[0].name.?);
    try testing.expectEqual(@as(f64, 4e-18), d.noise[0].white.?);
    try testing.expectEqual(@as(f64, 1e-12), d.noise[0].rtol); // the default
    try testing.expect(d.noise[0].needsPoint());

    try testing.expectEqual(@as(f64, 1e-20), d.noise[1].flicker.?);
    try testing.expectEqual(@as(f64, 1.25), d.noise[1].ef.?);
    try testing.expectEqual(@as(f64, 1e-4), d.noise[1].rtol);

    // `interp`/`points` are comptime table data, so the table row asserts
    // nothing that needs a bias.
    try testing.expectEqualStrings("log", d.noise[2].interp.?);
    try testing.expectEqualSlices([2]f64, &.{ .{ 1.0, 1e-18 }, .{ 1e3, 1e-21 } }, d.noise[2].points.?);
    try testing.expect(!d.noise[2].needsPoint());

    // A branch written with a space inside the parentheses still parses: the
    // topology ends at the first space AFTER the `#`, not at the first space.
    const spaced = try tb_directive.parse(arena, "//! noise thermal(p, n)#0 name=x\n");
    try testing.expectEqualStrings("thermal(p, n)#0", spaced.noise[0].topo);

    // An unknown key is a fixture asserting something the runner will silently
    // not check, which is the one failure mode this directive cannot afford.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 whte=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise thermal(a,b)#0 name\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 interp=spline\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! noise table(a,b)#0 points=1.0\n"));
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

    // Canonicalised, so the space a human writes is not a different want than
    // the one the device spells.
    try testing.expectEqualStrings("(q,n)", d.acstim[1].topo);
    // `name=` is OPTIONAL — an absent one asserts nothing, because §4.6.3
    // defaults `analysis_name` to "ac" and a fixture may not care.
    try testing.expect(d.acstim[1].name == null);

    // "This model declares no stimulus" is a claim and silence is not.
    const none = try tb_directive.parse(arena, "//! acstim none\n");
    try testing.expect(none.asserts_acstim);
    try testing.expectEqual(@as(usize, 0), none.acstim.len);

    // An unknown key is a fixture asserting something nothing will check.
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a,b) magnitude=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a,b) mag\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim a,b mag=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (a) mag=1\n"));
    try testing.expectError(error.BadSyntax, tb_directive.parse(arena, "//! acstim (,b) mag=1\n"));
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
    // Four time points, one `x[…] = 1` per point after the first, and exactly
    // one `step(...)` per point: the state has to advance or the operators
    // answer from zero history every time.
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
    // Three sweep points × two times, and a `newState` per sweep point — not
    // per time, and not once for the whole run.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, src, "        point("));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "= newState("));
    // Point numbers are global, so no two transcript blocks share a label.
    try testing.expect(std.mem.indexOf(u8, src, "point(5, &x") != null);
}

test "§5.10.2 global events mark the first and last point of each analysis" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A dc sweep is ONE analysis: first step only, last step only.
    const swept = try tb_runner.renderRunner(arena, "062_sweep", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1, 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, swept, "inst.is_final_step = true;"));
    try testing.expect(std.mem.indexOf(u8, swept, "inst.is_initial_step = true;\n        inst.is_final_step = false;\n        inst.is_analog_initial = true;\n        const solved0 = solve(&x, &forced, &model, &inst);\n        point(0,") != null);
    try testing.expect(std.mem.indexOf(u8, swept, "inst.is_initial_step = false;\n        inst.is_final_step = true;\n        inst.is_analog_initial = true;\n        const solved2 = solve(&x, &forced, &model, &inst);\n        point(2,") != null);
    // §5.2.1 the `analog initial` flag is NOT `is_initial_step`: a dc sweep is one
    // analysis with three SUB-TASKS, so the block re-executes at all three points
    // while the global event fires at one.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, swept, "inst.is_analog_initial = true;"));

    // With `//! time` each sweep block is its own transient run, so each gets
    // its own first and last timepoint.
    const tran = try tb_runner.renderRunner(arena, "063_tran", try tb_directive.parse(arena, "//! sweep V(a) = 0, 1\n//! time 0, 1n, 2n\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_final_step = true;"));
    // Two blocks, so two sub-tasks: one analog-initial pass each, at dt = 0.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, tran, "inst.is_analog_initial = true;"));

    // The single-point default is the Table 5-1 DCOP column: both events fire.
    const op = try tb_runner.renderRunner(arena, "064_op", .{});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "inst.is_initial_step = true;"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, op, "inst.is_final_step = true;"));
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
    // §3.4.1/§4.2.1.1: the card's value goes through `cardValue`, which is what
    // converts it when `g` turns out to be an `integer` parameter.
    try testing.expect(std.mem.indexOf(u8, src, "model.g = cardValue(@TypeOf(model.g), 0.002)") != null);
}
