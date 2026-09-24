//! Lowering self-checks: source in, diagnostics or MIR out.
//!
//! Run on std.testing.allocator through an arena, so a leaked byte fails the test.
//!
//! LRM clauses this file's code cites: §2.7, §2.9, §2.9.2, §3.2, §3.2.2, §3.3, §3.4, §5.6.1.3, §5.6.7, §5.6.7.2, §5.8, §5.8.1.
//!
//! Cut verbatim from `lower.zig`. Functions take `self: *Lower` and are called
//! directly, `lower_test.f(self, ...)`; `lower.zig` aliases only what other modules call.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_param = @import("param.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const ground = Lower.ground;
const Access = Lower.Access;
const Kind = Lower.Kind;
const init = Lower.init;
const call = Lower.call;
const strToInt = Lower.strToInt;
const lowerFile = Lower.lowerFile;

// ---------------------------------------------------------------------------
// Self-checks run on std.testing.allocator
// through an arena, so a leaked byte fails the test.
// ---------------------------------------------------------------------------

pub const Parser = @import("frontend").Parser;

pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    bag: diag.Bag,
    low: Lower,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .bag = undefined,
            .low = undefined,
        };
        const arena = out.arena_state.allocator();
        out.bag = diag.Bag.init(arena);
        const text = (try Preprocessor.process(arena, src, .{ .bag = &out.bag })).text;
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        out.file.builtin_modules = Preprocessor.spice_module_count;
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
    }

    /// The code of the i'th diagnostic. Assertions key on the CODE, never on
    /// prose: the message no longer carries the LRM citation (`Info.lrm` does)
    /// and the title is not part of the message at all.
    fn code(self: *const Harness, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: *const Harness, i: usize) []const u8 {
        return self.bag.at(i).message;
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

test "lower: system math aliases preserve operand-sensitive result types" {
    const cases = [_]struct { expr: []const u8, op: Mir.Opcode, div: Mir.Opcode }{
        .{ .expr = "abs(a)", .op = .iabs, .div = .idiv },
        .{ .expr = "$abs(a)", .op = .iabs, .div = .idiv },
        .{ .expr = "min(a,b)", .op = .imin, .div = .idiv },
        .{ .expr = "$min(a,b)", .op = .imin, .div = .idiv },
        .{ .expr = "max(a,b)", .op = .imax, .div = .idiv },
        .{ .expr = "$max(a,b)", .op = .imax, .div = .idiv },
        .{ .expr = "abs(r)", .op = .fabs, .div = .fdiv },
        .{ .expr = "$abs(r)", .op = .fabs, .div = .fdiv },
        .{ .expr = "min(a,r)", .op = .fmin, .div = .fdiv },
        .{ .expr = "$min(a,r)", .op = .fmin, .div = .fdiv },
        .{ .expr = "$min(r,a)", .op = .fmin, .div = .fdiv },
        .{ .expr = "max(r,a)", .op = .fmax, .div = .fdiv },
        .{ .expr = "$max(r,a)", .op = .fmax, .div = .fdiv },
        .{ .expr = "$max(a,r)", .op = .fmax, .div = .fdiv },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p);
            \\inout p; electrical p;
            \\parameter integer a = 3, b = 5;
            \\parameter real r = 3.0;
            \\analog I(p) <+ {s}/2;
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        _ = try h.low.lowerFile();
        var math_count: usize = 0;
        var div_count: usize = 0;
        for (h.mir.insts.items(.op)) |op| {
            if (op == c.op) math_count += 1;
            if (op == c.div) div_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), math_count);
        try std.testing.expectEqual(@as(usize, 1), div_count);
    }
}

test "lower: system math aliases reject wrong arity" {
    for ([_][]const u8{ "$abs()", "$abs(1,2)", "$min(1)", "$min(1,2,3)", "$max(1)", "$max(1,2,3)" }) |expr| {
        const src = try std.fmt.allocPrint(
            std.testing.allocator,
            "module m(p); inout p; electrical p; analog I(p) <+ {s}; endmodule",
            .{expr},
        );
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var found = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0506) found = true;
        }
        try std.testing.expect(found);
    }
}

test "lower: §2.7 a string literal is a base-256 numeral, §3.3 justified right" {
    // §2.7's own sentence, at the natural width: most significant character
    // first, and a plain space is a character like any other.
    try std.testing.expectEqual(@as(i64, 10), strToInt("\n", 64));
    try std.testing.expectEqual(@as(i64, 32), strToInt(" ", 64));
    try std.testing.expectEqual(@as(i64, 16706), strToInt("AB", 64));
    // §3.3 into a 32-bit `integer` (§3.2): "hello" is 40 bits and loses its
    // leading 'h' on the LEFT, "A" is zero filled on the left, and Table 3-3's
    // `""` -> 8'b0 is the caller's (`strLitBytes`), so `{"H", ""}` is "H\x00".
    try std.testing.expectEqual(@as(i64, 1701604463), strToInt("hello", 32));
    try std.testing.expectEqual(@as(i64, 65), strToInt("A", 32));
    try std.testing.expectEqual(@as(i64, 18432), strToInt("H\x00", 32));
    try std.testing.expectEqual(@as(i64, 0), strToInt("", 32));
}

test "lower: §3.2 a multidimensional array is scalarized row-major" {
    // The ORDER is the load-bearing part: §3.3's own initializer
    // `string paths[0:2][0:1] = '{ '{"dir1","fileA"}, … }` is rows of columns,
    // so cell k of the flat walk must be `[k / cols][k % cols]`. Transposing it
    // reads one cell where another was written, and every value in that example
    // is plausible in both places — which is why the fixture checks all six.
    const dims = [_]lower_param.Bounds{ .{ .lo = 0, .hi = 2 }, .{ .lo = 0, .hi = 1 } };
    try std.testing.expectEqual(@as(usize, 6), lower_param.shapeCells(&dims));
    var idx: [2]i64 = undefined;
    const want = [_][2]i64{
        .{ 0, 0 }, .{ 0, 1 },
        .{ 1, 0 }, .{ 1, 1 },
        .{ 2, 0 }, .{ 2, 1 },
    };
    for (want, 0..) |w, k| {
        lower_param.shapeSubscripts(&dims, k, &idx);
        try std.testing.expectEqualSlices(i64, &w, &idx);
    }
    // A non-zero `lo` offsets the subscript and not the walk (§3.2.2 counts
    // elements): `[1:3]` puts the first cell at 1.
    const off = [_]lower_param.Bounds{.{ .lo = 1, .hi = 3 }};
    var one: [1]i64 = undefined;
    lower_param.shapeSubscripts(&off, 0, &one);
    try std.testing.expectEqual(@as(i64, 1), one[0]);
    lower_param.shapeSubscripts(&off, 2, &one);
    try std.testing.expectEqual(@as(i64, 3), one[0]);
}

test "lower: §2.9/§2.9.2 attribute values — constant, and in domain" {
    // Every row is one attr_spec in a slot Syntax 2-7 really has, so the only
    // thing under test is the VALUE. The accepting rows matter as much as the
    // refusing ones: §2.9 leaves an unlisted name's meaning to the tool, so a
    // domain check that fired on `tool_hint` would refuse conforming source.
    const cases = [_]struct { attr: []const u8, code: ?diag.Code }{
        // §2.9 `attr_spec ::= attr_name [ = constant_expression ]`.
        .{ .attr = "q = 1", .code = null },
        .{ .attr = "q", .code = null }, // "the default value is 1"
        .{ .attr = "q = gain", .code = null }, // A.8.4 a parameter IS constant
        .{ .attr = "q = z", .code = .E0357 }, // a variable is not
        .{ .attr = "q = 1 + z", .code = .E0357 },
        // §2.9.2's four names and nothing else.
        .{ .attr = "desc = \"a resistance\"", .code = null },
        .{ .attr = "desc = 7", .code = .E0358 },
        .{ .attr = "units = \"S\"", .code = null },
        .{ .attr = "units = 1.0", .code = .E0358 },
        .{ .attr = "op = \"yes\"", .code = null },
        .{ .attr = "op = \"no\"", .code = null },
        .{ .attr = "op = \"maybe\"", .code = .E0358 },
        .{ .attr = "op = 1", .code = .E0358 },
        .{ .attr = "multiplicity = \"multiply\"", .code = null },
        .{ .attr = "multiplicity = \"divide\"", .code = null },
        .{ .attr = "multiplicity = \"none\"", .code = null },
        .{ .attr = "multiplicity = \"sideways\"", .code = .E0358 },
        // Not a §2.9.2 name: no stated domain, so no check.
        .{ .attr = "tool_hint = \"anything\"", .code = null },
        .{ .attr = "full_case = 1", .code = null },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  real z;
            \\  (* {s} *) parameter real gain = 1.0;
            \\  analog begin
            \\    z = 2.0;
            \\    I(p, n) <+ gain * V(p, n);
            \\  end
            \\endmodule
        , .{c.attr});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var seen: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0357 or h.code(i) == .E0358) seen = h.code(i);
        }
        std.testing.expectEqual(c.code, seen) catch |e| {
            std.debug.print("attribute: (* {s} *)\n", .{c.attr});
            return e;
        };
    }
}

test "lower: contribution splits into resistive and reactive parts" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module rc(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf);
        \\  parameter real c = 1p;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 / r;
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ g * V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();

    // §6.5 ports first, in header order — this is the host's terminal order.
    try std.testing.expectEqual(@as(u16, 2), h.low.out.num_ports);
    try std.testing.expectEqualStrings("p", h.low.out.nodes.items(.name)[0]);
    try std.testing.expectEqualStrings("n", h.low.out.nodes.items(.name)[1]);

    // §3.4.2 the value range MUST survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.params.items.len);
    try std.testing.expectEqualStrings("r", h.low.out.params.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.params.items[0].ranges.len);
    try std.testing.expectEqual(Ast.ValueRange.Kind.from, h.low.out.params.items[0].ranges[0].kind);

    // §5.6.1.3 both `<+` statements accumulate into ONE target…
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    const c = h.low.out.contributions.items[0];
    try std.testing.expectEqual(Access.flow, c.access);
    try std.testing.expectEqual(@as(u16, 0), c.hi);
    try std.testing.expectEqual(@as(u16, 1), c.lo);
    // …and §5.6.1.2 splits them: the guarded g*V is resistive, ddt(c*V) is not.
    const resist = h.mir.resolveAlias(c.resist_val);
    const react = h.mir.resolveAlias(c.react_val);
    try std.testing.expect(resist != .f_zero); // a phi over the §5.8 guard
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(resist).inst_result));
    // The reactive part is `c * V(p,n)` — the charge, NOT its derivative.
    const react_inst = h.mir.valueDef(react).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fadd, h.mir.instOp(react_inst));
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(
        h.mir.valueDef(h.mir.instData(react_inst).binary.rhs).inst_result,
    ));
}

test "lower: §5.6.7 indirect contribution is a nullor entry, one per statement" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog begin
        \\    V(out) : V(pin, nin) == 2.0 * V(out);
        \\    V(out) : V(pin) == 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();

    // §5.6.7.1 several indirect contributions are legal, and each is its own
    // equation — NEVER accumulated the way §5.6.1.3 accumulates `<+`.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.contributions.items.len);
    for (h.low.out.contributions.items) |c| {
        try std.testing.expectEqual(Kind.indirect, c.kind);
        try std.testing.expectEqual(Access.potential, c.access);
        try std.testing.expectEqual(@as(u16, 0), c.hi); // out
        try std.testing.expectEqual(ground, c.lo);
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }
    // Row ORIENTATION: probe − equation, so the top-level op is `fsub` whose
    // LHS is the probe slice. Reversed, the residual is negated and an
    // asymmetric equation converges to the wrong point.
    const row = h.mir.resolveAlias(h.low.out.contributions.items[0].resist_val);
    const inst = h.mir.valueDef(row).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(inst));
    const lhs = h.mir.resolveAlias(h.mir.instData(inst).binary.lhs);
    // lhs is V(pin,nin) = x[pin] − x[nin]; rhs is the 2.0*V(out) product.
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(h.mir.valueDef(lhs).inst_result));
    const rhs = h.mir.resolveAlias(h.mir.instData(inst).binary.rhs);
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(h.mir.valueDef(rhs).inst_result));
}

test "lower: §5.6.7.2 an indirectly assigned branch refuses <+, in either order" {
    // The two orders are mirror images, and each has its own code.
    const cases = [_]struct { want: diag.Code, src: []const u8 }{
        .{ .want = .E0409, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    V(p, n) : V(p) == 0.0;
        \\    I(p, n) <+ 1e-6;
        \\  end
        \\endmodule
        },
        // …and the reverse order, on the reversed net pair (a "parallel
        // branch" in §5.6.7.2's words).
        .{ .want = .E0415, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(n, p) <+ 1e-6;
        \\    V(p, n) : V(p) == 0.0;
        \\  end
        \\endmodule
        },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
    }
}

test "lower: §5.6.7 indirect is banned under a runtime condition, allowed under a constant one" {
    var bad: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (V(i) > 0.0) V(o) : V(i) == 0.0;
        \\endmodule
    , &bad);
    defer bad.deinit();
    try std.testing.expectError(error.DiagnosticsReported, bad.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0412, bad.code(0));

    // "…unless the conditional expression is a constant expression": a folded
    // condition lowers its arm straight into the current block, so it never
    // raises `cond_depth`. (A §3.4 `parameter` is deliberately NOT foldable
    // here — one artifact serves every model card — and `foldExpr(..., false)` treats a
    // §3.4.5 `localparam` the same way, so this uses a literal.)
    var ok: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (1) V(o) : V(i) == 0.0;
        \\endmodule
    , &ok);
    defer ok.deinit();
    _ = try ok.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 1), ok.low.out.contributions.items.len);
    try std.testing.expectEqual(Kind.indirect, ok.low.out.contributions.items[0].kind);
}

test "lower: a ddt that is not a linear factor is a diagnostic, not wrong physics" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ sin(ddt(V(p,n)));
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0503, h.code(0));
}

test "lower: genvar loops unroll, procedural loops do not" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module chain(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar i;
        \\  analog begin
        \\    for (i = 0; i < 3; i = i + 1)
        \\      I(a,b) <+ i * V(a,b);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    // §6.6.1: three unrolled bodies accumulate into one target, and the loop
    // left no CFG behind (entry only).
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.mir.blockCount());
}

test "lower: §3.2.2 a runtime-indexed array is one storage, a constant-indexed one is scalars" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar g;
        \\  real h[0:7], c[0:1][0:2];
        \\  integer k, i;
        \\  analog begin
        \\    @(initial_step) k = 0;
        \\    for (g = 0; g < 2; g = g + 1) c[g][1] = V(a,b);
        \\    for (i = 0; i < 8; i = i + 1) h[i] = c[1][1] * i;
        \\    h[k] = 2.0 * h[k];
        \\    I(a,b) <+ h[3] + c[0][1];
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(!h.bag.failed());
    // `h` is read and written at `i` and `k`: one storage of 8. `c` is only
    // ever indexed by constants and a genvar, so it stays six places.
    try std.testing.expectEqual(@as(usize, 1), h.low.out.mem_arrays.items.len);
    try std.testing.expectEqualStrings("h", h.low.out.mem_arrays.items[0].name);
    try std.testing.expectEqual(@as(u32, 8), h.low.out.mem_arrays.items[0].len);
    var n = [_]u32{0} ** 3; // anew, load, store
    for (h.mir.insts.items(.op)) |op| switch (op) {
        .anew => n[0] += 1,
        .fload => n[1] += 1,
        .store => n[2] += 1,
        else => {}, // else: only the array ops are counted
    };
    // One declaration; `h[k]` and `h[3]` read; the loop body and `h[k] =` write.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2 }, &n);
    // Row-major, each dimension from its left bound, so `[1:0]` counts down.
    try std.testing.expectEqual(@as(i64, 3), lower_param.flatIndex(&.{ .{ .lo = 0, .hi = 1 }, .{ .lo = 0, .hi = 2 } }, &.{ 1, 0 }));
    try std.testing.expectEqual(@as(i64, 1), lower_param.flatIndex(&.{.{ .lo = 0, .hi = 1, .descending = true }}, &.{0}));
}

test "lower: §5.4.3 port access — what is rejected, and what the unknown is" {
    const cases = [_]struct { src: []const u8, want: diag.Code, msg: []const u8 = "" }{
        // "The expression V(<a>) is invalid for ports and nets, where V is a
        // potential access function."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(p) <+ V(<p>);
        \\endmodule
        , .want = .E0507, .msg = "potential access function" },
        // "The port access function shall not be used on the left side of a
        // contribution operator <+."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(<p>) <+ 1.0;
        \\endmodule
        , .want = .E0407 },
        // §4.4.2 "the expression list is a single port of the module": an
        // internal net has no outside, so I(<n>) would be an identical zero.
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  electrical n;
        \\  analog I(p, n) <+ I(<n>);
        \\endmodule
        , .want = .E0508, .msg = "I(<n>)" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
        if (c.msg.len != 0)
            try std.testing.expect(std.mem.indexOf(u8, h.msg(0), c.msg) != null);
    }
}

test "lower: §5.4.3 repeated I(<p>) is one unknown, appended after the ports" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, c);
        \\  inout a, c; electrical a, c;
        \\  analog I(a, c) <+ I(<a>) + I(<c>) + I(<a>);
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();

    try std.testing.expectEqual(@as(u16, 2), h.low.out.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.out.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u16, 0), h.low.out.port_probes.items[0].port);
    try std.testing.expectEqual(@as(u16, 1), h.low.out.port_probes.items[1].port);
    for (h.low.out.port_probes.items) |pp| {
        try std.testing.expect(pp.u >= h.low.out.num_ports);
        // The KIND tag, which is what codegen's `isFlowUnknown` now reads. This
        // used to assert the `"flow(<"` prefix, i.e. the spelling — and §2.8.1
        // makes that predicate false for a net someone declared `\flow(<p>)`.
        // The spelling still reaches the host as `flowZ28Z3cpZ3eZ29` and is
        // pinned there, in codegen.zig's "the `U` block is the SPELLING
        // contract" test; the two claims no longer ride on one string.
        try std.testing.expectEqual(pp.port, h.low.out.nodes.items(.kind)[pp.u].port_flow);
    }
    try std.testing.expectEqualStrings("flow(<a>)", h.low.nodeName(h.low.out.port_probes.items[0].u));
}

test "lower: §5.6.1.3 a kind mismatch REPLACES the retained value, and §5.4.2.2 reads it" {
    var h: Harness = undefined;
    // §5.6.1.3's own worked example, whose stated answer is 7.0 and whose whole
    // point is that 8.0 (every potential contribution accumulated, both
    // conversions ignored) is wrong.
    try Harness.run(std.testing.allocator,
        \\module vr(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    V(p,n) <+ 1.0;
        \\    I(p,n) <+ 2.0;
        \\    V(p,n) <+ 3.0;
        \\    V(p,n) <+ 4.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();

    // Two entries — the pair received both kinds — but only ONE survives with a
    // value. `emitResidual` skips a contribution whose value folds to `.f_zero`,
    // so the discarded flow source of 2.0 emits no row at all, which is what
    // "the flow being discarded" has to mean in the device.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.contributions.items.len);
    for (h.low.out.contributions.items) |c| {
        switch (c.access) {
            .flow => try std.testing.expectEqual(Mir.Value.f_zero, c.resist_val),
            .potential => try std.testing.expect(c.resist_val != .f_zero),
        }
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }

    // §5.4.2.2 the read side: a flow read AFTER a flow contribution is the
    // retained value, so it mints no `flow(p,n)` unknown; before one — or on a
    // POTENTIAL source, whose branch current codegen does pin — it still does.
    //
    // What this asserts is WHETHER an unknown exists, and it now reads that off
    // the KIND TAG — the node pair keyed in `flow_unknowns` — rather than off
    // the string. Its counterpart on the spelling, that the member still prints
    // `flowZ28pZ2cnZ29`, is codegen.zig's "the `U` block is the SPELLING
    // contract" test. Two claims, two tests, no shared string.
    const cases = [_]struct { src: []const u8, unknown: bool }{
        .{ .src = "I(p,n) <+ 1.0; x = I(p,n);", .unknown = false },
        .{ .src = "x = I(p,n); I(p,n) <+ 1.0;", .unknown = true },
        .{ .src = "V(p,n) <+ 1.0; x = I(p,n);", .unknown = true },
    };
    for (cases) |c| {
        var g: Harness = undefined;
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module fr(p, n);
            \\  inout p, n; electrical p, n;
            \\  real x;
            \\  analog begin {s} end
            \\endmodule
        , .{c.src});
        defer std.testing.allocator.free(src);
        try Harness.run(std.testing.allocator, src, &g);
        defer g.deinit();
        _ = try g.low.lowerFile();
        // `p` and `n` are `nodes` rows 0 and 1, so the branch is that pair.
        try std.testing.expectEqual(c.unknown, g.low.out.flow_unknowns.contains(.{ .hi = 0, .lo = 1 }));
    }
}

test "lower: scan destinations are guarded by the single assignment count" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module scan(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer fd, count, iv; real rv; string sv;
        \\  analog begin
        \\    iv = 73; rv = 2.5; sv = "kept";
        \\    count = $sscanf("12 nope", "%d %f", iv, rv, sv);
        \\    count = $fscanf(fd, "%d %f", iv, rv, sv);
        \\    I(p,n) <+ iv + rv + count;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    var string_counts: usize = 0;
    var file_counts: usize = 0;
    var guarded: usize = 0;
    var blocks = h.mir.blockIter();
    while (blocks.next()) |b| {
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) == .call) {
                const name = h.mir.instData(inst).call.name;
                if (std.mem.eql(u8, name, "$sscanf")) string_counts += 1;
                if (std.mem.eql(u8, name, "$fscanf")) file_counts += 1;
            }
            if (h.mir.instOp(inst) != .select) continue;
            const selection = h.mir.instData(inst).ternary;
            const condition = h.mir.resolveAlias(selection.cond);
            const comparison = h.mir.valueDef(condition).inst_result;
            try std.testing.expectEqual(Mir.Opcode.igt, h.mir.instOp(comparison));
            const lhs = h.mir.resolveAlias(h.mir.instData(comparison).binary.lhs);
            const count_inst = h.mir.valueDef(lhs).inst_result;
            try std.testing.expectEqual(Mir.Opcode.call, h.mir.instOp(count_inst));
            const name = h.mir.instData(count_inst).call.name;
            try std.testing.expect(std.mem.eql(u8, name, "$sscanf") or std.mem.eql(u8, name, "$fscanf"));
            guarded += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), string_counts);
    try std.testing.expectEqual(@as(usize, 1), file_counts);
    try std.testing.expectEqual(@as(usize, 6), guarded);
}

test "lower: §9.17.2 $bound_step accumulates through the CFG, not unconditionally" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $bound_step(1n);
        \\    if (V(p,n) > 0.0) $bound_step(1p);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // Exactly ONE synthetic call, and its argument is a phi: the guarded
    // `$bound_step(1p)` must NOT bound the step on the arm that never ran.
    var found: ?Mir.Value = null;
    var blocks = h.mir.blockIter();
    while (blocks.next()) |b| {
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) != .call) continue;
            if (!std.mem.eql(u8, h.mir.instData(inst).call.name, "$bound_step")) continue;
            try std.testing.expect(found == null);
            found = h.mir.instData(inst).call.args[0];
        }
    }
    const arg = h.mir.resolveAlias(found orelse return error.NoBoundStepCall);
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(arg).inst_result));
    // …and nothing was emitted for §9.17.1, which this module never calls.
    try std.testing.expect(h.low.disc_place == null);
}

test "lower: §9.17.1 $discontinuity separates iteration rejection from degree" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    try std.testing.expectEqual(Mir.Value.one, h.low.out.reject_iteration);
    // Iteration rejection must not become a timestep discontinuity.
    try std.testing.expect(h.low.disc_place == null);
    try std.testing.expect(h.low.bound_step_place == null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d2(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(2);
        \\    $discontinuity;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());
    try std.testing.expect(h2.low.disc_place != null);
}

test "lower: A.6.4 the analog_statement / analog_event_statement split" {
    // §5.10 "Contribution statements cannot be used inside an event control
    // block"; A.6.4 `analog_event_statement` has no contribution alternative.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(p, c);
        \\  inout p, c; electrical p, c;
        \\  analog @(cross(V(c), +1)) I(p) <+ V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0406, h.code(0));

    // `disable` is the mirror image: absent from `analog_statement`, present in
    // `analog_event_statement`. There is no §5.11 entry for it (5.11 is
    // jump_statement), so the diagnostic must not claim one.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p);
        \\  inout p; electrical p;
        \\  analog begin : work
        \\    if (V(p) > 1.0) disable work;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h2.bag.count());
    try std.testing.expectEqual(diag.Code.E0401, h2.code(0));
    // A.6.4, never §5.11 (which is jump_statement) — the citation is the code's.
    try std.testing.expectEqualStrings("A.6.4", diag.info(.E0401).lrm);
}

test "lower: §5.10.4 a named event resolves; anything else at `@`/`->` is E0705" {
    // The accepting side is three fixtures (annex_a/17, ch05/named_event_*,
    // annex_c/19), which pin the NUMBER end to end. What no fixture reaches is
    // the resolution failure, and it has to be a failure in both positions:
    // §2.8 gives an event a name and no value, so a real variable is not an
    // event even though `@(v)` would type-check as an integer guard.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ev(p);
        \\  inout p; electrical p; real v; event tick;
        \\  analog begin
        \\    @(initial_step) -> tick;
        \\    @(tick) v = 1.0;
        \\    @(v) v = 2.0;
        \\    I(p) <+ v;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0705, h.code(0));
    try std.testing.expectEqualStrings("`v`", h.msg(0));

    // The trigger goes through the same table, so a misspelling there lands on
    // the same code rather than silently triggering nothing.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ev2(p);
        \\  inout p; electrical p; event tick;
        \\  analog begin
        \\    @(initial_step) -> tock;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0705, h2.code(0));
    try std.testing.expectEqualStrings("`tock`", h2.msg(0));
}

test "lower: an unknown name carries a `did you mean` help" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  real vds;
        \\  analog I(p) <+ vdss * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0314, h.code(0));
    try std.testing.expectEqualStrings("`vdss`", h.msg(0));
    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = h.bag.notes(h.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("did you mean `vds`?", notes[0].text);
}

test "lower: §3.3 Table 3-3 string concatenation folds; the integer form never reaches here" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  string a = "hello", b = "world", c;
        \\  analog begin
        \\    c = {a, " ", b};
        \\    I(p) <+ 0.0 * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // The LRM's own example: `{ "hello", " ", "world" }` == `"hello world"`.
    var found = false;
    for (h.mir.strings.strings.items) |s| {
        if (std.mem.eql(u8, s, "hello world")) found = true;
    }
    try std.testing.expect(found);

    // A non-string operand has no width here (the parser folds the sized-
    // constant form), so it is rejected rather than silently coerced.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m; integer a, b; analog a = {b, b}; endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0327, h2.code(0));
    try std.testing.expect(std.mem.indexOf(u8, h2.msg(0), "only sized constants") != null);
}

test "lower: §5.8.1 an analog operator under a runtime condition (E0514)" {
    // What makes this rule worth a diagnostic: an analog operator is a state
    // machine the kernel steps once per accepted timestep. Under a branch the
    // solve can flip, the step its arm was off feeds it the type's zero, and its
    // history is wrong from then on — with a residual that still looks ordinary.
    //
    // Each case is the SAME operator under a different condition; only the
    // condition decides the verdict, which is exactly what §5.8.1 says.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        // Not an analysis_or_constant_expression: a probe moves every iteration.
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "V(c) > 0.5 && gain > 0.0", .warns = true },
        // A.8.2 analysis_function_call — §5.8.1 names it explicitly.
        .{ .cond = "analysis(\"dc\")", .warns = false },
        .{ .cond = "!analysis(\"tran\")", .warns = false },
        // constant_primary: a §3.4 parameter cannot move mid-analysis.
        .{ .cond = "gain > 0.0", .warns = false },
        .{ .cond = "analysis(\"dc\") || gain > 0.0", .warns = false },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  parameter real gain = 1.0;
            \\  real q;
            \\  analog begin
            \\    q = 0.0;
            \\    if ({s}) q = ddt(V(p, n));
            \\    I(p, n) <+ q;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0514) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: §5.9 a loop body has no carve-out, and §4.5.6/§4.5.13 have no history" {
    // §5.9's ban on analog filter functions in repeat/while/non-genvar `for` is
    // unconditional — there is no analysis_or_constant escape hatch — so a
    // constant loop bound does NOT license the operator.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0514, h.code(0));

    // ...but a genvar `for` (§5.9.3 analog_for) is unrolled onto the spine, so
    // every operator instance is stepped every time: no warning.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  genvar i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());

    // `ddx` (§4.5.6) and `limexp` (§4.5.13) read no previous timestep, so a
    // branch that was off cannot corrupt them. `vdmos.va` calls conditional
    // `limexp` three times; warning there would be noise, and noise is what
    // teaches a modeller to silence the code.
    var h3: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  real q;
        \\  analog begin
        \\    q = 0.0;
        \\    if (V(c) > 0.5) q = limexp(V(p, n)) + ddx(V(p, n), V(p));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h3);
    defer h3.deinit();
    _ = try h3.low.lowerFile();
    try std.testing.expect(h3.bag.isEmpty());
}

test "lower: §5.8/§5.10.3.1 an event control statement is stricter than E0514" {
    // §5.8: event control "cannot be used inside conditional statements unless
    // the conditional expression is a constant expression" — CONSTANT, not
    // analysis_or_constant. So the very condition that licenses `ddt` above
    // still rejects `@(cross(...))`, and the two rules must not share a counter.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "analysis(\"dc\")", .warns = true },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, c);
            \\  inout p, c;
            \\  electrical p, c;
            \\  real held;
            \\  analog begin
            \\    held = 0.0;
            \\    if ({s}) @(cross(V(c) - 1.0, 1)) held = V(p);
            \\    I(p) <+ held;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0707) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: A.6.1 an assign target is judged by declaration kind, then by domain" {
    // IEEE 1364-2005 §6.1 (via VAMS §1.1): a continuous assignment drives a
    // NET, so a variable is E0438. Among nets, §7.3's "write operations ... are
    // only allowed from the context of their domain" refuses a continuous one
    // (E0435) and admits a discrete one — `ddiscrete` (§3.6.2.2 `domain
    // discrete`) exactly as an undisciplined `wire`. Pinned here because the
    // positive fixture (ch07/ddiscrete_net_continuously_assigned) is xfail on the
    // digital runner, which would hide a return of the old E0438.
    const cases = [_]struct { decl: []const u8, code: ?diag.Code }{
        .{ .decl = "integer t;", .code = .E0438 },
        .{ .decl = "electrical t;", .code = .E0435 },
        .{ .decl = "ddiscrete t;", .code = null },
        .{ .decl = "wire t;", .code = null },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p);
            \\  inout p; electrical p;
            \\  {s}
            \\  assign t = 1'b1;
            \\  analog I(p) <+ V(p) + t;
            \\endmodule
        , .{c.decl});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var first: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0438 or h.code(i) == .E0435) first = first orelse h.code(i);
        }
        std.testing.expectEqual(c.code, first) catch |e| {
            std.debug.print("declaration: {s}\n", .{c.decl});
            return e;
        };
    }
}

test "lower: A.6.2 an initial block of constant assignments lowers; anything else is E0433" {
    // The accepting side is six fixtures (ch07/digital_initial_accepted,
    // discrete_bus_narrow, discrete_bus_31, discrete_real_from_analog,
    // annex_c/13, ch08/analog_digital_initial_order), which pin the VALUE end to
    // end. What no fixture reaches is E0433's own arms: the procedural_*
    // fixtures die in the parser first (`force`, `release` and a procedural
    // `assign` have no statement production), and a TIMED initial is no longer
    // E0433 at all — it makes the module mixed (`lower_context.isMixed`). So the
    // arms are stated here, one per reading a kernel would be needed for.
    const cases = [_]struct { stmt: []const u8, code: diag.Code }{
        // A non-constant right-hand side: `v` is a runtime variable, so there is
        // nothing to install and nothing computed it before the analysis.
        .{ .stmt = "q = v;", .code = .E0433 },
        // §5.10 event control: the block suspends, so it is a PROCESS and the
        // module is mixed; what it suspends on is an ANALOG event, which is
        // §7.3.6.1's A2D path the mixed-signal kernel does not have yet.
        .{ .stmt = "@(initial_step) q = 1;", .code = .E0437 },
        // §5.9.2 a loop, and §5.8 a conditional over a runtime value: both are
        // only worth writing over something that changes during the run.
        .{ .stmt = "for (q = 0; q < 3; q = q + 1) q = 1;", .code = .E0433 },
        // §3.2.2 an array element: which element is a question about a value.
        .{ .stmt = "arr[0] = 1;", .code = .E0433 },
        // §6.8 a name this module never declares. Nothing else lowers the block,
        // so if this scan does not report it, nobody does.
        .{ .stmt = "nope = 1;", .code = .E0313 },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p);
            \\  inout p; electrical p;
            \\  integer q; real v; integer arr[0:3];
            \\  initial begin {s} end
            \\  analog begin v = V(p); I(p) <+ v + q; end
            \\endmodule
        , .{c.stmt});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == c.code) seen = true;
        }
        std.testing.expect(seen) catch |e| {
            std.debug.print("initial statement: {s}\n", .{c.stmt});
            return e;
        };
    }

    // The accepting shape, at the seam that matters: the constant reaches the
    // variable's INITIAL VALUE, which is where an A.2.2.1 declaration assignment
    // lands, and a parameter counts as a constant (§3.4).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real k = 2.5;
        \\  integer q; real r;
        \\  initial begin q = 3; r = k; q = 4; end
        \\  analog I(p) <+ V(p) + q + r;
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    // Last assignment wins: the body is sequential.
    try std.testing.expectEqual(@as(usize, 2), h.low.initial_state.count());
}
