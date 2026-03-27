//! Parser self-checks: the real lexer drives the real parser.
//!
//! Source in, `Ast` and diagnostics out, asserted per Annex A production.
//!
//! LRM clauses this file's code cites: §1, §2.6.1, §2.7, §3.2.1, §3.3, §3.4.2, §4.2.2, §4.2.13, §4.2.14, §4.5.11, §6.6, §6.6.2.
//!
//! Cut verbatim from `parser.zig`.

const std = @import("std");
const parser = @import("../parser.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const diag = @import("diag");
const Parser = parser.Parser;

// ---------------------------------------------------------------------------
// Self-check. The REAL lexer drives the real parser, so the check exercises the
// grammar against the token stream the engine actually produces. A throwaway
// second lexer lived here and its own comment admitted it was weaker — no §2.6.1
// based numbers, no §2.7 strings, no §10.6 directives — so every test that
// needed one of those had to opt into a second entry point.
// ---------------------------------------------------------------------------

pub const TestResult = struct {
    file: Ast.SourceFile,
    bag: *diag.Bag,

    fn count(self: TestResult) usize {
        return self.bag.count();
    }

    fn code(self: TestResult, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: TestResult, i: usize) []const u8 {
        return self.bag.at(i).message;
    }
};

pub fn newBag(arena: std.mem.Allocator, src: []const u8) !*diag.Bag {
    const bag = try arena.create(diag.Bag);
    bag.* = diag.Bag.init(arena);
    try bag.setSingleFile("test.va", src, 0);
    return bag;
}

pub fn parseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    var list = try lexer.Lexer.tokenize(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

test "escaped identifier expressions share declaration normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = [_][]const u8{
        "a.b",                                                                                              "a..b", ".", "a/b", "a\\b", "a`b", "abc", "module",
        "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~",
    };
    for (names) |name| {
        const src = try std.fmt.allocPrint(
            arena,
            "module m; integer \\{s} ; initial begin \\{s} = 9; $display(\"%0d\", \\{s} ); end endmodule",
            .{ name, name, name },
        );
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
        const declared = res.file.modules[0].vars[0].name;
        var references: usize = 0;
        for (res.file.exprs.nodes.items(.tag), res.file.exprs.nodes.items(.str)) |tag, str| {
            if (tag == .ident) {
                try std.testing.expectEqual(declared, str);
                references += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), references);
    }
}

test "escaped nature access shares expression normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(
        arena,
        "nature n; access = \\a.b ; endnature module m(p); inout p; electrical p; analog \\a.b (p) <+ 0; endmodule",
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const body = res.file.stmt(res.file.modules[0].analog[0].body);
    const lhs = switch (body) {
        .contribute => |c| c.lhs,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(lhs));
}

test "escaped hierarchy head shares instance normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(
        arena,
        "module m; child \\a.b (); integer z; initial z = \\a.b .c; endmodule",
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const declared = res.file.modules[0].instances[0].name;
    var references: usize = 0;
    for (res.file.exprs.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .hier_ident) {
            const parts = res.file.exprs.nameParts(@enumFromInt(i));
            try std.testing.expectEqual(@as(usize, 2), parts.len);
            try std.testing.expectEqual(declared, parts[0]);
            references += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), references);
}

test "§10.6 begin_keywords picks which annex B words are reserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // LRM §10.6 worked example: `sin` is a port name under 1364-2005. Note the
    // module body still uses `analog` — a VAMS-only annex B keyword — because
    // §10.6 changes reserving, not tokens.
    const ok =
        \\`begin_keywords "1364-2005"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\  electrical sin, n;
        \\  analog I(sin,n) <+ V(sin,n) + sin;
        \\endmodule
        \\`end_keywords
    ;
    const a = try parseForTest(arena, ok);
    try std.testing.expectEqual(@as(usize, 0), a.count());
    try std.testing.expectEqualStrings("sin", a.file.str(a.file.modules[0].ports[0].name));

    // Same code, VAMS keywords: "shall result in an error".
    const bad =
        \\`begin_keywords "VAMS-2023"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\endmodule
        \\`end_keywords
    ;
    const b = try parseForTest(arena, bad);
    try std.testing.expect(b.count() > 0);
    try std.testing.expectEqual(diag.Code.E0208, b.code(0));
    try std.testing.expectEqualStrings("found `sin`", b.msg(0));

    // The set is restored by `end_keywords, so `sin` is reserved again after.
    const c = try parseForTest(arena,
        \\`begin_keywords "1364-1995"
        \\`end_keywords
        \\module m(sin);
        \\endmodule
    );
    try std.testing.expect(c.count() > 0);

    // §10.6: only these five specifiers exist.
    const d = try parseForTest(arena, "`begin_keywords \"1800-2017\"\n`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0135, d.code(0));
    try std.testing.expectEqualStrings("`1800-2017`", d.msg(0));

    // Unbalanced. An open `begin_keywords at end of file is NOT an error:
    // §10.6 scopes the directive "even across source code file boundaries",
    // so the set simply carries on into whatever is compiled next.
    const e = try parseForTest(arena, "`begin_keywords \"VAMS-2.3\"\nmodule m; endmodule\n");
    try std.testing.expectEqual(@as(usize, 0), e.count());
    // The other way round has no such reading.
    const f = try parseForTest(arena, "`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0136, f.code(0));

    // §10.6: "can only be specified outside of a design element".
    const g = try parseForTest(arena,
        \\module m;
        \\`begin_keywords "1364-2005"
        \\endmodule
        \\`end_keywords
    );
    try std.testing.expectEqual(diag.Code.E0202, g.code(0));
    try std.testing.expectEqualStrings("`begin_keywords inside a module", g.msg(0));
}

test "§2.6.1 based literals decode to the right VALUE, not just to a token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m;
        \\  integer a, b, c, d;
        \\  analog begin
        \\    a = 8'hFFFF;
        \\    b = 4'shf;
        \\    c = 'h837ff;
        \\    d = 16'b0011_0101;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const body = res.file.modules[0].analog[0].body;
    const stmts = switch (res.file.stmt(body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // These are the regression pins: the parser's old private decoder ignored
    // the size (65535) and skipped the `s` designator (15).
    const want = [_]i32{ 255, -1, 0x837ff, 0x35 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a2| a2.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }
}

test "§4.2.13 a sized-constant concatenation joins BITS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4'b1010, 4'b0101};
        \\    b = {1'b1, 3'b101};
        \\    c = {4'shf, 4'b0001};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 0xA5; §4.2.13's own example `{1'b1, 3'b101}` == 4'b1101; and a signed
    // operand contributes its BITS (4'shf is -1, i.e. 1111), not its value.
    const want = [_]i32{ 165, 0b1101, 0xf1 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // "Unsized constant numbers shall not be allowed in concatenations."
    const unsized = try parseForTest(arena, "module m; integer a; analog a = {1'b1, 3}; endmodule");
    try std.testing.expectEqual(diag.Code.E0216, unsized.code(0));
    // §3.2.1: 33 bits does not fit an integer, and must not wrap silently.
    const wide = try parseForTest(arena, "module m; integer a; analog a = {16'h0, 16'h0, 1'b1}; endmodule");
    try std.testing.expectEqual(diag.Code.E0217, wide.code(0));
    try std.testing.expectEqualStrings("at least 33 bits wide", wide.msg(0));
    // A brace list with no sized operand stays a `.concat` (§4.5.11 filter
    // coefficients spell their vector that way).
    const coeffs = try parseForTest(arena, "module m; real a; analog a = laplace_nd(1.0, {1,0}, {1,1}); endmodule");
    try std.testing.expectEqual(@as(usize, 0), coeffs.count());
}

test "§4.2.13 replication unrolls into the operand list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4{2'b10}};
        \\    b = {1'b0, {3{1'b1, 1'b0}}};
        \\    c = {{0{1'b1}}, 4'b0101};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 4.2.13's own three worked cases: "{4{w}} yields the same value as
    // {w, w, w, w}" (8 bits, 10101010); "{b, {3{a, b}}} yields the same value
    // as {b, a, b, a, b, a, b}" (7 bits, 0101010); and a zero replication
    // "considered to have a size of zero and ignored", leaving 4'b0101 alone.
    const want = [_]i32{ 170, 42, 5 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // §3.3 Table 3-3: "multiplier ... can be nonconstant" for a string result,
    // so a non-literal count is NOT a parse error — it keeps its node and
    // lowering repeats the string.
    const nonconst = try parseForTest(arena, "module m; integer i; string s; analog s = {i{\"Hi\"}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), nonconst.count());

    // A.8.1's assignment-pattern replication, §4.2.14's own `'{5{0.0}}`, is a
    // different brace and a different meaning: five ELEMENTS, not five copies
    // of a bit pattern.
    const pat = try parseForTest(arena, "module m; parameter real d[0:4] = '{5{0.0}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), pat.count());
    try std.testing.expectEqual(@as(usize, 5), pat.file.exprs.args(pat.file.modules[0].params[0].default).len);
}

test "a resistor parses into ports, ranged parameters and a contribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf) exclude 0;
        \\  real g;
        \\  analog begin : body
        \\    g = 1.0 / r;
        \\    if (V(p, n) > 0.0) g = g * 2;
        \\    I(p, n) <+ g * V(p, n) + ddt(V(p, n)) - $temperature;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.modules.len);

    const m = res.file.modules[0];
    try std.testing.expectEqualStrings("res", res.file.str(m.name));
    try std.testing.expectEqual(@as(usize, 2), m.ports.len);
    try std.testing.expectEqual(Ast.Direction.inout, m.ports[0].direction);
    // `electrical p, n;` binds the discipline to the port, not a second net.
    try std.testing.expectEqualStrings("electrical", res.file.str(m.ports[1].discipline));
    try std.testing.expectEqual(@as(usize, 0), m.nets.len);

    // §3.4.2 ranges must survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    const p0 = m.params[0];
    try std.testing.expectEqual(Ast.Type.real, p0.ty);
    try std.testing.expectEqual(@as(f64, 1000.0), res.file.exprs.realValue(p0.default));
    try std.testing.expectEqual(@as(usize, 2), p0.ranges.len);
    try std.testing.expect(!p0.ranges[0].lo_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, res.file.exprs.tag(p0.ranges[0].hi));
    try std.testing.expectEqual(Ast.ValueRange.Kind.exclude, p0.ranges[1].kind);

    try std.testing.expectEqual(@as(usize, 1), m.analog.len);
    const blk = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b,
        else => return error.WrongTag,
    };
    try std.testing.expectEqualStrings("body", res.file.str(blk.name));
    try std.testing.expectEqual(@as(usize, 3), blk.body.len);
    const contrib = switch (res.file.stmt(blk.body[2])) {
        .contribute => |c| c,
        else => return error.WrongTag,
    };
    // `I(p,n)` is a branch probe because `I` is a nature access name (§4.4.1).
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(contrib.lhs));
    // §4.2.2: `a*b + f(x) - $t` parses as `(a*b + f(x)) - $t`.
    try std.testing.expectEqual(Ast.BinaryOp.sub, res.file.exprs.binOp(contrib.rhs));
}

test "A.1.8 connectrules: both item forms land in their typed slots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every optional slot of connect_insertion in one block, plus both
    // resolution targets. The AST shape is asserted here because no fixture
    // can see it: mode/params/overrides have no consumer until an insertion
    // phase exists (Ast.ConnectInsertion says so), so the parse into the
    // right slot is the whole of what there is to pin.
    const src =
        \\connectrules cr;
        \\  connect a2d;
        \\  connect a2d split #(.tt(3.5), .vcc(3.3)) input elec, output dig;
        \\  connect d2a merged elec, dig;
        \\  connect e18, e33 resolveto exclude;
        \\  connect x, y, a resolveto a;
        \\endconnectrules
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.connectrules.len);
    const cr = res.file.connectrules[0];
    try std.testing.expectEqualStrings("cr", res.file.str(cr.name));

    try std.testing.expectEqual(@as(usize, 3), cr.insertions.len);
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.unspecified, cr.insertions[0].mode);
    try std.testing.expectEqual(@as(?Ast.ConnectInsertion.PortOverrides, null), cr.insertions[0].overrides);
    const full = cr.insertions[1];
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.split, full.mode);
    try std.testing.expectEqual(@as(usize, 2), full.params.len);
    try std.testing.expectEqualStrings("tt", res.file.str(full.params[0].name));
    try std.testing.expectEqual(Ast.Direction.input, full.overrides.?.a_dir);
    try std.testing.expectEqual(Ast.Direction.output, full.overrides.?.b_dir);
    try std.testing.expectEqualStrings("dig", res.file.str(full.overrides.?.b));
    // The undirected override shape keeps both directions unspecified.
    try std.testing.expectEqual(Ast.Direction.unspecified, cr.insertions[2].overrides.?.a_dir);

    try std.testing.expectEqual(@as(usize, 2), cr.resolutions.len);
    try std.testing.expect(cr.resolutions[0].exclude);
    try std.testing.expectEqual(Ast.StrId.none, cr.resolutions[0].resolved);
    try std.testing.expectEqual(@as(usize, 3), cr.resolutions[1].disciplines.len);
    try std.testing.expect(!cr.resolutions[1].exclude);
    try std.testing.expectEqualStrings("a", res.file.str(cr.resolutions[1].resolved));

    // A.1.8's connect_port_overrides admits exactly four direction pairings;
    // `input _, input _` is not one, and `expect` names what the grammar
    // wanted (E0207).
    const bad = try parseForTest(arena,
        \\connectrules crx;
        \\  connect a2d input elec, input dig;
        \\endconnectrules
    );
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
}

test "§3.7 wreal: a net type in a `.v` and a `.va` alike" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(a, b);
        \\  input wreal a;
        \\  output b;
        \\  wreal b;
        \\  wreal [3:0] bus;
        \\  wreal seeded = 2.5;
        \\endmodule
    ;

    // Annex C.4 bullet 2 / C.8 remove `wreal` from the Verilog-A SUBSET only;
    // VerA compiles Verilog-AMS, where §3.7/§6.5.3 make it a net and port type.
    const va = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), va.count());
    try std.testing.expectEqual(Ast.NetKind.wreal, va.file.modules[0].ports[0].kind);

    // Under `--run` the same text is A.2.1.2 `[ net_type | wreal ]` and
    // A.2.1.3's two `wreal` arms. Both reach `NetKind.wreal`, cleanly: the
    // digital engine runs a real-valued net.
    var list = try lexer.Lexer.tokenize(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    p.digital = true;
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    try std.testing.expect(!bag.failed());

    const m = file.modules[0];
    try std.testing.expectEqual(Ast.NetKind.wreal, m.ports[0].kind); // `input wreal a;`
    try std.testing.expectEqual(Ast.NetKind.wreal, m.ports[1].kind); // `output b;` + `wreal b;`
    // The body nets keep the range and the `net_decl_assignment` driver.
    try std.testing.expectEqual(@as(usize, 2), m.nets.len);
    try std.testing.expectEqual(Ast.NetKind.wreal, m.nets[0].kind);
    try std.testing.expect(m.nets[0].range != null);
    try std.testing.expect(m.nets[1].init != .none);
}

test "UDP single transition descriptor per sequential row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One pair is one edge, not two. All shorthand edge symbols are
    // independently legal with a level input; level-only rows remain legal.
    for ([_][]const u8{ "(01) 0", "0 (10)", "(0?) 1", "? (??)", "r 0", "R 0", "f 0", "F 0", "p 0", "P 0", "n 0", "N 0", "* 0", "0 1", "x 0" }) |inputs| {
        const src = try std.fmt.allocPrint(arena, "primitive u(q,a,b); output q; reg q; input a,b; table {s} : ? : 1; endtable endprimitive", .{inputs});
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
        try std.testing.expectEqual(@as(usize, 1), res.file.udps[0].rows.len);
    }
    // Pair/pair, pair/symbol in either order and symbol/symbol all exceed
    // the same source restriction, even when their transitions differ.
    for ([_][]const u8{ "(01) (10)", "(01) r", "f (10)", "r f", "P N", "* (??)", "(0?) *", "R F" }) |inputs| {
        const src = try std.fmt.allocPrint(arena, "primitive u(q,a,b); output q; reg q; input a,b; table {s} : ? : 1; endtable endprimitive", .{inputs});
        const res = try parseForTest(arena, src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0234, res.code(0));
        try std.testing.expectEqualStrings("a sequential UDP table entry permits at most one input transition descriptor", res.bag.at(0).message);
    }
}

test "A.5.1 a udp_declaration survives the parse, both header arms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both A.5.1 arms, and the sequential body's three moving parts: the
    // `udp_initial_statement`, an `edge_indicator` spelled across several
    // tokens, and a `next_state` of `-`. No fixture can see any of this —
    // there is no evaluator — so the parse into the right slot is the whole
    // of what there is to pin.
    const src =
        \\primitive comb (q, a, b);
        \\  output q; input a, b;
        \\  table
        \\    0 ? : 0;
        \\    ? 0 : 0;
        \\    1 1 : 1;
        \\  endtable
        \\endprimitive
        \\primitive dff (output reg q, input clk, input d);
        \\  initial q = 1'b0;
        \\  table
        \\    (01) 0 : ? : 0;
        \\    (01) 1 : ? : 1;
        \\    (0x) ? : ? : -;
        \\  endtable
        \\endprimitive
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 2), res.file.udps.len);

    const comb = res.file.udps[0];
    try std.testing.expectEqualStrings("comb", res.file.str(comb.name));
    // A.5.2 puts the output first, so ports[0] is `q` and the rest are inputs.
    try std.testing.expectEqual(@as(usize, 3), comb.ports.len);
    try std.testing.expectEqualStrings("q", res.file.str(comb.ports[0]));
    try std.testing.expectEqualStrings("b", res.file.str(comb.ports[2]));
    try std.testing.expect(!comb.is_sequential);
    try std.testing.expectEqual(Ast.ExprId.none, comb.init);
    try std.testing.expectEqual(@as(usize, 3), comb.rows.len);
    try std.testing.expectEqualStrings("0?", comb.rows[0].inputs);
    try std.testing.expectEqual(@as(u8, '0'), comb.rows[0].output);
    try std.testing.expectEqual(@as(u8, 0), comb.rows[0].state);

    const dff = res.file.udps[1];
    try std.testing.expectEqualStrings("dff", res.file.str(dff.name));
    try std.testing.expectEqualStrings("clk", res.file.str(dff.ports[1]));
    try std.testing.expect(dff.is_sequential);
    try std.testing.expect(dff.init != .none);
    // `(01) 0` is ONE edge field and one level field — six characters and
    // several tokens. The grouping is kept because splitting the list into one
    // field per input port is the evaluator's, and needs the port count.
    try std.testing.expectEqualStrings("(01)0", dff.rows[0].inputs);
    try std.testing.expectEqual(@as(u8, '?'), dff.rows[0].state);
    try std.testing.expectEqual(@as(u8, '1'), dff.rows[1].output);
    try std.testing.expectEqual(@as(u8, '-'), dff.rows[2].output);
}

test "A.2.5: `from` needs a bracket, and saying so is a diagnostic not an assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bare-expression range belongs to `exclude` alone. This used to be
    // `std.debug.assert(kind == .exclude)` — a panic on a checked build and
    // `unreachable` under ReleaseFast, reached from a source file.
    const bad = try parseForTest(arena, "module m; parameter real g = 1 from 5; endmodule");
    try std.testing.expectEqual(@as(usize, 1), bad.count());
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
    try std.testing.expectEqualStrings("expected `(` or `[` — only `exclude` takes a bare value", bad.bag.at(0).point);

    // The sibling that IS in the grammar still parses.
    const ok = try parseForTest(arena, "module m; parameter real g = 1 exclude 5; endmodule");
    try std.testing.expectEqual(@as(usize, 0), ok.count());
}

test "Table 4-3 precedence: ?: is the ONLY right-associative operator (§4.2.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ 1 + 2 * 3 ** 2 ** 3 > 4 ? V(p) : 2 ? 3 : 4;
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const e = &res.file.exprs;
    const rhs = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .contribute => |c| c.rhs,
        else => return error.WrongTag,
    };
    // `?:` is lowest and right-associative: cond ? V(p) : (2 ? 3 : 4)
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(rhs));
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(e.ternaryElse(rhs)));
    // §4.2.2: "All operators associate left to right with the exception of
    // the conditional operator which associates right to left." So the cond is
    // `(1 + (2 * ((3 ** 2) ** 3))) > 4` — `**` groups on the LEFT like every
    // other binary operator, and the nested pow hangs off `lhs`, not `rhs`.
    // Reading `**` as right-associative (the IEEE 1800 rule, not this one) made
    // `2**3**2` evaluate to 512 where §4.2.2 requires 64.
    const cond = e.lhs(rhs);
    try std.testing.expectEqual(Ast.BinaryOp.gt, e.binOp(cond));
    const add = e.lhs(cond);
    try std.testing.expectEqual(Ast.BinaryOp.add, e.binOp(add));
    const mul = e.rhs(add);
    try std.testing.expectEqual(Ast.BinaryOp.mul, e.binOp(mul));
    const pow = e.rhs(mul);
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(pow));
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(e.lhs(pow)));
    try std.testing.expectEqual(Ast.ExprTag.int_literal, e.tag(e.rhs(pow)));
}

test "A.6.2/A.6.5: discrete statement forms are grammar in a discrete body of any module, not in analog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `always`, `assign`, `#`, `wait`, `<=` and intra-assignment timing in an
    // ANALOG module's discrete processes: all module items / statements.
    const ok = try parseForTest(arena,
        \\module m(p);
        \\  inout p; electrical p;
        \\  reg clk, q; wire w;
        \\  assign w = q;
        \\  initial begin clk = 0; #4 clk = 1; wait (q) q = #1 0; end
        \\  always @(posedge clk) q <= 1;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), ok.count());
    const m = ok.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.assigns.len);
    try std.testing.expectEqual(@as(usize, 2), m.discrete.len);
    // The same forms in an ANALOG block are still not analog statements (A.6.4).
    const nba = try parseForTest(arena, "module m(p); inout p; electrical p; integer s; analog begin s <= 1; I(p) <+ V(p); end endmodule");
    try std.testing.expectEqual(diag.Code.E0214, nba.code(0));
    const delay = try parseForTest(arena, "module m(p); inout p; electrical p; analog begin #1 I(p) <+ V(p); end endmodule");
    try std.testing.expectEqual(diag.Code.E0209, delay.code(0));
}

test "errors are collected with locations and parsing continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module bad(p);
        \\  inout p;
        \\  electrical p;
        \\  child u(p);
        \\  driver_update w;
        \\  analog I(p) <+ V(p);
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    // `child u(p);` is a §6.2.2 module_instantiation and parses now; only
    // `driver_update` (a reserved word) is not a module item.
    try std.testing.expectEqual(@as(usize, 1), res.count());
    try std.testing.expectEqual(diag.Code.E0205, res.code(0));
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].instances.len);

    // The span still points at the offending token, on line 5.
    const idx = try diag.LineIndex.build(arena, src);
    try std.testing.expectEqual(@as(u32, 5), idx.loc(res.bag.at(0).span.start).line);
    // Recovery kept going: the analog block after the bad items still parsed.
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].analog.len);
}

test "annex C rejections keep their pinned wording" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, code: diag.Code, point: []const u8 = "" }{
        // §2.9 "Nesting of attribute instances is disallowed. It shall be illegal
        // to specify the value of an attribute with a constant expression that
        // contains an attribute instance." The outer instance sits in a slot
        // Syntax 2-7 has, and A.8.3 gives the `+` its own attribute slot, so the
        // inner one is refused by this rule and not by the grammar — delete it and
        // the same file parses.
        .{
            .src = "module m(p); inout p; electrical p; (* o = (1 + (* i *) 2) *) parameter real x = 1.0; analog I(p) <+ x; endmodule",
            .code = .E0357,
        },
        // A.1.3 module_parameter_port_list. The header `#(parameter real a = 1)`
        // USED to be this row, pinning that it was unimplemented; it parses now.
        // What A.1.3 still refuses is the SystemVerilog shorthand that drops the
        // `parameter` keyword after the first declaration — Verilog-AMS spells
        // the production `# ( parameter_declaration { , parameter_declaration } )`
        // with no such elision, so a bare type ends the list at the `(`.
        .{ .src = "module m #(real a = 1) (p); endmodule", .code = .E0207, .point = "expected `)`" },
        // A.2.4 net_decl_assignment used to have three rows here — vector nets,
        // the scalar nodeset spelling, and the clause's BUS form with its null
        // element. All three parse now; `electrical [0:4] p = '{2.3,4.5,,6.0}`
        // reaches lowering with a `.none` in the pattern where the hole was.
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(c.code, res.code(0));
        // E0207's title is only "unexpected token": what was wanted rides on
        // the caret, so that is what the fixtures pin.
        if (c.point.len != 0)
            try std.testing.expectEqualStrings(c.point, res.bag.at(0).point);
    }
}

test "§6.6 generate: what does not nest, what may not be declared, what may share a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; ";
    // `.code = null` = the parser must accept it. Those rows are the point of the
    // test: every rule here is a rule about POSITION, so the permitted position
    // has to be pinned beside the refused one or the gate is untestable.
    const cases = [_]struct { src: []const u8, code: ?diag.Code }{
        // §6.6 "Generate regions do not nest, and they may only occur directly
        // within a module" — both halves of the sentence, then the legal single
        // region.
        .{ .src = head ++ "generate generate if (1) ; endgenerate endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) begin generate if (1) ; endgenerate end endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6 a generate block "may not contain ... parameter declarations".
        // `localparam` in the same position is `module_or_generate_item`'s own
        // alternative, and a `parameter` back at module scope is untouched.
        .{ .src = head ++ "generate if (1) begin parameter real x = 1.0; end endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate parameter real x = 1.0; endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate if (1) begin localparam real x = 1.0; end endgenerate endmodule", .code = null },
        .{ .src = head ++ "parameter real x = 1.0; generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6.2 "Named generate blocks may not have the same name as any other
        // declaration in the same scope", and §6.6.1 the same for a loop
        // construct's instance array. The declaration may come after.
        .{ .src = head ++ "real g; generate if (1) begin end endgenerate endmodule", .code = null },
        .{ .src = head ++ "real g; generate if (1) begin : g end endgenerate endmodule", .code = .E0230 },
        .{ .src = head ++ "generate if (1) begin : g end endgenerate real g; endmodule", .code = .E0230 },
        .{ .src = head ++ "genvar i; real g; generate for (i=0;i<2;i=i+1) begin : g end endgenerate endmodule", .code = .E0230 },
        // §6.6.2 "... as blocks in any other generate construct in the same
        // scope, EVEN IF NOT SELECTED FOR INSTANTIATION" — hence `if (0)`.
        .{ .src = head ++ "generate if (1) begin : b end if (0) begin : b end endgenerate endmodule", .code = .E0230 },
        // ...against the permission in the preceding bullet: "more than one block
        // within a single conditional generate construct" may share a name, and
        // an `else if` chain is one construct by §6.6.2's direct nesting.
        .{ .src = head ++ "generate if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (1) begin : b end else if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        // Syntax 6-8 case_generate_construct: a label list, a `default`, and the
        // arms sharing one name (one construct). Outside a generate it is A.6.7's
        // statement keyword with no module-item production at all — E0205.
        .{ .src = head ++ "generate case (1) 1, 2: begin : b end default: begin : b end endcase endgenerate endmodule", .code = null },
        .{ .src = head ++ "case (1) 1: ; endcase endmodule", .code = .E0205 },
        // §6.6: a generate block brings its module instances (and defparams,
        // and discrete blocks) into existence only when the scheme selects or
        // repeats it. VerA has no generate scope for them: E0235, not a hoist —
        // except a module instance, which the block keeps for elaboration to
        // gate by the scheme (`Flatten.genInstances`).
        .{ .src = head ++ "generate if (0) begin r u(p); end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (0) begin defparam u.x = 1.0; end endgenerate endmodule", .code = .E0235 },
        .{ .src = head ++ "generate if (0) begin initial begin end end endgenerate endmodule", .code = .E0235 },
        .{ .src = head ++ "generate if (0) begin event e; end endgenerate endmodule", .code = .E0235 },
        // A generate REGION has no scheme; its items are ordinary module items.
        .{ .src = head ++ "generate r u(p); endgenerate endmodule", .code = null },
        // IEEE 1364 §19.6: `resetall is illegal within a module, legal between.
        .{ .src = "`resetall\n" ++ head ++ "`resetall\nendmodule", .code = .E0236 },
        .{ .src = "`resetall\n" ++ head ++ "endmodule\n`resetall\n", .code = null },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        if (c.code) |code| {
            try std.testing.expect(res.count() > 0);
            try std.testing.expectEqual(code, res.code(0));
        } else {
            try std.testing.expectEqual(@as(usize, 0), res.count());
        }
    }
}

test "4.7.1's bullet list and 4.7.2.2 are checked at the declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; analog function real f; ";
    const cases = [_]struct { body: []const u8, code: diag.Code }{
        // "shall have at least one formal argument declared"
        .{ .body = "f = 1.0; endfunction", .code = .E0224 },
        // "all formal arguments shall have an associated block item
        // declaration specifying the data type of the argument" — the
        // direction alone is not one.
        .{ .body = "input x; f = x; endfunction", .code = .E0225 },
        // "shall not use named blocks"
        .{ .body = "input x; real x; begin : b f = x; end endfunction", .code = .E0226 },
        // 4.7.2.2 "shall specify an expression"
        .{ .body = "input x; real x; begin return; end endfunction", .code = .E0227 },
    };
    for (cases) |c| {
        const src = try std.mem.concat(arena, u8, &.{ head, c.body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(c.code, res.code(0));
    }

    // And the legal spellings still are: the type on the direction, the type in
    // a separate block item declaration, an UNNAMED block, and a `return` with
    // an expression. None of these may report anything.
    for ([_][]const u8{
        "input real x; f = x; endfunction",
        "input x; real x; f = x; endfunction",
        "input x; real x; begin f = x; end endfunction",
        "input x; real x; begin return x; end endfunction",
    }) |body| {
        const src = try std.mem.concat(arena, u8, &.{ head, body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "casex/casez and reduction xor PARSE, so lowering owns the annex C rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both used to die here — casex on E0209 "expected an expression" and `^b`
    // on E0215 "expected an operand". Those are recovery artifacts: they name
    // no rule, they fire for any token that cannot start an expression, and
    // they made §4.2.10's E0320 unreachable. The grammar is now accepted and
    // the check happens where the meaning is known (casex/casez lower, §7.3.2).
    for ([_][]const u8{
        "module m; integer s; analog casex (s) 0: s = 1; endcase endmodule",
        "module m; integer s; analog casez (s) 0: s = 1; endcase endmodule",
        "module m; integer b, q; analog q = ^b; endmodule",
        "module m; integer b, q; analog q = ~^b; endmodule",
    }) |src| {
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.4 has no null statement outside a conditional, case or event body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // annex G.2.2: the three survivors stay legal, the free-standing `;` does
    // not. `analog ;` is the A.6.2 form of the same mistake.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; analog begin ; I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; analog ; endmodule",
    }) |bad| {
        const res = try parseForTest(arena, bad);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0219, res.code(0));
    }
    for ([_][]const u8{
        "module m(p); inout p; electrical p; integer c; analog begin if (c) ; else I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; integer c; analog begin case (c) 0: ; default: I(p) <+ 1.0; endcase end endmodule",
        "module m(p); inout p; electrical p; analog begin @(initial_step) ; I(p) <+ 1.0; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.5 gives a step event no empty analysis list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog begin @(final_step()) x = 0.0; I(p) <+ x; end endmodule");
    try std.testing.expect(bad.count() > 0);
    try std.testing.expectEqual(diag.Code.E0220, bad.code(0));

    // Both legal forms: the bare keyword, and a non-empty list.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; real x; analog begin @(final_step) x = 0.0; I(p) <+ x; end endmodule",
        "module m(p); inout p; electrical p; real x; analog begin @(final_step(\"tran\")) x = 0.0; I(p) <+ x; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "a missing terminator suggests inserting it after the PREVIOUS token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The caret lands on `end`, one line after the mistake. What makes the
    // message actionable is the fix: a zero-width insertion at the end of the
    // contribution, which is where a person has to type the `;`.
    const src =
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n)
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(diag.Code.E0207, res.code(0));

    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = res.bag.notes(res.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    const fix = notes[0].fix orelse return error.TestExpectedFix;
    try std.testing.expectEqualStrings(";", fix.replacement);
    // Zero width: an insertion, not a replacement.
    try std.testing.expectEqual(fix.span.start, fix.span.end);
    // ...and it is anchored just past `)`, not at the `end` the caret is under.
    try std.testing.expectEqualStrings("V(p, n)", src[fix.span.start - 7 .. fix.span.start]);

    // A terminator is the only shape that earns an insertion: E0208 wants a
    // NAME, and no fix can invent one. The port branch `branch (<p>) b` used to
    // be this example and parses now (§3.12.1); a NUMBER where the
    // list_of_branch_identifiers goes is the same production still wanting a name.
    const named = try parseForTest(arena, "module m(p); inout p; electrical p; branch (p) 7; endmodule");
    try std.testing.expectEqual(diag.Code.E0208, named.code(0));
    try std.testing.expectEqual(@as(u32, 0), named.bag.at(0).n_notes);
}

test "§2.7 a string may not span lines, however it is continued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The IEEE 1800 §5.9 continuation bsim4va's $strobe uses, and a plain
    // runaway. Both are E0138; only the first earns the SystemVerilog note.
    const cases = [_]struct { src: []const u8, notes: u32 }{
        .{ .src = "module m; analog $strobe(\"a\\\nb\"); endmodule", .notes = 2 },
        .{ .src = "module m; analog $strobe(\"a\nb\"); endmodule", .notes = 1 },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0138, res.code(0));
        try std.testing.expectEqualStrings(
            "this literal is still open at the end of the line",
            res.bag.at(0).point,
        );
        try std.testing.expectEqual(c.notes, res.bag.at(0).n_notes);
    }
}

test "analog functions, events, case and indirect contributions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\nature Voltage;
        \\  units = "V";
        \\  access = Pot;
        \\  abstol = 1e-6;
        \\endnature
        \\discipline el;
        \\  potential Voltage;
        \\  potential.abstol = 1e-9;
        \\  domain continuous;
        \\  max_voltage = 48.0;
        \\enddiscipline
        \\module m(p, n);
        \\  inout p, n;
        \\  el p, n;
        \\  branch (p, n) br;
        \\  real x[0:1];
        \\  integer k;
        \\  analog function real half;
        \\    input v;
        \\    real v;
        \\    half = v / 2.0;
        \\  endfunction
        \\  analog begin
        \\    @(initial_step("dc", "tran")) x[0] = 0.0;
        \\    @(cross(Pot(p, n), +1) or timer(1n, 1n)) x[1] = 1.0;
        \\    for (k = 0; k < 2; k = k + 1) x[0] = x[0] + half(Pot(br));
        \\    case (k)
        \\      0, 1: $strobe("k=%d", k);
        \\      default: ;
        \\    endcase
        \\    Pot(p, n) : Pot(p) == 2.0 * x[0];
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.natures.len);
    try std.testing.expectEqual(@as(usize, 1), res.file.disciplines.len);
    const d = res.file.disciplines[0];
    try std.testing.expectEqualStrings("Voltage", res.file.str(d.potential));
    try std.testing.expectEqual(Ast.DisciplineDecl.Domain.continuous, d.domain);
    try std.testing.expectEqual(@as(usize, 1), d.overrides.len);
    // §3.6.2.7 a discipline's user-defined attribute, kept like a nature's.
    try std.testing.expectEqual(@as(usize, 1), d.attrs.len);
    try std.testing.expectEqualStrings("max_voltage", res.file.str(d.attrs[0].name));

    const m = res.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.branches.len);
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
    // `input v; real v;` types the argument and does not leave a local.
    try std.testing.expectEqual(@as(usize, 1), m.functions[0].args.len);
    try std.testing.expectEqual(Ast.Type.real, m.functions[0].args[0].ty);
    try std.testing.expectEqual(@as(usize, 0), m.functions[0].vars.len);

    const body = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b.body,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(@as(usize, 5), body.len);
    const ev = switch (res.file.stmt(body[0])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    // §5.10.2: the argument list is analysis-name strings, not expressions.
    try std.testing.expectEqual(Ast.ExprTag.event_initial_step, res.file.exprs.tag(ev));
    try std.testing.expectEqual(@as(usize, 2), res.file.exprs.nameParts(ev).len);
    try std.testing.expectEqualStrings("dc", res.file.str(res.file.exprs.nameParts(ev)[0]));

    const ev2 = switch (res.file.stmt(body[1])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.event_or, res.file.exprs.tag(ev2));
    try std.testing.expectEqual(
        Ast.ExprTag.event_function,
        res.file.exprs.tag(res.file.exprs.lhs(ev2)),
    );
    // §5.6.7 indirect contribution survives parsing (lowering may reject it).
    switch (res.file.stmt(body[4])) {
        .indirect => |ind| try std.testing.expectEqual(
            Ast.ExprTag.branch_access,
            res.file.exprs.tag(ind.probe),
        ),
        else => return error.WrongTag,
    }
}

test "§2.6.1 AST preserves exact digital literals and known literal metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(arena,
        \\module literals;
        \\  integer a, b, c, d;
        \\  initial begin
        \\    a = 85'hz3;
        \\    b = 8'shf;
        \\    c = 128'd18446744073709551617;
        \\    d = 'hx;
        \\    d = {4'b10xz, 4'hf};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 4), res.file.exprs.logic.items.len);
    try std.testing.expectEqual(@as(u32, 85), res.file.exprs.logic.items[0].width);
    try std.testing.expectEqual(@as(u64, 3), res.file.exprs.logic.items[0].values()[0]);
    try std.testing.expectEqual(@as(u32, 128), res.file.exprs.logic.items[1].width);
    try std.testing.expect(!res.file.exprs.logic.items[2].sized);
    try std.testing.expectEqual(@as(u32, 8), res.file.exprs.ints.items[0].width);
    try std.testing.expect(res.file.exprs.ints.items[0].signed);
    var copy: Ast.SourceFile = .empty;
    try copy.seedFrom(arena, &res.file);
    try std.testing.expect(copy.exprs.logic.items[0].planes.ptr != res.file.exprs.logic.items[0].planes.ptr);
    try std.testing.expectEqualSlices(u64, res.file.exprs.logic.items[0].planes, copy.exprs.logic.items[0].planes);
}
