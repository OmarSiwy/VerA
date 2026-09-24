//! Preprocessor self-checks: source in, expanded text and diagnostics out.
//!
//! Includes the differential tests of the `@Vector` scans against the scalar loops they replaced.
//!
//! LRM clauses this file's code cites: §1, §2.2, §2.4, §2.6.2, §2.8.1, §4.4.1, §4.5.8, §4.7, §9.15.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const pp_annex_d = @import("annex_d.zig");
const pp_prelude = @import("prelude.zig");
const max_expansion_depth = Preprocessor.max_expansion_depth;
const Allocator = Preprocessor.Allocator;
const diag = @import("diag");
const Lexer = @import("../lexer.zig");
const token = @import("../token.zig");
const Parser = @import("../parser.zig");
const DefaultDiscipline = Preprocessor.DefaultDiscipline;
const DefaultTransition = Preprocessor.DefaultTransition;
const Timescale = Preprocessor.Timescale;
const NetType = Preprocessor.NetType;
const NetTypeRegion = Preprocessor.NetTypeRegion;
const CellRegion = Preprocessor.CellRegion;
const Drive = Preprocessor.Drive;
const DriveRegion = Preprocessor.DriveRegion;
const predefined_macros = Preprocessor.predefined_macros;
const process = Preprocessor.process;
const Pp = Preprocessor.Pp;
const scan_stops = Preprocessor.scan_stops;
const findStop = Preprocessor.findStop;
const directive = Preprocessor.directive;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const testing = std.testing;

/// Preprocess without the std-def prelude, on an arena backed by the testing
/// allocator; the result is duped so the arena can be torn down (leak-checked).
pub fn runTest(src: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = (try process(arena_state.allocator(), src, .{ .std_defs = false, .bag = &bag })).text;
    return testing.allocator.dupe(u8, text);
}

pub fn expectPp(expected: []const u8, src: []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// The line-number contract: nothing this stage deletes may change the count.
pub fn expectPreserved(src: []const u8, present: []const []const u8, absent: []const []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqual(
        std.mem.count(u8, src, "\n"),
        std.mem.count(u8, got, "\n"),
    );
    for (present) |s| try testing.expect(std.mem.indexOf(u8, got, s) != null);
    for (absent) |s| try testing.expect(std.mem.indexOf(u8, got, s) == null);
}

/// Fails with `code`, and the span it reports lands inside the file it names.
pub fn expectFail(src: []const u8, code: diag.Code) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    try testing.expectError(error.PreprocessFailed, process(
        arena_state.allocator(),
        src,
        .{ .std_defs = false, .bag = &bag },
    ));
    try testing.expectEqual(@as(usize, 1), bag.count());
    const e = bag.at(0);
    try testing.expectEqual(code, e.code);
    try testing.expect(bag.failed());
    // A preprocess span is file-local: it must index the file it names.
    try testing.expect(e.file != null);
    try testing.expect(e.span.end <= bag.fileText(e.file.?).len);
    // The title carries the condition; the message may not repeat it.
    try testing.expect(std.mem.indexOf(u8, e.message, "LRM") == null);
}

test "findStop agrees with the scalar loop it replaced, at every tail boundary" {
    // The reference: the loop `scan` and `stripComments` used to run inline,
    // one byte at a time. `findStop`'s vector block must never disagree with it.
    const scalar = struct {
        fn find(text: []const u8, from: usize, comptime stops: []const u8) usize {
            var i = from;
            while (i < text.len) : (i += 1) {
                for (stops) |s| if (text[i] == s) return i;
            }
            return i;
        }
    }.find;

    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    // Every length from the empty slice through three full vectors, so both
    // tail boundaries and the no-vector-iteration case are covered.
    var buf: [3 * 64 + 1]u8 = undefined;
    for (0..3 * lanes + 1) |len| {
        for (0..64) |_| {
            // A byte set that hits the stops often enough to land one in every
            // lane position, and rarely enough to leave long ordinary runs.
            for (buf[0..len]) |*b| b.* = switch (rand.uintLessThan(u8, 10)) {
                0 => '"',
                1 => '\\',
                2 => '`',
                3 => '/',
                4 => '\n',
                else => 'a' + rand.uintLessThan(u8, 26),
            };
            const text = buf[0..len];
            // Sweep `from` too: `scan` never calls this at offset 0 only.
            for (0..len + 1) |from| {
                try testing.expectEqual(scalar(text, from, scan_stops), findStop(text, from, scan_stops));
                try testing.expectEqual(scalar(text, from, "\"\\/"), findStop(text, from, "\"\\/"));
            }
        }
    }
}

test "putNewlines emits exactly the newlines the byte loop it replaced did" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    var prng: std.Random.DefaultPrng = .init(0xf00d);
    const rand = prng.random();
    var buf: [200]u8 = undefined;
    for (0..buf.len + 1) |len| {
        for (buf[0..len]) |*b| b.* = if (rand.uintLessThan(u8, 4) == 0) '\n' else 'x';
        const span = buf[0..len];

        // The reference: `for (span) |c| if (c == '\n') append('\n');`
        var want: usize = 0;
        for (span) |c| want += @intFromBool(c == '\n');

        var pp: Pp = .{ .arena = arena, .opts = .{ .bag = &bag } };
        try pp.putNewlines(span);
        try testing.expectEqual(want, pp.out.items.len);
        for (pp.out.items) |c| try testing.expectEqual(@as(u8, '\n'), c);
    }
}

test "§2.4 comments vanish, newlines do not — but the separator survives" {
    try expectPp("a\n\nb\n", "a// gone\n/* two\n   lines */b\n");
    try expectPp("\"// not a comment\"\n", "\"// not a comment\"\n");
    // §2.4 block comments do not nest: the first `*/` closes it.
    try expectPp("x   y\n", "x /* a /* b */ y\n");
    try expectFail("x\n/* never closed\n", .E0102);

    // §2.2 makes a comment a token SEPARATOR, so a comment with no newline in
    // it still has to leave one byte of whitespace behind. Dropping it welded
    // the neighbours: these two used to reach the lexer as the integer `12` and
    // as the single operator `<=`, and both compiled without a word.
    try expectPp("1 2", "1/*c*/2");
    try expectPp("a < = b", "a </*c*/= b");
    // A multi-line comment already separates via its newlines; it must not gain
    // a spurious extra space.
    try expectPp("1\n2", "1/*\n*/2");
}

test "§10.4 object-like and function-like macros" {
    try expectPp("\n3.0*v", "`define GAIN 3.0\n`GAIN*v");
    try expectPp("\n((v)*(v))", "`define SQ(x) ((x)*(x))\n`SQ(v)");
    // Nested expansion (fixture ch10 07_nested_macros).
    try expectPp(
        "\n\n(((v)*(v)) + (v))",
        "`define I(x) ((x)*(x))\n`define O(x) (`I(x) + (x))\n`O(v)",
    );
    // Multi-line macro text (fixture ch10 06_define_multiline).
    try expectPp("\n\n(1 + 2)", "`define P (1 + \\\n2)\n`P");
    // A formal is only substituted as a whole identifier, and never inside a
    // string or after a '`'.
    try expectPp("\n\"x\" ax 1", "`define M(x) \"x\" ax x\n`M(1)");
    // Commas inside nested parens do not split arguments.
    try expectPp("\n(max(a,b))+(c)", "`define A(p,q) (p)+(q)\n`A(max(a,b), c)");
    try expectFail("`define SQ(x) x\n`SQ\n", .E0116);
    try expectFail("`define SQ(x) x\n`SQ(1,2)\n", .E0117);
    // A formal spelled INSIDE a §2.8.1 escaped identifier is part of that
    // identifier, not a use of the formal — `substitute` treats `\…` as opaque
    // exactly as `scan` and `stripComments` do.
    try expectPp("\nreal \\sig-x ;", "`define M(x) real \\sig-x ;\n`M(1)");
}

test "§10.4 macro argument brackets must match their openers" {
    // Matched nesting of all three bracket kinds is opaque to the comma split.
    try expectPp("\n{[(a)],b}", "`define SQ(x) x\n`SQ({[(a)],b})");
    // One shared depth counter let ANY of `)]}` close the list — `` `SQ(2.0] ``
    // compiled clean and crossed nestings mis-sliced the arguments. A closer
    // that does not match its opener is E0120: the `(` it abandons really is
    // unterminated.
    try expectFail("`define SQ(x) x\n`SQ(2.0]\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ({a)}\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ([1,2)]\n", .E0120);
}

test "§10.4 a nested invocation in an actual argument is not recursion" {
    // §10.4 hands text macros to IEEE Std 1364, whose recursion rule is about
    // the macro's TEXT referring to itself — a property of the DEFINITION.
    // `MAX`'s text refers only to its formals; the nested use sits in the CALL,
    // and arguments are fully expanded before substitution (fixture ch10 49).
    // The old splice-then-rescan model reported E0118 "MAX -> MAX" here.
    try expectPp(
        "\n((((1.0)>(2.0)?(1.0):(2.0)))>(3.0)?(((1.0)>(2.0)?(1.0):(2.0))):(3.0))",
        "`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`MAX(1.0,2.0),3.0)",
    );
    // An object-like use inside an argument expands there too, and a
    // function-like macro nested in ANOTHER macro's argument keeps working.
    try expectPp(
        "\n\n((7.0)>(2.0)?(7.0):(2.0))",
        "`define A 7.0\n`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`A,2.0)",
    );
    // Genuine self-reference in the TEXT is still the E0118 the rule is about:
    // object-like, function-like, and mutual (indirect).
    try expectFail("`define R `R\n`R\n", .E0118);
    try expectFail("`define F(x) `F(x)\n`F(1)\n", .E0118);
    try expectFail("`define A(x) `B(x)\n`define B(y) `A(y)\n`A(1)\n", .E0118);

    // E0119's ceiling now counts argument pre-expansion too: nested same-macro
    // calls never repeat a name on `expanding`, so the DEPTH is what bounds
    // the native stack.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "`define M(x) (x)\n");
    for (0..max_expansion_depth + 1) |_| try src.appendSlice(testing.allocator, "`M(");
    try src.appendSlice(testing.allocator, "1");
    for (0..max_expansion_depth + 1) |_| try src.appendSlice(testing.allocator, ")");
    try src.appendSlice(testing.allocator, "\n");
    try expectFail(src.items, .E0119);
}

test "escaped identifiers reach `undef, the conditionals and `default_discipline" {
    // Syntax 10-3 / A.9.3: every directive whose operand is an `identifier`
    // takes the §2.8.1 spelling, not just `define (fixture ch10 50).
    try expectPreserved("`define \\M-X 1\n`ifdef \\M-X\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    try expectPreserved("`define \\M-X 1\n`undef \\M-X\n`ifndef \\M-X\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved("`define \\M-X 1\n`ifdef NOPE\na\n`elsif \\M-X\nb\n`else\nc\n`endif\n", &.{"b"}, &.{ "a", "c" });

    // §10.2: annex D.1's `discipline \logic ;` is only nameable this way, and
    // §2.8.1 makes the recorded name the bare bytes between `\` and the space.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const defs = (try process(arena_state.allocator(), "`default_discipline \\logic\n", .{
        .std_defs = false,
        .bag = &bag,
    })).directives.disciplines;
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("logic", defs[0].discipline);
}

test "§10.4 undef, and IEEE 1364 conditionals" {
    try expectPreserved(
        "`define A\n`undef A\n`ifdef A\ntaken\n`else\nother\n`endif\n",
        &.{"other"},
        &.{"taken"},
    );
    try expectPreserved(
        "`define S\n`ifdef F\n1\n`elsif S\n2\n`else\n3\n`endif\n",
        &.{"2"},
        &.{ "1", "3" },
    );
    try expectPreserved(
        "`define O\n`define I\n`ifdef O\n`ifdef I\nsix\n`else\ntwo\n`endif\n`else\none\n`endif\n",
        &.{"six"},
        &.{ "two", "one" },
    );
    try expectPreserved("`ifndef NOPE\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    // An undefined macro inside a dead arm is not an error.
    try expectPreserved("`ifdef NOPE\n`MISSING\n`endif\n", &.{}, &.{"MISSING"});
    try expectFail("`ifdef A\nx\n", .E0101);
    try expectFail("`endif\n", .E0108);
    try expectFail("`ifdef A\n`else\n`else\n`endif\n", .E0106);
}

test "§10.5 predefined macros survive undef and resetall" {
    try expectPreserved("`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved(
        "`undef __VAMS_ENABLE__\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n",
        &.{"yes"},
        &.{},
    );
    // ... and so do user macros: IEEE 1364 §19.3 "The text macro facility is
    // not affected by the compiler directive `resetall" (fixture ch10
    // audit_macro_resetall_preserves_user).
    try expectPreserved("`define V 2.0\n`resetall\n`V\n", &.{"2.0"}, &.{});
    try expectPreserved("`resetall\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
}

test "§9.15 Table 9-27 reads `timescale back, in seconds" {
    const T = struct {
        /// The published timescale for `src`, which is the whole §9.15 surface:
        /// it contributes nothing to the output text (the first row pins that).
        fn ts(src: []const u8) !?Timescale {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            return (try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .bag = &bag,
            })).directives.timescale();
        }
    };
    // Table 9-27's units column is "s", not ticks.
    const t = (try T.ts("`timescale 1ns/1ps\n")).?;
    try testing.expectEqual(@as(f64, 1e-9), t.unit);
    try testing.expectEqual(@as(f64, 1e-12), t.precision);
    // Every magnitude on IEEE 1364 Table 19-1's grid, and the coarsest unit.
    const t2 = (try T.ts("`timescale 100us / 10 ns\n")).?;
    try testing.expectEqual(@as(f64, 100e-6), t2.unit);
    try testing.expectEqual(@as(f64, 10e-9), t2.precision);
    // No directive is NOT a default: §9.15 says "as specified in `timescale",
    // and with nothing specified the parameter is not known (E0811).
    try testing.expectEqual(@as(?Timescale, null), try T.ts("module m; endmodule\n"));
    // §19.6 `resetall returns it to that state.
    try testing.expectEqual(@as(?Timescale, null), try T.ts("`timescale 1ns/1ps\n`resetall\n"));
    // Off Table 19-1 in each of the three ways, plus §19.9's ordering rule and
    // the two ways of writing the wrong number of operands. All six are E0142
    // now: a directive with no reading cannot publish a timescale, and while
    // this was silent the mistake surfaced as §9.15's "not known" at the far end
    // of the compilation, or — in a model that never asked — nowhere at all.
    for ([_][]const u8{
        "`timescale 2ns/1ps\n", // magnitude
        "`timescale 1sec/1ps\n", // unit name
        "`timescale 1ns 1ps\n", // no slash
        "`timescale 1ps/1ns\n", // precision coarser than the unit
        "`timescale 1ns/1ps junk\n", // §19.9 takes two operands and no more
        "`timescale\n", // and they are not optional
    }) |src| try expectFail(src, .E0142);
    // The last one in the stream is the one in force (one elaborated module).
    try testing.expectEqual(@as(f64, 1e-3), (try T.ts("`timescale 1ns/1ps\n`timescale 1ms/1us\n")).?.unit);
}

test "directives that contribute no text, and rejected ones" {
    try expectPp(
        "\n\n\n\n",
        "`timescale 1ns/1ps\n`default_nettype wire\n`celldefine\n`pragma f harmless\n",
    );
    try expectPp("\n\n", "`default_discipline electrical\n`default_transition 1n\n");
    // §10.6 is the exception: passed through verbatim for the parser, which is
    // the only stage that knows where a design element starts.
    try expectPp(
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
    );
    // ... but still dies with an inactive `ifdef arm, like any other directive.
    try expectPp("\n\n\n", "`ifdef NOPE\n`begin_keywords \"VAMS-2.3\"\n`endif\n");
    try expectFail("`MISSING\n", .E0115); // fixture ch10 23
    try expectFail("`nosuchdirective_or_macro\n", .E0115);
    try expectFail("`define R `R\n`R\n", .E0118); // cycle guard
}

// ---------------------------------------------------------------------------
// The three IEEE 1364 directives that scope FORWARD: §19.2 `default_nettype,
// §19.1 `celldefine, §19.10 `unconnected_drive. §10.1's scope sentence is the
// shared rule; `Region.inForce` is the shared reader.
// ---------------------------------------------------------------------------

/// Preprocess `src` and hand back the three region lists, which is the whole of
/// what these directives contribute to a compilation.
pub fn regionsOf(arena: Allocator, src: []const u8) !struct {
    nettypes: []const NetTypeRegion,
    cells: []const CellRegion,
    drives: []const DriveRegion,
} {
    var bag: diag.Bag = .init(arena);
    const d = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).directives;
    return .{ .nettypes = d.nettypes, .cells = d.cells, .drives = d.drives };
}

test "IEEE 1364 §19.2 `default_nettype publishes a region per directive" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every value on §19.2's closed list parses, `none` included. Eleven
    // directives, eleven events, in text-stream order.
    const all = try regionsOf(arena,
        \\`default_nettype wire
        \\`default_nettype tri
        \\`default_nettype tri0
        \\`default_nettype tri1
        \\`default_nettype wand
        \\`default_nettype triand
        \\`default_nettype wor
        \\`default_nettype trior
        \\`default_nettype trireg
        \\`default_nettype uwire
        \\`default_nettype none
        \\
    );
    try testing.expectEqual(@as(usize, 11), all.nettypes.len);
    try testing.expectEqual(NetType.wire, all.nettypes[0].value);
    try testing.expectEqual(NetType.uwire, all.nettypes[9].value);
    try testing.expectEqual(NetType.none, all.nettypes[10].value);

    // §19.2's list is CLOSED, and it is not §10.2's: `reg`, `real` and
    // `supply0` are `default_discipline qualifiers and not net types.
    for ([_][]const u8{
        "`default_nettype reg\n",
        "`default_nettype real\n",
        "`default_nettype supply0\n",
        "`default_nettype wires\n", // a typo, not a twelfth type
        "`default_nettype\n", // no brackets in §19.2: mandatory
        "`default_nettype wire tri\n", // and exactly one
    }) |src| try expectFail(src, .E0140);

    // §10.1: a region runs from the directive to the next one. Before the first
    // there is no region, and §19.2 names the state there: wire.
    const r = try regionsOf(arena, "module a; endmodule\n`default_nettype none\nmodule b; endmodule\n");
    try testing.expectEqual(@as(usize, 1), r.nettypes.len);
    try testing.expectEqual(NetType.wire, NetTypeRegion.inForce(r.nettypes, 0, .default));
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(r.nettypes, r.nettypes[0].at, .default));
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(r.nettypes, r.nettypes[0].at + 1, .default));

    // IEEE 1364 §19.6, said twice: `resetall returns it to `wire`, and that is
    // an EVENT and not an erasure — the region above the reset keeps its value.
    const reset = try regionsOf(arena, "`default_nettype none\n`resetall\n");
    try testing.expectEqual(@as(usize, 2), reset.nettypes.len);
    try testing.expectEqual(NetType.none, reset.nettypes[0].value);
    try testing.expectEqual(NetType.wire, reset.nettypes[1].value);
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(reset.nettypes, reset.nettypes[0].at, .default));
}

test "IEEE 1364 §19.1 `celldefine tags the modules between the pair" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tag is a REGION, so what a consumer asks is "was this offset inside
    // one". Three modules, one of them a cell.
    const src =
        \\module outside_before; endmodule
        \\`celldefine
        \\module the_cell; endmodule
        \\`endcelldefine
        \\module outside_after; endmodule
        \\
    ;
    const r = try regionsOf(arena, src);
    try testing.expectEqual(@as(usize, 2), r.cells.len);
    try testing.expect(r.cells[0].value);
    try testing.expect(!r.cells[1].value);
    // Before the pair, inside it, after it.
    try testing.expect(!CellRegion.inForce(r.cells, 0, false));
    try testing.expect(CellRegion.inForce(r.cells, r.cells[0].at, false));
    try testing.expect(!CellRegion.inForce(r.cells, r.cells[1].at, false));

    // §19.6 again: the reset closes an open `celldefine.
    const reset = try regionsOf(arena, "`celldefine\n`resetall\n");
    try testing.expectEqual(@as(usize, 2), reset.cells.len);
    try testing.expect(!reset.cells[1].value);
}

test "IEEE 1364 §19.10 `unconnected_drive publishes pull0/pull1 regions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try regionsOf(arena,
        \\module before_any_directive; endmodule
        \\`unconnected_drive pull1
        \\`nounconnected_drive
        \\`unconnected_drive pull0
        \\
    );
    try testing.expectEqual(@as(usize, 3), r.drives.len);
    try testing.expectEqual(Drive.pull1, r.drives[0].value);
    try testing.expectEqual(Drive.float, r.drives[1].value);
    try testing.expectEqual(Drive.pull0, r.drives[2].value);
    // Above the first directive there is no region, and §19.10's state there is
    // "not pulled". A query AT a directive's offset is inside its region — the
    // offset is where the directive's own collapsed text ends — which is what
    // makes a module declared on the next line the subject of it.
    try testing.expectEqual(Drive.float, DriveRegion.inForce(r.drives, 0, .default));
    try testing.expectEqual(Drive.pull1, DriveRegion.inForce(r.drives, r.drives[0].at, .default));

    // §19.10's operand is a two-way alternation and it is not optional: the
    // form that takes none is the separate directive `nounconnected_drive.
    for ([_][]const u8{
        "`unconnected_drive\n",
        "`unconnected_drive pull2\n",
        "`unconnected_drive float\n", // `.float` is the other directive's value
        "`unconnected_drive pull1 pull0\n",
    }) |src| try expectFail(src, .E0141);
    // The operand-less directives do NOT police their line — `nounconnected_drive
    // pull1` is accepted and the trailing word collapses with the directive,
    // exactly as it does after `celldefine` and (necessarily) after `pragma`.
    // ponytail: one more handler would catch the typo of writing the closing
    // directive with the opening one's operand. Worth it the day a model does.
    try testing.expectEqual(Drive.float, (try regionsOf(arena, "`nounconnected_drive pull1\n")).drives[0].value);

    const reset = try regionsOf(arena, "`unconnected_drive pull1\n`resetall\n");
    try testing.expectEqual(Drive.float, reset.drives[1].value);
}

test "§10.1 scopes a directive across a source file boundary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // §10.1: "The scope of compiler directives extends from the point where it
    // is processed, ACROSS ALL FILES PROCESSED, to the point where another
    // compiler directive supersedes it or the processing completes." So an
    // `include neither opens nor closes a region — the annex D files are the
    // only ones this test can include without a filesystem, and they are enough
    // because what is being checked is that the boundary changes NOTHING.
    var bag: diag.Bag = .init(arena);
    const d = (try process(arena,
        \\`default_nettype none
        \\`celldefine
        \\`include "constants.vams"
        \\module after_the_include; endmodule
        \\
    , .{ .std_defs = false, .bag = &bag })).directives;
    const nettypes = d.nettypes;
    const cells = d.cells;

    // One event each — the included file wrote none — and both still in force
    // at the end of the stream, which is the far side of the boundary.
    try testing.expectEqual(@as(usize, 1), nettypes.len);
    try testing.expectEqual(@as(usize, 1), cells.len);
    const eof = std.math.maxInt(u32);
    try testing.expectEqual(NetType.none, NetTypeRegion.inForce(nettypes, eof, .default));
    try testing.expect(CellRegion.inForce(cells, eof, false));
}

test "§10.7 `__FILE__ and `__LINE__" {
    // fixtures ch10 21, 22. The default `Options.file_name` is "<source>".
    try expectPp("\"<source>\"\n", "`__FILE__\n");
    // PHYSICAL lines, counted through the comment the stripper deleted and
    // through a directive that collapsed to its newline.
    try expectPp("\n\n\n4 4\n", "// c\n`define X 1\n\n`__LINE__ `__LINE__\n");
    // fixture ch10 44: IEEE 1364 §19.7 numbers the line AFTER the directive.
    try expectPp("\n100\n101\n", "`line 100 \"virtual.va\" 0\n`__LINE__\n`__LINE__\n");
    try expectPp("\n\"virtual.va\"\n", "`line 100 \"virtual.va\" 0\n`__FILE__\n");
    try expectFail("`line\n", .E0128);
    try expectFail("`line nope\n", .E0128);
}

test "§10.2 `default_discipline Syntax 10-1" {
    try expectPp("\n\n\n", "`default_discipline\n`default_discipline electrical\n`default_discipline electrical wire\n");
    // fixture ch10 45: a discipline name is not one of the fifteen qualifiers.
    try expectFail("`default_discipline electrical electrical\n", .E0127);
    try expectFail("`default_discipline electrical wire junk\n", .E0127);
}

test "§10.3 `default_transition Syntax 10-2" {
    // The published §10.3 events for `src`, which is the whole surface §4.5.8
    // consumes: the value, and the output offset it takes effect from.
    const T = struct {
        fn ev(src: []const u8) ![]const DefaultTransition {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            const out = (try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .bag = &bag,
            })).directives.transitions;
            return testing.allocator.dupe(DefaultTransition, out);
        }
    };

    const one = try T.ev("`default_transition 4n\n");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(f64, 4e-9), one[0].value.?);

    // §10.3's supersession sentence: BOTH are published, in text order, so the
    // consumer can pick "the directive which immediately precedes" a call
    // rather than being handed one latched value.
    const two = try T.ev("`default_transition 8n\n`default_transition 4n\n");
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(f64, 8e-9), two[0].value.?);
    try testing.expectEqual(@as(f64, 4e-9), two[1].value.?);
    try testing.expect(two[0].at < two[1].at);

    // Every §2.6.2 spelling of the same time, since the operand is read in a
    // text stage and not by the number lexer proper.
    for ([_][]const u8{ "4n\n", "4e-9\n", "0.000000004\n", "4_000p\n" }) |t| {
        const src = try std.fmt.allocPrint(testing.allocator, "`default_transition {s}", .{t});
        defer testing.allocator.free(src);
        const e = try T.ev(src);
        defer testing.allocator.free(e);
        try testing.expectEqual(@as(f64, 4e-9), e[0].value.?);
    }

    // fixture ch10 48: the operand is not bracketed in Syntax 10-2, so it is
    // mandatory — and the bare form is NOT a request for the simulator default.
    try expectFail("`default_transition\n", .E0129);
    try expectFail("`default_transition    \n", .E0129);
    try expectFail("`default_transition electrical\n", .E0129);
    try expectFail("`default_transition -4n\n", .E0129);
    try expectFail("`default_transition 4n junk\n", .E0129);
}

test "`include resolves the built-in annex D files" {
    // fixture ch10 18_include_constants
    const got = try runTest("`include \"constants.vams\"\n`P_CELSIUS0 `P_K\n");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "273.15") != null);
    try testing.expect(std.mem.indexOf(u8, got, "1.3806503e-23") != null);
    try expectFail("`include \"no_such_file.vams\"\n", .E0126);
    try expectFail("`include nonsense\n", .E0122);

    // annex D.3 is shipped too, and is NOT preloaded: it has to be asked for.
    const d3 = try runTest("`include \"driver_access.vams\"\n`DRIVER_WAND\n");
    defer testing.allocator.free(d3);
    try testing.expect(std.mem.indexOf(u8, d3, "32'b10000000000") != null);
}

test "§10.4 the NAME may be escaped and the TEXT may not begin with __VAMS_" {
    // Syntax 10-3: text_macro_identifier ::= identifier, and A.9.3 makes that
    // simple OR escaped. §2.8.1 drops the `\` and the terminating white space,
    // so the definition and the use key on the same bytes.
    try expectPp("\n3.0 *v", "`define \\MY-GAIN 3.0\n`\\MY-GAIN *v");
    // An escaped name can only be object-like, and that falls out of the two
    // rules rather than being a restriction of its own: §2.8.1 ends the name at
    // the first white space, while §10.4 requires the formal list's `(` to
    // TOUCH the name — so `\SQ!(x)` is one nine-character name, not a call.
    try expectPp("\n1", "`define \\SQ!(x) 1\n`\\SQ!(x)");
    // §10.4: the macro TEXT shall not begin with __VAMS_ ...
    try expectFail("`define MY_ENABLE __VAMS_ENABLE__\n", .E0139);
    // ... and the NAME is unrestricted, which is the other half of the pair.
    try expectPp("\n7.0", "`define __VAMS_USER 7.0\n`__VAMS_USER");
}

test "annex D prelude is deterministic and self-guarded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "`include \"disciplines.vams\"\nmodule m; endmodule\n";
    // One bag per run: the compilation unit must be the FIRST file registered.
    var bag1: diag.Bag = .init(arena);
    var bag2: diag.Bag = .init(arena);
    const out_a = try process(arena, src, .{ .bag = &bag1 });
    const out_b = try process(arena, src, .{ .bag = &bag2 });
    const a = out_a.text;
    const b = out_b.text;
    const n1 = out_a.prelude_len;
    const n2 = out_b.prelude_len;
    try testing.expectEqualStrings(a, b); // determinism == cache identity
    try testing.expectEqual(n1, n2);

    // annex D.1 reached the output exactly once, annex D.2 defined its macros.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, a, "discipline electrical;"),
    );
    try testing.expect(std.mem.indexOf(u8, a[0..n1], "nature Voltage;") != null);
    // The re-`include collapses to just the newlines it consumed (line numbers
    // inside an included file are preserved even when its guard empties it).
    try testing.expectEqualStrings(
        "module m; endmodule\n",
        std.mem.trimStart(u8, a[n1..], "\n"),
    );
}

// The snapshot's whole correctness condition: replaying it must leave `Pp` in
// the state `runStdDefs` leaves it in. This runs the long way ONCE more, by
// hand, and compares all four things `Prelude` carries — anything a future
// prelude file writes into `Pp` and `Prelude` does not capture fails here, in
// `zig build test`, rather than in a diagnostic nobody reads.
test "the prelude snapshot replays exactly what running annex D.2/D.1/E.1 produces" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same starting state `process` and `buildPrelude` both establish.
    var bag: diag.Bag = .init(arena);
    var pp: Pp = .{ .arena = arena, .opts = .{ .bag = &bag } };
    _ = try bag.addFile("<source>", "");
    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }
    try pp.runStdDefs();

    const p = try pp_prelude.preludeSnapshot();
    try testing.expectEqualStrings(pp.out.items, p.text);
    try testing.expectEqual(pp.segs.items.len, p.segs.len);
    for (pp.segs.items, p.segs) |a, b| {
        try testing.expectEqual(a.out_start, b.out_start);
        try testing.expectEqual(a.in_start, b.in_start);
        try testing.expectEqual(a.file, b.file);
    }
    // The macro sets agree, both ways. The difference is exactly §10.5's
    // predefined set, which the snapshot deliberately does not carry — taken
    // from the array rather than written as a number, so adding one is not a
    // test edit.
    try testing.expectEqual(pp.macros.count(), p.macros.len + predefined_macros.len);
    for (p.macros) |d| {
        const live = pp.macros.get(d.name) orelse return error.MissingMacro;
        try testing.expectEqualStrings(live.body, d.macro.body);
        try testing.expectEqual(live.is_func, d.macro.is_func);
        try testing.expectEqual(live.params.len, d.macro.params.len);
    }
    // And the three file registrations the segments index by position — the
    // strip marks included, or a replayed file renders columns differently
    // from a freshly run one.
    for (p.files, 1..) |f, id| {
        try testing.expectEqualStrings(f.name, bag.fileName(@enumFromInt(id)));
        try testing.expectEqualStrings(f.stripped, bag.fileText(@enumFromInt(id)));
        try testing.expectEqualSlices(diag.StripMark, f.marks, bag.fileMarks(@enumFromInt(id)));
    }
}

// The token snapshot's correctness condition, and it needs its OWN long way
// round: `tokenizeSeeded` and `tokenize` are two code paths over one buffer, so
// this lexes the whole preprocessed text from offset 0 — touching no snapshot —
// and compares every token of it against the seeded result. A snapshot that
// dropped a token, kept the `.eof`, or recorded a relative offset diverges here.
//
// Two inputs, because the seam moves: with an annex E.2 netlist the prelude is
// followed by synthesized modules and only THEN the user's source, and the seed
// length must still be the std-defs prefix alone.
test "the prelude token snapshot lexes exactly what lexing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = (try process(arena,
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  analog I(p, n) <+ V(p, n) / r;
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist })).text;

        // THE LONG WAY: no seed, one scan of the whole buffer.
        const long = try Lexer.Lexer.tokenize(arena, text);
        const seeded = try Lexer.Lexer.tokenizeSeeded(arena, text, try pp_prelude.preludeTokens(true));

        try testing.expectEqual(long.len, seeded.len);
        try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
        try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));

        // The premise the seam rests on, checked rather than asserted in prose:
        // the snapshot's bytes ARE a prefix of the text, at offset 0.
        const p = try pp_prelude.preludeSnapshot();
        try testing.expect(std.mem.startsWith(u8, text, p.text));
        // ...and the snapshot stops one token short of `.eof`, which belongs to
        // whatever buffer is actually being lexed.
        try testing.expect(p.tags.len != 0 and p.tags[p.tags.len - 1] != .eof);
    }
}

test "`--no-std-defs` gets no seed, and lexes the same either way" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const text = (try process(arena, "module m; endmodule\n", .{ .std_defs = false, .bag = &bag })).text;

    try testing.expectEqual(@as(?Lexer.Lexer.Seed, null), try pp_prelude.preludeTokens(false));
    try testing.expectEqual(@as(?*const Parser.Parser.Seed, null), try pp_prelude.preludeAst(false));
    const long = try Lexer.Lexer.tokenize(arena, text);
    const seeded = try Lexer.Lexer.tokenizeSeeded(arena, text, try pp_prelude.preludeTokens(false));
    try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
    try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));
}

/// Structural equality by REFLECTION, not by a hand-written field list: the AST
/// declaration types are ~20 structs of slices, and a hand-written comparator is
/// a second surface that goes stale the day someone adds a field — the exact
/// failure the test below exists to prevent. Slices of `u8` compare by CONTENT,
/// deliberately: the snapshot's names borrow the process-lifetime prelude text
/// and a fresh parse's borrow the compilation's copy of the same bytes, so
/// identical pointers are not the claim and identical bytes are.
pub fn expectDeepEqual(comptime T: type, a: T, b: T) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            if (p.child == u8) return testing.expectEqualStrings(a, b);
            try testing.expectEqual(a.len, b.len);
            for (a, b) |x, y| try expectDeepEqual(p.child, x, y);
        },
        .@"struct" => |s| inline for (s.fields) |f| {
            try expectDeepEqual(f.type, @field(a, f.name), @field(b, f.name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            try testing.expectEqual(@as(Tag, a), @as(Tag, b));
            inline for (u.fields) |f| {
                if (@as(Tag, a) == @field(Tag, f.name))
                    try expectDeepEqual(f.type, @field(a, f.name), @field(b, f.name));
            }
        },
        .optional => |o| {
            try testing.expectEqual(a == null, b == null);
            if (a) |x| try expectDeepEqual(o.child, x, b.?);
        },
        else => try testing.expectEqual(a, b),
    }
}

// The AST snapshot's correctness condition, and like the token one it needs its
// OWN long way round. The determinism test at the top of this file CANNOT grade
// a cache: after this change both of its runs take the cached path, so a
// snapshot that dropped a declaration is byte-identical in both and passes.
//
// So this parses the whole preprocessed text from token 0 with NO seed and
// compares the result against the seeded parse in FULL — the interner's contents
// AND its ids AND its map, every column of every `ExprStore` row, the statement
// pool, all four declaration arrays to their leaves, and the parser state that
// is not in the `SourceFile` at all (`access_names`, `pos`, `gen_construct`).
//
// Two inputs, for the same reason the token test has two: with an annex E.2
// netlist the prelude is followed by synthesized modules, so the declarations
// landing immediately after the seam are not the user's.
test "the prelude AST snapshot parses exactly what parsing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = (try process(arena,
            \\nature Pressure;
            \\  units = "Pa"; access = Pr; abstol = 1e-6;
            \\endnature
            \\discipline fluid; potential Pressure; enddiscipline
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  real acc[0:2];
            \\  analog begin : body
            \\    integer k;
            \\    for (k = 0; k < 3; k = k + 1) acc[k] = k * 2.0;
            \\    I(p, n) <+ V(p, n) / r + acc[1];
            \\  end
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist })).text;

        var toks = try Lexer.Lexer.tokenize(arena, text);
        const tags = toks.items(.tag);
        const starts = toks.items(.start);

        // THE LONG WAY: no seed, one parse of every token from 0.
        var lbag: diag.Bag = .init(arena);
        var lp = Parser.Parser.init(arena, text, tags, starts, &lbag);
        const long = try lp.parseSourceFile();

        var sbag: diag.Bag = .init(arena);
        const seed = (try pp_prelude.preludeAst(true)).?;
        var sp = try Parser.Parser.initSeeded(arena, text, tags, starts, &sbag, seed);
        // The seed is doing something: the resumed parse starts deep in the file.
        try testing.expect(sp.pos > 2000 and sp.pos < tags.len - 1);
        const seeded = try sp.parseSourceFile();

        // --- the interner: same strings, at the same ids, and the same map ---
        try testing.expectEqual(long.strings.strings.items.len, seeded.strings.strings.items.len);
        try testing.expectEqual(long.strings.map.size, seeded.strings.map.size);
        for (long.strings.strings.items, seeded.strings.strings.items, 0..) |x, y, i| {
            try testing.expectEqualStrings(x, y);
            // The id is the claim, not just the membership: everything below the
            // parser addresses a name by its `StrId`.
            const id = seeded.strings.find(y) orelse return error.NameNotInMap;
            try testing.expectEqual(i, @intFromEnum(id));
        }

        // --- the expression store: every column of every row, and the three
        // side tables the rows index ---
        try testing.expectEqual(long.exprs.nodes.len, seeded.exprs.nodes.len);
        for (0..long.exprs.nodes.len) |i| {
            try expectDeepEqual(
                @TypeOf(long.exprs.nodes.get(0)),
                long.exprs.nodes.get(i),
                seeded.exprs.nodes.get(i),
            );
        }
        try testing.expectEqualSlices(u32, long.exprs.pool.items, seeded.exprs.pool.items);
        try testing.expectEqualSlices(f64, long.exprs.reals.items, seeded.exprs.reals.items);
        try testing.expectEqualDeep(long.exprs.ints.items, seeded.exprs.ints.items);

        // --- statements ---
        try testing.expectEqualSlices(u32, long.stmt_toks.items, seeded.stmt_toks.items);
        try expectDeepEqual(@TypeOf(long.stmts.items), long.stmts.items, seeded.stmts.items);

        // --- all four declaration arrays, to their leaves ---
        try expectDeepEqual(@TypeOf(long.modules), long.modules, seeded.modules);
        try expectDeepEqual(@TypeOf(long.disciplines), long.disciplines, seeded.disciplines);
        try expectDeepEqual(@TypeOf(long.natures), long.natures, seeded.natures);
        try expectDeepEqual(@TypeOf(long.paramsets), long.paramsets, seeded.paramsets);

        // --- the parser state that is not in the SourceFile ---
        // A dropped access name turns a §4.4.1 branch probe into a §4.7 function
        // call silently, so the set is compared both ways.
        try testing.expectEqual(lp.access_names.size, sp.access_names.size);
        var it = lp.access_names.keyIterator();
        while (it.next()) |k| try testing.expect(sp.access_names.contains(k.*));
        try testing.expectEqual(lp.pos, sp.pos);
        try testing.expectEqual(lp.gen_construct, sp.gen_construct);
        try testing.expectEqual(lp.failed, sp.failed);
        try testing.expectEqual(@as(usize, 0), lbag.list.items.len + sbag.list.items.len);
    }
}

test "an ABSTOL override reaches annex D.1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = (try process(
        arena_state.allocator(),
        "`define CURRENT_ABSTOL 1e-15\n`include \"disciplines.vams\"\n",
        .{ .std_defs = false, .bag = &bag },
    )).text;
    try testing.expect(std.mem.indexOf(u8, text, "abstol      = 1e-15;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abstol      = 1e-12;") == null);
}

test "a span inside an `include resolves to the included file's own line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "module m;\n`include \"disciplines.vams\"\nendmodule\n";
    const out = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).text;

    // A byte that came from the included file.
    const needle = "discipline electrical;";
    const at: u32 = @intCast(std.mem.indexOf(u8, out, needle).?);
    const r = bag.map.resolve(at);
    try testing.expectEqualStrings("disciplines.vams", bag.fileName(r.file));
    try testing.expect(r.file != .root);

    // ... at ITS line number, not one measured in the preprocessed text.
    const want = std.mem.count(
        u8,
        pp_annex_d.disciplines_vams[0..std.mem.indexOf(u8, pp_annex_d.disciplines_vams, needle).?],
        "\n",
    ) + 1;
    const idx = try diag.LineIndex.build(arena, bag.fileText(r.file));
    try testing.expectEqual(@as(u32, @intCast(want)), idx.loc(r.offset).line);
    try testing.expectEqualStrings(
        needle,
        bag.fileText(r.file)[r.offset..][0..needle.len],
    );

    // ... while the top-level file still resolves to itself, at line 1.
    const top = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "module m;").?));
    try testing.expectEqual(diag.FileId.root, top.file);
    try testing.expectEqual(@as(u32, 0), top.offset);
    // ... and so does what follows the `include, despite the splice.
    const after = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "endmodule").?));
    try testing.expectEqual(diag.FileId.root, after.file);
    try testing.expectEqualStrings("endmodule\n", src[after.offset..]);
}

test "a diagnostic after a comment renders the ORIGINAL line at the ORIGINAL column" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    // The error token sits AFTER a block comment on its line. Its span indexes
    // the STRIPPED text (the comment is one space there, so the '`' is at
    // stripped column 3); before the strip map, rendering printed the stripped
    // line — a line that appears nowhere in the file — and measured the column
    // in it. The map puts the caret on the line the user wrote, at column 25.
    const src = "/* a leading comment */ `NOPE\n";
    try testing.expectError(
        error.PreprocessFailed,
        process(arena, src, .{ .std_defs = false, .bag = &bag }),
    );
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expectEqual(diag.Code.E0115, bag.at(0).code);

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    defer buf = aw.toArrayList();
    try diag.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    // The line drawn is the user's, comment included ...
    try testing.expect(std.mem.indexOf(u8, out, "| /* a leading comment */ `NOPE") != null);
    // ... the column is measured in it — the '`' is byte 24, column 25 ...
    try testing.expect(std.mem.indexOf(u8, out, ":1:25") != null);
    // ... and the caret row is indented to match: 24 spaces, then the span.
    try testing.expect(std.mem.indexOf(u8, out, "|                         ^^^^^") != null);
}

test "a span inside a macro expansion resolves to the invocation site" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "`define SQ(x) ((x)*(x))\ny = `SQ(v) + 1;\n";
    const out = (try process(arena, src, .{ .std_defs = false, .bag = &bag })).text;

    // Bytes that exist only in the expansion have no counterpart in the file;
    // the honest answer is the `SQ that produced them.
    const inside: u32 = @intCast(std.mem.indexOfScalar(u8, out, '*').?);
    const r = bag.map.resolve(inside);
    try testing.expectEqual(diag.FileId.root, r.file);
    try testing.expect(std.mem.startsWith(u8, src[r.offset..], "`SQ(v)"));
    try testing.expectEqualStrings("SQ", bag.map.segs[r.seg].macro);

    // ... and the text after the expansion is verbatim again.
    const after = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "+ 1").?));
    try testing.expectEqualStrings("+ 1;\n", src[after.offset..]);
}
