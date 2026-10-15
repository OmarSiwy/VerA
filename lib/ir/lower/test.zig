//! Lowering self-checks: source in, diagnostics or MIR out.
//!
//! Run on std.testing.allocator through an arena, so a leaked byte fails the test.
//!
//! LRM clauses this file's code cites: §1.1, §1.3.1, §1.3.1.2, §2.6.2, §2.7, §2.8,
//! §2.8.1, §2.9, §2.9.2, §3.2, §3.2.2, §3.3, §3.4, §3.4.2, §3.6, §3.6.1.2, §3.6.1.3,
//! §3.6.2.1, §3.6.2.2, §3.6.2.5, §3.6.3.2, §3.11, §3.13.1, §3.13.2, §4.2, §4.4, §4.4.2,
//! §4.5, §4.5.1, §4.5.2, §4.5.5, §4.5.6, §4.5.8, §4.5.9, §4.5.10, §4.5.11, §4.5.12,
//! §4.5.13, §4.6, §4.6.1, §4.6.4.1, §4.6.4.2, §4.6.4.3, §4.7, §4.7.2.3, §4.7.3, §5.3.2,
//! §5.4.2.2, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3, §5.6.7, §5.6.7.1, §5.6.7.2, §5.8, §5.8.1,
//! §5.9, §5.9.2, §5.9.3, §5.10, §5.10.3, §5.10.3.1, §5.10.3.2, §5.10.3.3, §5.10.3.4,
//! §5.10.4, §5.11, §6.3.1, §6.3.4, §6.3.6, §6.5, §6.6.1, §6.8, §7.3, §7.3.2.1, §9.2,
//! §9.4, §9.4.1, §9.4.3, §9.5.3, §9.5.4.2, §9.7, §9.7.2, §9.7.3, §9.13, §9.13.1, §9.15,
//! §9.17, §9.17.1, §9.17.2, §9.17.3, §9.19, §9.21, §9.21.1, §9.21.2, §9.22.
//! IEEE 1364-2005 clauses cited: §6.1.

const std = @import("std");
const Lower = @import("../lower.zig");
const lower_shape = @import("shape.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const ground = Lower.ground;
const Access = Lower.Access;
const Kind = Lower.Kind;
const strToInt = Lower.strToInt;

/// The frontend parser namespace the harness drives.
pub const Parser = @import("frontend").Parser;

/// The one lowering harness (`Lower.Harness`), shared with every `lower/*.zig` test.
const Harness = Lower.Harness;

test "§6.3.4 monitored-event parameters retain their dependencies, not unrelated reals" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real base = 0.1, unused = 7.0;
        \\  parameter delta = 2.0 * base;
        \\  localparam real tol = base / 100.0;
        \\  integer n;
        \\  initial n = 0;
        \\  always @(absdelta(V(p), delta, 1p, tol)) n = n + 1;
        \\  analog I(p) <+ 0.0;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 3), h.low.out.discrete_params.count());
    for ([_][]const u8{ "delta", "base", "tol" }) |name|
        try std.testing.expect(h.low.out.discrete_params.contains(name));
    try std.testing.expect(!h.low.out.discrete_params.contains("unused"));
}

test "§6.3.1 paramset defparams follow final parameter values and freeze the selected generate shape" {
    const source =
        \\module top(p);
        \\  inout p; electrical p;
        \\  parameter integer enabled = 1;
        \\  card #(.select(enabled)) u(p);
        \\endmodule
        \\paramset card wrapper;
        \\  parameter integer select = 1;
        \\  .enabled = select;
        \\endparamset
        \\module wrapper(p);
        \\  inout p; electrical p;
        \\  parameter integer enabled = 1;
        \\  if (enabled) begin bad child(p); end
        \\  analog I(p) <+ 0.0;
        \\endmodule
        \\module bad(p);
        \\  inout p; electrical p;
        \\  leaf child(p); defparam child.gain = 5.0;
        \\endmodule
        \\module leaf(p);
        \\  inout p; electrical p;
        \\  parameter real gain = 1.0;
        \\  analog I(p) <+ gain * V(p);
        \\endmodule
    ;
    for ([_]?f64{ null, 0, 1 }) |override| {
        var h: Harness = undefined;
        try h.init(std.testing.allocator, source);
        defer h.deinit();
        var overrides: [1]Lower.ParamOverride = undefined;
        if (override) |value| {
            overrides[0] = .{ .name = "enabled", .value = value };
            h.low.param_overrides = &overrides;
        }
        if (override != null and override.? == 0) {
            const out = try h.low.lowerFile();
            const index = h.low.param_index.get("u.enabled").?;
            try std.testing.expect(out.params.items[index].shape);
            try std.testing.expectEqual(@as(u32, 0), h.bag.err_count);
        } else {
            try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
            var found = false;
            for (0..h.bag.records.items.len) |i| if (h.bag.at(i).code == .E0926) {
                try std.testing.expect(std.mem.find(u8, h.bag.at(i).message, "`u`") != null);
                found = true;
            };
            try std.testing.expect(found);
        }
    }
}

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
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\inout p; electrical p;
            \\parameter integer a = 3, b = 5;
            \\parameter real r = 3.0;
            \\analog I(p) <+ {s}/2;
            \\endmodule
        , .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        _ = try h.low.lowerFile();
        const ops = h.mir.insts.items(.op);
        try std.testing.expectEqual(@as(usize, 1), std.mem.countScalar(Mir.Opcode, ops, c.op));
        try std.testing.expectEqual(@as(usize, 1), std.mem.countScalar(Mir.Opcode, ops, c.div));
    }
}

test "lower: system math aliases reject wrong arity" {
    for ([_][]const u8{ "$abs()", "$abs(1,2)", "$min(1)", "$min(1,2,3)", "$max(1)", "$max(1,2,3)" }) |expr| {
        const src = try std.testing.allocator.print(
            "module m(p); inout p; electrical p; analog I(p) <+ {s}; endmodule",
            .{expr},
        );
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var found = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0506) found = true;
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
        const src = try std.testing.allocator.print(
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
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var seen: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0357 or h.bag.at(i).code == .E0358) seen = h.bag.at(i).code;
        }
        std.testing.expectEqual(c.code, seen) catch |e| {
            std.debug.print("attribute: (* {s} *)\n", .{c.attr});
            return e;
        };
    }
}

test "lower: contribution splits into resistive and reactive parts" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
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
    );
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
    try h.init(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog begin
        \\    V(out) : V(pin, nin) == 2.0 * V(out);
        \\    V(out) : V(pin) == 0.0;
        \\  end
        \\endmodule
    );
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
        try h.init(std.testing.allocator, c.src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.bag.at(0).code);
    }
}

test "lower: §5.6.7 indirect is banned under a runtime condition, allowed under a constant one" {
    var bad: Harness = undefined;
    try bad.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (V(i) > 0.0) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer bad.deinit();
    try std.testing.expectError(error.DiagnosticsReported, bad.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0412, bad.bag.at(0).code);

    // "…unless the conditional expression is a constant expression": a folded
    // condition lowers its arm straight into the current block, so it never
    // raises `cond_depth`. A parameter condition folds too, as a shape
    // parameter (`lowerIf`); the second harness below.
    var ok: Harness = undefined;
    try ok.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (1) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer ok.deinit();
    _ = try ok.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 1), ok.low.out.contributions.items.len);
    try std.testing.expectEqual(Kind.indirect, ok.low.out.contributions.items[0].kind);

    var par: Harness = undefined;
    try par.init(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  parameter integer sel = 1;
        \\  analog if (sel) V(o) : V(i) == 0.0;
        \\endmodule
    );
    defer par.deinit();
    _ = try par.low.lowerFile();
    try std.testing.expectEqual(Kind.indirect, par.low.out.contributions.items[0].kind);
    try std.testing.expect(par.low.out.params.items[0].shape);
}

test "lower: a ddt that is not a linear factor is its own unknown, row and charge site (§4.5.2)" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module nonlinear(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ sin(ddt(V(p,n)));
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 3), h.low.out.nodes.len);
    try std.testing.expect(h.low.out.nodes.items(.kind)[2] == .op_state);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.charge_sites.items.len);
    try std.testing.expectEqual(@as(f64, -1.0), h.low.out.charge_sites.items[0].sign);
}

test "lower: genvar loops unroll, procedural loops do not" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module chain(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar i;
        \\  analog begin
        \\    for (i = 0; i < 3; i = i + 1)
        \\      I(a,b) <+ i * V(a,b);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // §6.6.1: three unrolled bodies accumulate into one target, and the loop
    // left no CFG behind (entry only).
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.mir.blockCount());
}

test "lower: §3.2.2 a runtime-indexed array is one storage, a constant-indexed one is scalars" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
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
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(!h.bag.failed());
    // `h` is read and written at `i` and `k`: one storage of 8. `c` is only
    // ever indexed by constants and a genvar, so it stays six places.
    try std.testing.expectEqual(@as(usize, 1), h.low.out.mem_arrays.items.len);
    try std.testing.expectEqualStrings("h", h.low.out.mem_arrays.items[0].name);
    try std.testing.expectEqual(@as(u32, 8), h.low.out.mem_arrays.items[0].len);
    var n: [3]u32 = @splat(0); // anew, load, store
    for (h.mir.insts.items(.op)) |op| switch (op) {
        .anew => n[0] += 1,
        .fload => n[1] += 1,
        .store => n[2] += 1,
        else => {}, // else: only the array ops are counted
    };
    // One declaration; `h[k]` and `h[3]` read; the loop body and `h[k] =` write.
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2 }, &n);
    // Row-major, each dimension from its left bound, so `[1:0]` counts down.
    try std.testing.expectEqual(@as(i64, 3), lower_shape.flatIndex(&.{ .{ .lo = 0, .hi = 1 }, .{ .lo = 0, .hi = 2 } }, &.{ 1, 0 }));
    try std.testing.expectEqual(@as(i64, 1), lower_shape.flatIndex(&.{.{ .lo = 0, .hi = 1, .descending = true }}, &.{0}));
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
        try h.init(std.testing.allocator, c.src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.bag.at(0).code);
        if (c.msg.len != 0)
            try std.testing.expect(std.mem.find(u8, h.bag.at(0).message, c.msg) != null);
    }
}

test "lower: §5.4.3 repeated I(<p>) is one unknown, appended after the ports" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(a, c);
        \\  inout a, c; electrical a, c;
        \\  analog I(a, c) <+ I(<a>) + I(<c>) + I(<a>);
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();

    try std.testing.expectEqual(@as(u16, 2), h.low.out.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.out.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u16, 0), h.low.out.port_probes.items[0].port);
    try std.testing.expectEqual(@as(u16, 1), h.low.out.port_probes.items[1].port);
    for (h.low.out.port_probes.items) |pp| {
        try std.testing.expect(pp.u >= h.low.out.num_ports);
        // The kind tag, which codegen's `isFlowUnknown` reads. Not the
        // `"flow(<"` spelling: §2.8.1 lets a net be declared `\flow(<p>)`.
        // The spelling the host sees is pinned by codegen.zig's "the `U` block
        // is the SPELLING contract" test.
        try std.testing.expectEqual(pp.port, h.low.out.nodes.items(.kind)[pp.u].port_flow);
    }
    try std.testing.expectEqualStrings("flow(<a>)", @import("node.zig").nodeName(&h.low, h.low.out.port_probes.items[0].u));
}

test "lower: §5.6.1.3 a kind mismatch REPLACES the retained value, and §5.4.2.2 reads it" {
    var h: Harness = undefined;
    // §5.6.1.3's own worked example, whose stated answer is 7.0 and whose whole
    // point is that 8.0 (every potential contribution accumulated, both
    // conversions ignored) is wrong.
    try h.init(std.testing.allocator,
        \\module vr(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    V(p,n) <+ 1.0;
        \\    I(p,n) <+ 2.0;
        \\    V(p,n) <+ 3.0;
        \\    V(p,n) <+ 4.0;
        \\  end
        \\endmodule
    );
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
    // This asserts whether an unknown exists, read off the kind tag (the node
    // pair keyed in `flow_unknowns`). The spelling is pinned by codegen.zig's
    // "the `U` block is the SPELLING contract" test.
    const cases = [_]struct { src: []const u8, unknown: bool }{
        .{ .src = "I(p,n) <+ 1.0; x = I(p,n);", .unknown = false },
        .{ .src = "x = I(p,n); I(p,n) <+ 1.0;", .unknown = true },
        .{ .src = "V(p,n) <+ 1.0; x = I(p,n);", .unknown = true },
    };
    for (cases) |c| {
        var g: Harness = undefined;
        const src = try std.testing.allocator.print(
            \\module fr(p, n);
            \\  inout p, n; electrical p, n;
            \\  real x;
            \\  analog begin {s} end
            \\endmodule
        , .{c.src});
        defer std.testing.allocator.free(src);
        try g.init(std.testing.allocator, src);
        defer g.deinit();
        _ = try g.low.lowerFile();
        // `p` and `n` are `nodes` rows 0 and 1, so the branch is that pair.
        try std.testing.expectEqual(c.unknown, g.low.out.flow_unknowns.contains(.{ .hi = 0, .lo = 1 }));
    }
}

test "lower: scan destinations are guarded by the single assignment count" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
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
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    var string_counts: usize = 0;
    var file_counts: usize = 0;
    var guarded: usize = 0;
    for (0..h.mir.blockCount()) |bi| {
        const b: Mir.Block = @fromBackingInt(@intCast(bi));
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
    try h.init(std.testing.allocator,
        \\module bs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $bound_step(1n);
        \\    if (V(p,n) > 0.0) $bound_step(1p);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // Exactly ONE synthetic call, and its argument is a phi: the guarded
    // `$bound_step(1p)` must NOT bound the step on the arm that never ran.
    var found: ?Mir.Value = null;
    for (0..h.mir.blockCount()) |bi| {
        const b: Mir.Block = @fromBackingInt(@intCast(bi));
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
    try std.testing.expect(h.low.systask_state.disc_place == null);
}

test "lower: §9.17.1 $discontinuity separates iteration rejection from degree" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    try std.testing.expectEqual(Mir.Value.one, h.low.out.reject_iteration);
    // Iteration rejection must not become a timestep discontinuity.
    try std.testing.expect(h.low.systask_state.disc_place == null);
    try std.testing.expect(h.low.systask_state.bound_step_place == null);

    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module d2(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(2);
        \\    $discontinuity;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());
    try std.testing.expect(h2.low.systask_state.disc_place != null);
}

test "lower: A.6.4 the analog_statement / analog_event_statement split" {
    // §5.10 "Contribution statements cannot be used inside an event control
    // block"; A.6.4 `analog_event_statement` has no contribution alternative.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module e(p, c);
        \\  inout p, c; electrical p, c;
        \\  analog @(cross(V(c), +1)) I(p) <+ V(p);
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0406, h.bag.at(0).code);

    // `disable` is the mirror image: absent from `analog_statement`, present in
    // `analog_event_statement`. There is no §5.11 entry for it (5.11 is
    // jump_statement), so the diagnostic must not claim one.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module d(p);
        \\  inout p; electrical p;
        \\  analog begin : work
        \\    if (V(p) > 1.0) disable work;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h2.bag.count());
    try std.testing.expectEqual(diag.Code.E0401, h2.bag.at(0).code);
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
    try h.init(std.testing.allocator,
        \\module ev(p);
        \\  inout p; electrical p; real v; event tick;
        \\  analog begin
        \\    @(initial_step) -> tick;
        \\    @(tick) v = 1.0;
        \\    @(v) v = 2.0;
        \\    I(p) <+ v;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0705, h.bag.at(0).code);
    try std.testing.expectEqualStrings("`v`", h.bag.at(0).message);

    // The trigger goes through the same table, so a misspelling there lands on
    // the same code rather than silently triggering nothing.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module ev2(p);
        \\  inout p; electrical p; event tick;
        \\  analog begin
        \\    @(initial_step) -> tock;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0705, h2.bag.at(0).code);
    try std.testing.expectEqualStrings("`tock`", h2.bag.at(0).message);
}

test "lower: §5.10.3.4 absdelta bounds do not freeze card defaults" {
    // A host can replace every default below with valid values. Unlike a
    // literal negative bound, these analog_expression operands cannot be
    // refused from their declarations alone. This is the compile-time half;
    // event_bounds_mixed_legal.va runs legal runtime operands through the
    // emitted mixed-signal host.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module ad(p);
        \\  inout p; electrical p;
        \\  parameter real delta = -1.0, ttol = -1.0, etol = -1.0, en = 0.5;
        \\  real sampled;
        \\  always @(absdelta(V(p), delta, ttol, etol, en)) sampled = V(p);
        \\  analog I(p) <+ 0.0;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expect(!h.bag.failed());
}

test "lower: an unknown name carries a `did you mean` help" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  real vds;
        \\  analog I(p) <+ vdss * V(p);
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0314, h.bag.at(0).code);
    try std.testing.expectEqualStrings("`vdss`", h.bag.at(0).message);
    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = h.bag.notes(h.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("did you mean `vds`?", notes[0].text);
}

test "lower: §3.3 Table 3-3 string concatenation folds; the integer form never reaches here" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  string a = "hello", b = "world", c;
        \\  analog begin
        \\    c = {a, " ", b};
        \\    I(p) <+ 0.0 * V(p);
        \\  end
        \\endmodule
    );
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
    try h2.init(std.testing.allocator,
        \\module m; integer a, b; analog a = {b, b}; endmodule
    );
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0327, h2.bag.at(0).code);
    try std.testing.expect(std.mem.find(u8, h2.bag.at(0).message, "only sized constants") != null);
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
        const src = try std.testing.allocator.print(
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
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0514) seen = true;
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
    try h.init(std.testing.allocator,
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
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0514, h.bag.at(0).code);

    // ...but a genvar `for` (§5.9.3 analog_for) is unrolled onto the spine, so
    // every operator instance is stepped every time: no warning.
    var h2: Harness = undefined;
    try h2.init(std.testing.allocator,
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
    );
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());

    // `ddx` (§4.5.6) and `limexp` (§4.5.13) read no previous timestep, so a
    // branch that was off cannot corrupt them. `vdmos.va` calls conditional
    // `limexp` three times; warning there would be noise, and noise is what
    // teaches a modeller to silence the code.
    var h3: Harness = undefined;
    try h3.init(std.testing.allocator,
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
    );
    defer h3.deinit();
    _ = try h3.low.lowerFile();
    try std.testing.expect(h3.bag.isEmpty());
}

test "lower: §3.2 a variable some path reads before writing is held, and only that" {
    // §5.6.1.3 "Unlike variables, the contributed value for a branch is only
    // valid for the current iteration": a variable keeps its value, which a
    // read is able to see only where no write of this evaluation precedes it.
    const W = Lower.HeldVar.Why;
    const cases = [_]struct { body: []const u8, held: usize, why: W = .unless_invariant }{
        .{ .body = "x = 2.0; I(p) <+ x;", .held = 0 },
        .{ .body = "if (V(p) > 0) x = 1.0; else x = 2.0; I(p) <+ x;", .held = 0 },
        .{ .body = "if (V(p) > 0) x = 1.0; I(p) <+ x;", .held = 1 }, // the else path
        .{ .body = "x = x + 1.0; I(p) <+ x;", .held = 1, .why = .retained }, // the read reaches the write
        .{ .body = "I(p) <+ x; x = V(p);", .held = 1, .why = .retained },
        .{ .body = "if (V(p) > 0) I(p) <+ x; else x = 1.0;", .held = 1 }, // the arms exclude each other
        .{ .body = "for (k = 0; k < 2; k = k + 1) begin $strobe(\"%g\", x); x = 1.0; end", .held = 1, .why = .retained }, // the next iteration
        .{ .body = "a[0] = 1.0; a[1] = 2.0; I(p) <+ a[0] + a[1];", .held = 0 },
        .{ .body = "a[0] = 1.0; I(p) <+ a[1];", .held = 2 }, // every element of the array
        .{ .body = "I(p) <+ x;", .held = 0 }, // never written: nothing to retain
        .{ .body = "@(cross(V(p), 1)) x = 1.0; I(p) <+ x;", .held = 1, .why = .event },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p;
            \\  electrical p;
            \\  real x, y, a[0:1];
            \\  integer k;
            \\  analog begin
            \\    {s}
            \\  end
            \\endmodule
        , .{c.body});
        defer std.testing.allocator.free(src);
        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const out = try h.low.lowerFile();
        errdefer std.debug.print("body: {s}\n", .{c.body});
        try std.testing.expectEqual(c.held, out.held_vars.items.len);
        for (out.held_vars.items) |v| try std.testing.expectEqual(c.why, v.why);
    }
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
        const src = try std.testing.allocator.print(
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
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0707) seen = true;
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
    // digital runner and would not catch a wrong E0438.
    const cases = [_]struct { decl: []const u8, code: ?diag.Code }{
        .{ .decl = "integer t;", .code = .E0438 },
        .{ .decl = "electrical t;", .code = .E0435 },
        .{ .decl = "ddiscrete t;", .code = null },
        .{ .decl = "wire t;", .code = null },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p; electrical p;
            \\  {s}
            \\  assign t = 1'b1;
            \\  analog I(p) <+ V(p) + t;
            \\endmodule
        , .{c.decl});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }
        var first: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0438 or h.bag.at(i).code == .E0435) first = first orelse h.bag.at(i).code;
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
    // `assign` have no statement production), and a timed initial is not
    // E0433: it makes the module mixed (`lower_context.isMixed`). So the arms
    // are stated here, one per reading a kernel would be needed for.
    const cases = [_]struct { stmt: []const u8, code: diag.Code }{
        // A non-constant right-hand side: `v` is a runtime variable, so there is
        // nothing to install and nothing computed it before the analysis.
        .{ .stmt = "q = v;", .code = .E0433 },
        // §5.10 event control: the block suspends, so it is a PROCESS and the
        // module is mixed; what it suspends on is `initial_step`, which §5.10
        // does not allow "in the digital context".
        .{ .stmt = "@(initial_step) q = 1;", .code = .E0708 },
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
        const src = try std.testing.allocator.print(
            \\module m(p);
            \\  inout p; electrical p;
            \\  integer q; real v; integer arr[0:3];
            \\  initial begin {s} end
            \\  analog begin v = V(p); I(p) <+ v + q; end
            \\endmodule
        , .{c.stmt});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == c.code) seen = true;
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
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real k = 2.5;
        \\  integer q; real r;
        \\  initial begin q = 3; r = k; q = 4; end
        \\  analog I(p) <+ V(p) + q + r;
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    // Last assignment wins: the body is sequential.
    try std.testing.expectEqual(@as(usize, 2), h.low.initial_state.count());
}

test "lower: a 60000-statement dependency chain lowers without exhausting the stack" {
    // tests/fixtures/ADVERSARIAL.tsv: `scanFinite` recursed along the whole
    // chain and overflowed the native stack at 2e4 chained statements.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p);\ninout p; electrical p;\nreal x;\nanalog begin\nx = 0.0;\n");
    for (0..60000) |_| try src.appendSlice(gpa, "x = x + 1.0;\n");
    try src.appendSlice(gpa, "I(p) <+ x;\nend\nendmodule\n");
    var h: Harness = undefined;
    try h.init(gpa, src.items);
    defer h.deinit();
    _ = try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
}

test "§6.6.1 a genvar loop of exactly the unroll limit is legal; a longer one is E0485; an endless one is E0420" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { cond: []const u8, step: []const u8, code: ?diag.Code }{
        .{ .cond = "i < 4096", .step = "i = i + 1", .code = null }, // ends exactly at the cap
        .{ .cond = "i < 5000", .step = "i = i + 1", .code = .E0485 }, // ends, past the cap
        .{ .cond = "i < 3", .step = "i = i - 1", .code = .E0420 }, // runs away
        .{ .cond = "i < 9000", .step = "i = (i + 1) % 8", .code = .E0420 }, // repeats a value
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\genvar i;
            \\generate for (i = 0; {s}; {s}) begin end endgenerate
            \\analog I(p) <+ 0.0;
            \\endmodule
        , .{ c.cond, c.step });
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        if (c.code) |want| {
            try std.testing.expect(h.bag.count() >= 1);
            try std.testing.expectEqual(want, h.bag.at(0).code);
        } else try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    }
}

test "A.8.2 an omitted system-function argument with no meaning is a named error, never a crash" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { call: []const u8, bad: bool }{
        .{ .call = "$limit(V(p), \"pnjlim\", 0.025, 0.6)", .bad = false },
        .{ .call = "$limit(V(p), , 0.025, 0.6)", .bad = true },
        .{ .call = "$table_model(V(p), , \"1LL\")", .bad = true },
        .{ .call = "$hypot(V(p), )", .bad = true },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\analog I(p) <+ {s};
            \\endmodule
        , .{c.call});
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        var errors: usize = 0;
        var e0894 = false;
        for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) {
            errors += 1;
            e0894 = e0894 or h.bag.at(i).code == .E0894;
        };
        if (errors != @intFromBool(c.bad) or e0894 != c.bad) {
            for (0..h.bag.count()) |i| std.debug.print("{s}: {s} {s}\n", .{ c.call, @tagName(h.bag.at(i).code), h.bag.at(i).message });
            return error.TestUnexpectedResult;
        }
    }
}

test "A.8.1 an empty pattern element is E0894 except in §3.6.3.2's bus nodeset; A.8.2 noise functions take no empty slot" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { src: []const u8, code: ?diag.Code }{
        .{ .src = "parameter real a[0:2] = '{1.0, , 3.0};\nanalog I(p) <+ a[1] * V(p);", .code = .E0894 },
        .{ .src = "parameter real a[0:2] = '{1.0, 2.0, 3.0};\nanalog I(p) <+ a[1] * V(p);", .code = null },
        .{ .src = "real a[0:2];\nanalog begin a = '{1.0, , 3.0}; I(p) <+ a[1] * V(p); end", .code = .E0894 },
        .{ .src = "analog I(p) <+ white_noise(1e-20, , \"x\");", .code = .E0505 },
        .{ .src = "analog I(p) <+ white_noise(1e-20, \"x\");", .code = null },
    };
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p);
            \\inout p; electrical p;
            \\{s}
            \\endmodule
        , .{c.src});
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = h.low.lowerFile() catch |err| switch (err) {
            error.DiagnosticsReported => {},
            else => |e| return e,
        };
        var first: ?diag.Code = null;
        for (0..h.bag.count()) |i| if (h.bag.at(i).severity == .err) {
            first = h.bag.at(i).code;
            break;
        };
        try std.testing.expectEqual(c.code, first);
    }
}

// ---------------------------------------------------------------------------
// Rule cases for the `ir-lower-b` files: one source, one expected verdict
// ---------------------------------------------------------------------------
//
// The oracle is the LRM sentence each case cites, not VerA's own output: a
// refusing case names the code the clause's diagnostic carries, and every
// refusal has a legal neighbour beside it that must lower with no error, so a
// blanket refusal fails the table.

/// One rule case: a source and the code it must report, or null for a source
/// that must lower with no error at all.
const Case = struct { src: []const u8, code: ?diag.Code };

/// Lowers `src` and checks the one fact a `Case` states: `want` among the
/// diagnostics, or, when `want` is null, no error. A mismatch prints the
/// source and every diagnostic, so the failing case names itself.
fn expectRule(src: []const u8, want: ?diag.Code) !void {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, src);
    defer h.deinit();
    _ = h.low.lowerFile() catch |err| switch (err) {
        error.DiagnosticsReported => {},
        else => |e| return e,
    };
    var ok = h.bag.err_count == 0;
    if (want) |w| {
        ok = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == w) ok = true;
        }
    }
    if (ok) return;
    std.debug.print("source:\n{s}\nwanted {s}, got:\n", .{ src, if (want) |w| @tagName(w) else "no error" });
    for (0..h.bag.count()) |i| std.debug.print("  {s}: {s}\n", .{ @tagName(h.bag.at(i).code), h.bag.at(i).message });
    return error.TestUnexpectedResult;
}

/// `expectRule` over a module body: electrical ports `p` and `q`, a real
/// parameter `g`, and the variables the cases read and write.
fn expectBody(body: []const u8, want: ?diag.Code) !void {
    const gpa = std.testing.allocator;
    const src = try gpa.print(
        \\module m(p, q);
        \\  inout p, q;
        \\  electrical p, q;
        \\  parameter real g = 1.0;
        \\  real x, r;
        \\  integer iv, seed;
        \\  string sv;
        \\{s}
        \\endmodule
    , .{body});
    defer gpa.free(src);
    try expectRule(src, want);
}

/// `expectBody` over every case, stopping at the first that fails.
fn expectBodies(cases: []const Case) !void {
    for (cases) |c| try expectBody(c.src, c.code);
}

test "§9.21.2 $table_model: the control string, the dependent selector and the sample count" {
    // One lookup input, two pattern columns (§9.21.1 "Arrays may be specified
    // directly"): ncol = 2, so the leading columns are 1 and there is M = 1
    // dependent. "This number runs 1 though M", so only `;1` selects one.
    try expectBodies(&.{
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;1\");", .code = null },
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;2\");", .code = .E0815 },
        // A selector that parses as an integer but is past every column: the
        // same refusal, never an overflow in the column arithmetic.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL;18446744073709551615\");", .code = .E0815 },
        // "Each sub-string ... has at most 3 characters."
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LLL\");", .code = .E0815 },
        // `X` is in neither Table 9-30 nor Table 9-31.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1X\");", .code = .E0815 },
        // One sub-string per independent variable; there is one.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"1LL,1LL\");", .code = .E0815 },
        // Table 9-30's `I` ignores a column; it takes no extrapolation.
        .{ .src = "analog I(p) <+ $table_model(V(p), '{0.0, 1.0}, '{0.0, 2.0}, \"IC;1\");", .code = .E0815 },
        // §9.21: two dimensions need 2^2 = 4 samples; these columns hold 2.
        .{ .src = "analog I(p) <+ $table_model(V(p), V(q), '{0.0, 1.0}, '{0.0, 1.0}, '{0.0, 1.0});", .code = .E0815 },
        // §9.21.1: the data source "is captured on the first call", so a file
        // that is not there is that call's error, not the compilation's.
        .{ .src = "analog I(p) <+ $table_model(V(p), \"vera_lower_test_no_such_table.tbl\");", .code = null },
    });
}

test "§4.5 analog operators: argument shapes and bounds" {
    try expectBodies(&.{
        // §4.5.1: only the laplace and Z-transform coefficient slots take an
        // array. Anywhere else a pattern is §4.2's scalar context (E0509),
        // never a vector flattened into the operator's other arguments.
        .{ .src = "analog I(p) <+ transition('{1.0, 2.0});", .code = .E0509 },
        .{ .src = "analog I(p) <+ laplace_nd(V(p), '{1.0}, '{1.0, 1.0});", .code = null },
        // §4.5.11: a scalar in a coefficient slot is neither array spelling.
        .{ .src = "analog I(p) <+ laplace_nd(V(p), 1.0, '{1.0, 1.0});", .code = .E0572 },
        // §4.5.6: the second argument is one unknown; V(p, q) is two.
        .{ .src = "analog I(p) <+ ddx(V(p), V(p, q));", .code = .E0504 },
        .{ .src = "analog I(p) <+ ddx(V(p), V(p));", .code = null },
        // §4.5.8 td, §4.5.9 the two rates, §4.5.5 modulus, §4.5.10 direction.
        .{ .src = "analog I(p) <+ transition(V(p), -1.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ transition(V(p), 0.0);", .code = null },
        .{ .src = "analog I(p) <+ slew(V(p), 1.0, 1.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ idtmod(V(p), 0.0, 0.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ last_crossing(V(p), 2);", .code = .E0516 },
        // Table 4-20: abstol is a constant expression argument; a probe moves.
        .{ .src = "analog I(p) <+ ddt(V(p), V(q));", .code = .E0515 },
        .{ .src = "analog I(p) <+ ddt(V(p), 1e-6);", .code = null },
    });
}

test "§4.6 small-signal sources: arguments and labels" {
    try expectBodies(&.{
        // §4.6.4.1 `white_noise(pwr[, name])`: the power is a scalar. Only
        // `noise_table`'s input (§4.6.4.3) is a vector.
        .{ .src = "analog I(p) <+ white_noise('{1.0, 2.0});", .code = .E0509 },
        .{ .src = "analog I(p) <+ white_noise(1e-20);", .code = null },
        // Syntax 4-4: the optional last argument is a string label.
        .{ .src = "analog I(p) <+ white_noise(1e-20, 3);", .code = .E0573 },
        // §4.6.4.2: 1/f^exp has no default exponent.
        .{ .src = "analog I(p) <+ flicker_noise(1e-20);", .code = .E0522 },
        // A.8.2 puts the quotation marks inside `ac_stim`'s production.
        .{ .src = "analog I(p) <+ ac_stim(1);", .code = .E0521 },
    });
}

test "§5.6 contributions: the rules a `<+` is judged by" {
    try expectBodies(&.{
        // §6.3.6: every flow contribution is already scaled by $mfactor.
        .{ .src = "analog I(p) <+ V(p) * $mfactor;", .code = .E0912 },
        .{ .src = "analog I(p) <+ V(p) + 0.0 * $mfactor;", .code = null },
        // §4.5.12: a zero-transition Z-filter "shall not be directly assigned".
        .{ .src = "analog V(p) <+ zi_nd(V(q), '{1.0}, '{1.0}, 1n, 0);", .code = .E0518 },
        // §7.3.2.1: an infinite value contributed to a branch.
        .{ .src = "analog begin x = 1.0 / 0.0; I(p) <+ x + 0.0 * V(p); end", .code = .E0424 },
        .{ .src = "analog begin x = 1.0 / 2.0; I(p) <+ x + 0.0 * V(p); end", .code = null },
        // §1.3.1: both quantities of a probe branch; a contribution makes it a
        // source, whose two quantities §5.4.2.2 makes accessible.
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(p) <+ x; end", .code = .E0423 },
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(p, q) <+ x * 1m; end", .code = null },
        // §4.4 Table 4-16: `I(n1,n1)` is an error.
        .{ .src = "analog I(p) <+ I(p, p);", .code = .E0315 },
        // §5.9: no contribution inside a procedural `for`.
        .{ .src = "analog for (iv = 0; iv < 2; iv = iv + 1) I(p) <+ 1.0;", .code = .E0426 },
    });
}

test "§1.3.1.2 a reversed spelling accumulates into one source" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  analog begin
        \\    I(p, q) <+ 1.0;
        \\    I(q, p) <+ 2.0;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // `I(q,p) <+ 2` is `I(p,q) <+ -2`: one row, in canonical (p, q) order.
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    try std.testing.expectEqual(@as(u16, 0), h.low.out.contributions.items[0].hi);
    try std.testing.expectEqual(@as(u16, 1), h.low.out.contributions.items[0].lo);
}

test "§9.4/§9.7/§9.17 system tasks: arguments a task refuses, and their neighbours" {
    try expectBodies(&.{
        // §9.7.3 `finish_number ::= 0 | 1 | 2`.
        .{ .src = "analog begin $fatal(3); I(p) <+ V(p); end", .code = .E0824 },
        .{ .src = "analog begin $fatal(1, \"stop\"); I(p) <+ V(p); end", .code = null },
        // §9.17.2 "The expression argument shall be non-negative."
        .{ .src = "analog begin $bound_step(-1.0); I(p) <+ V(p); end", .code = .E0803 },
        .{ .src = "analog begin $bound_step(1n); I(p) <+ V(p); end", .code = null },
        // §9.17.1: "i must be a non-negative integer"; -1 is the special form.
        .{ .src = "analog begin $discontinuity(-2); I(p) <+ V(p); end", .code = .E0820 },
        .{ .src = "analog begin $discontinuity(-1); I(p) <+ V(p); end", .code = null },
        // §9.17.1's argument is a constant_expression.
        .{ .src = "analog begin x = V(p); $discontinuity(x); I(p) <+ V(p); end", .code = .E0805 },
        // §9.4.3: one argument per consuming conversion; `%%` consumes none.
        .{ .src = "analog begin $strobe(\"%d %d\", 1); I(p) <+ V(p); end", .code = .E0810 },
        .{ .src = "analog begin $strobe(\"%d%%\", 1); I(p) <+ V(p); end", .code = null },
        .{ .src = "analog begin $strobe(\"%s\", 1.5); I(p) <+ V(p); end", .code = .E0819 },
        // §9.5.3: `$swrite` writes into a string variable.
        .{ .src = "analog begin $swrite(x, \"a\"); I(p) <+ V(p); end", .code = .E0813 },
        // §9.5.4.2's six conversion codes, and nothing else.
        .{ .src = "analog begin iv = $sscanf(\"1\", \"%q\", r); I(p) <+ V(p); end", .code = .E0813 },
        .{ .src = "analog begin iv = $sscanf(\"1\", \"%d\", r); I(p) <+ V(p) * r; end", .code = null },
        // §9.7.2 "The $stop task shall not be used within an analog initial block."
        .{ .src = "analog initial begin $stop; end\nanalog I(p) <+ V(p);", .code = .E0807 },
    });
}

test "Clause 9 system functions: context and argument rules" {
    try expectBodies(&.{
        // §9.2 Table 9-7: `$time` reads No in the analog column.
        .{ .src = "analog begin x = $time; I(p) <+ x; end", .code = .E0806 },
        // §9.22 "Driver access functions can only be called from connect modules."
        .{ .src = "analog begin x = $driver_count(p); I(p) <+ x; end", .code = .E0818 },
        // Annex G: `$limexp` became §4.5.13's `limexp`.
        .{ .src = "analog begin x = $limexp(1.0); I(p) <+ x; end", .code = .E0808 },
        // §9.17.3: pnjlim takes vte and vcrit.
        .{ .src = "analog I(p) <+ $limit(V(p), \"pnjlim\", 0.025);", .code = .E0809 },
        // §9.15: an unknown name is an error only without the fallback.
        .{ .src = "analog begin x = $simparam(\"vera_no_such\"); I(p) <+ x; end", .code = .E0811 },
        .{ .src = "analog begin x = $simparam(\"vera_no_such\", 1.0); I(p) <+ x * V(p); end", .code = null },
        .{ .src = "analog begin sv = $simparam$str(\"vera_no_such\"); I(p) <+ V(p); end", .code = .E0811 },
        // §9.19: "a single argument, which must be a parameter identifier".
        .{ .src = "analog begin x = $param_given(x); I(p) <+ x; end", .code = .E0822 },
        .{ .src = "analog begin x = $param_given(g); I(p) <+ x * V(p); end", .code = null },
        // §4.6.1 / A.8.2: each analysis name is a quoted string.
        .{ .src = "analog begin x = analysis(dc); I(p) <+ x; end", .code = .E0574 },
        .{ .src = "analog begin x = analysis(\"dc\"); I(p) <+ x * V(p); end", .code = null },
    });
}

test "§9.13 distributions: the seed and the parameter rules" {
    try expectBodies(&.{
        // "For each system function, the seed argument shall be an integer."
        .{ .src = "analog begin iv = $random(r); I(p) <+ iv; end", .code = .E0816 },
        // Syntax 9-9: $dist_uniform takes a seed, a start and an end.
        .{ .src = "analog begin iv = $dist_uniform(seed, 0); I(p) <+ iv; end", .code = .E0816 },
        // "The start value shall be smaller than the end value."
        .{ .src = "analog begin x = $rdist_uniform(seed, 2.0, 1.0); I(p) <+ x; end", .code = .E0816 },
        .{ .src = "analog begin x = $rdist_uniform(seed, 0.0, 1.0); I(p) <+ x * V(p); end", .code = null },
        // "mean ... shall be greater than zero (0)."
        .{ .src = "analog begin x = $rdist_exponential(seed, -1.0); I(p) <+ x; end", .code = .E0816 },
        // A type_string "shall only be used ... from within a paramset".
        .{ .src = "analog begin x = $rdist_uniform(seed, 0.0, 1.0, \"global\"); I(p) <+ x; end", .code = .E0816 },
    });
}

test "§9.13.1 omitted seeds number their sites in source order" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer a, b;
        \\  analog begin
        \\    a = $random;
        \\    b = $random;
        \\    I(p) <+ (a + b) * V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // "the simulator picks a seed": VerA's pick is 1 + 7919·ordinal, so the
    // two sites start apart (`lowerRandom`).
    try std.testing.expectEqualSlices(i64, &.{ 1, 7920 }, h.low.out.rng_auto_seeds.items);
}

test "§5.10.3 monitored events: argument rules, each beside a legal call" {
    try expectBodies(&.{
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.1 the direction "shall evaluate to integers".
        .{ .src = "analog begin @(cross(V(p) - 0.5, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If either or both tolerances are defined, then the direction shall
        // also be defined."
        .{ .src = "analog begin @(cross(V(p) - 0.5, , 1n)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If expr_tol is specified, time_tol shall also be specified."
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, , 1u)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // A.6.5: the enable is analog_expression, not `_or_null`.
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u, )) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // §5.10.3.3 time_tol is non-negative.
        .{ .src = "analog begin @(timer(0, 1n, -1p)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(timer(0, 1n)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.2 the enable "shall evaluate to an integer".
        .{ .src = "analog begin @(above(V(p) - 0.5, 1n, 1u, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(above(V(p) - 0.5)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.4 absdelta is "only allowed in an initial or always block".
        .{ .src = "analog begin @(absdelta(V(p), 0.1)) x = 1.0; I(p) <+ x; end", .code = .E0513 },
        // §5.10 "Nested event control statements are not allowed."
        .{ .src = "analog begin @(initial_step) @(final_step) x = 1.0; I(p) <+ x; end", .code = .E0703 },
    });
}

test "§3.6 natures and disciplines: the declaration rules" {
    const cases = [_]Case{
        // §3.6.2.1 one nature on both bindings.
        .{ .src =
        \\nature lb_n1; units = "V"; access = LbV1; abstol = 1u; endnature
        \\discipline lb_d1; potential lb_n1; flow lb_n1; enddiscipline
        \\module m; endmodule
        , .code = .E0338 },
        // §3.6.2.2 a discrete domain with a nature binding.
        .{ .src =
        \\nature lb_n2; units = "V"; access = LbV2; abstol = 1u; endnature
        \\discipline lb_d2; potential lb_n2; domain discrete; enddiscipline
        \\module m; endmodule
        , .code = .E0339 },
        // §3.6.1.2 abstol "is required for all base natures".
        .{ .src =
        \\nature lb_n3; units = "V"; access = LbV3; endnature
        \\module m; endmodule
        , .code = .E0332 },
        // A derived nature inherits units and access; it does not restate them.
        .{ .src =
        \\nature lb_n4; units = "V"; access = LbV4; abstol = 1u; endnature
        \\nature lb_n5 : lb_n4; units = "mV"; endnature
        \\module m; endmodule
        , .code = .E0333 },
        .{ .src =
        \\nature lb_n4; units = "V"; access = LbV4; abstol = 1u; endnature
        \\nature lb_n6 : lb_n4; access = LbV6; endnature
        \\module m; endmodule
        , .code = .E0334 },
        // §3.6.1.3 "The name of the attribute shall be unique".
        .{ .src =
        \\nature lb_n7; units = "V"; access = LbV7; abstol = 1u; abstol = 2u; endnature
        \\module m; endmodule
        , .code = .E0343 },
        // §3.6.1.2 access "shall be an identifier (by name, not as a string)".
        .{ .src =
        \\nature lb_n8; units = "V"; access = "LbV8"; abstol = 1u; endnature
        \\module m; endmodule
        , .code = .E0340 },
        // §3.13.1 one scope for natures and disciplines.
        .{ .src =
        \\nature lb_x; units = "V"; access = LbX; abstol = 1u; endnature
        \\discipline lb_x; potential lb_x; enddiscipline
        \\module m; endmodule
        , .code = .E0336 },
        .{ .src =
        \\nature lb_n9; units = "V"; access = LbV9; abstol = 1u; endnature
        \\nature lb_n9; units = "V"; access = LbV9b; abstol = 1u; endnature
        \\module m; endmodule
        , .code = .E0342 },
        // §3.13.2 "the access function of each base nature shall be unique".
        .{ .src =
        \\nature lb_a; units = "V"; access = LbAcc; abstol = 1u; endnature
        \\nature lb_b; units = "A"; access = LbAcc; abstol = 1u; endnature
        \\module m; endmodule
        , .code = .E0335 },
        // §3.6.1.2 ddt_nature "shall be the name ... of a nature which is
        // defined elsewhere".
        .{ .src =
        \\nature lb_n10; units = "V"; access = LbV10; abstol = 1u; ddt_nature = lb_nowhere; endnature
        \\module m; endmodule
        , .code = .E0374 },
        .{ .src =
        \\nature lb_n11; units = "Wb"; access = LbPhi11; abstol = 1u; endnature
        \\nature lb_n12; units = "V"; access = LbV12; abstol = 1u; ddt_nature = lb_n11; endnature
        \\module m; endmodule
        , .code = null },
        // §3.6.2.5 "the bound nature and attribute needs to be defined".
        .{ .src =
        \\nature lb_n13; units = "V"; access = LbV13; abstol = 1u; endnature
        \\discipline lb_d13; potential lb_n13; flow.abstol = 1u; enddiscipline
        \\module m; endmodule
        , .code = .E0370 },
        // §3.11 "if an access function has two nets as arguments, they must
        // be compatible": electrical and thermal bind different natures.
        .{ .src =
        \\module m(a, b);
        \\  inout a, b;
        \\  electrical a;
        \\  thermal b;
        \\  analog I(a, b) <+ V(a, b);
        \\endmodule
        , .code = .E0355 },
    };
    for (cases) |c| try expectRule(c.src, c.code);
}

test "§3.6.2.5 a discipline's abstol override is the value its net reads" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\nature lb_i; units = "A"; access = LbI; abstol = 1u; endnature
        \\nature lb_v; units = "V"; access = LbV; abstol = 100u; endnature
        \\discipline lb_ttl; potential lb_v; flow lb_i; flow.abstol = 10u; enddiscipline
        \\module m; endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    const info = h.low.out.disciplines.get("lb_ttl").?;
    // §2.6.2: 10u and 1e-5 are one real number, so the comparison is exact.
    try std.testing.expectEqual(@as(f64, 1e-5), info.flow_abstol);
    try std.testing.expectEqual(@as(f64, 1e-4), info.potential_abstol);
    try std.testing.expectEqualStrings("LbV", info.potential_access);
    try std.testing.expect(info.has_potential and info.has_flow and !info.is_discrete);
}

test "§9.17.3 one $limit state slot per access function, whatever the site count" {
    const cases = [_]struct { second: []const u8, slots: usize }{
        .{ .second = "V(p)", .slots = 1 }, // two sites, one access function
        .{ .second = "V(q)", .slots = 2 },
    };
    for (cases) |c| {
        const gpa = std.testing.allocator;
        const src = try gpa.print(
            \\module m(p, q);
            \\  inout p, q; electrical p, q;
            \\  analog function real lim;
            \\    input vnew, vold;
            \\    real vnew, vold;
            \\    lim = vnew;
            \\  endfunction
            \\  analog begin
            \\    I(p) <+ 1m * $limit(V(p), lim);
            \\    I(q) <+ 1m * $limit({s}, lim);
            \\  end
            \\endmodule
        , .{c.second});
        defer gpa.free(src);
        var h: Harness = undefined;
        try h.init(gpa, src);
        defer h.deinit();
        _ = try h.low.lowerFile();
        try std.testing.expectEqual(c.slots, h.low.out.limit_slots.items.len);
    }
}

test "§9.17.3 a limiter's formals are all input, and the simulator supplies two" {
    // "The arguments of the user-defined function shall all be declared input."
    try expectRule(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real lim;
        \\    input vnew; output vold;
        \\    real vnew, vold;
        \\    lim = vnew;
        \\  endfunction
        \\  analog I(p) <+ 1m * $limit(V(p), lim);
        \\endmodule
    , .E0814);
    // vnew and vold come from the simulator; a third formal has no actual.
    try expectRule(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real lim;
        \\    input vnew, vold, k;
        \\    real vnew, vold, k;
        \\    lim = k * vnew;
        \\  endfunction
        \\  analog I(p) <+ 1m * $limit(V(p), lim);
        \\endmodule
    , .E0511);
}

test "§4.7 analog functions: recursion on the declarations, arity at the call" {
    // §4.7.3 "recursive functions are not permitted", called or not.
    try expectRule(
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog function real f;
        \\    input a; real a;
        \\    f = h(a);
        \\  endfunction
        \\  analog function real h;
        \\    input a; real a;
        \\    h = f(a);
        \\  endfunction
        \\  analog I(p) <+ V(p);
        \\endmodule
    , .E0510);
    try expectRule(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real r;
        \\  analog function real f;
        \\    input a; real a;
        \\    f = 2.0 * a;
        \\  endfunction
        \\  analog begin r = f(1.0, 2.0); I(p) <+ r * V(p); end
        \\endmodule
    , .E0511);
}

test "§4.7.2.3/§6.8 an array formal's bounds are the function's own declarations" {
    // §6.8 makes the analog function a scope, so its local `n` (2) shadows the
    // module's (3) in the formal's declaration as it does in the body: `v` is
    // two cells, and a two-element pattern is "of equivalent size".
    try expectRule(
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter integer n = 3;
        \\  real r;
        \\  analog function real sum2;
        \\    input v;
        \\    parameter integer n = 2;
        \\    real v[0:n-1];
        \\    sum2 = v[0] + v[1];
        \\  endfunction
        \\  analog begin r = sum2('{1.0, 2.0}); I(p) <+ r * V(p); end
        \\endmodule
    , null);
}

test "§9.4.1/§5.3.2 a deferred display operand keeps its named block's names" {
    // `$strobe` reads a branch flow, so its operand is lowered at the end of
    // the block, where §5.4.2.2's flow is converged. `x` is the named block's
    // own variable, and the operand was written in its scope.
    var h: Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  analog begin : blk
        \\    real x;
        \\    x = 2.0;
        \\    $strobe("%g", x * I(p, q));
        \\    I(p, q) <+ V(p, q);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = h.low.lowerFile() catch |err| switch (err) {
        error.DiagnosticsReported => {},
        else => |e| return e,
    };
    if (h.bag.err_count != 0) for (0..h.bag.count()) |i| std.debug.print("  {s}: {s}\n", .{ @tagName(h.bag.at(i).code), h.bag.at(i).message });
    try std.testing.expectEqual(@as(u32, 0), h.bag.err_count);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.displays.items.len);
}
