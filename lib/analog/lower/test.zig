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
const Mir = @import("ir").Mir;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const ground = Lower.ground;
const Access = Lower.Access;
const Kind = Lower.Kind;

/// The frontend parser namespace the harness drives.
pub const Parser = @import("frontend").Parser;

/// The one lowering harness (`Lower.Harness`), shared with every `lower/*.zig` test.
const Harness = Lower.Harness;

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
    try std.testing.expectEqual(@as(u32, 2), h.low.out.num_ports);
    try std.testing.expectEqualStrings("p", h.low.out.nodes.items(.name)[0]);
    try std.testing.expectEqualStrings("n", h.low.out.nodes.items(.name)[1]);

    // §3.4.2 the value range MUST survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 2), h.low.out.params.items.len);
    try std.testing.expectEqualStrings("r", h.low.out.params.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.params.items[0].ranges.len);
    try std.testing.expect(h.low.out.params.items[0].ranges[0].kind == .from);

    // §5.6.1.3 both `<+` statements accumulate into ONE target…
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    const c = h.low.out.contributions.items[0];
    try std.testing.expectEqual(Access.flow, c.access);
    try std.testing.expectEqual(@as(u32, 0), c.hi);
    try std.testing.expectEqual(@as(u32, 1), c.lo);
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

    try std.testing.expectEqual(@as(u32, 2), h.low.out.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.out.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u32, 0), h.low.out.port_probes.items[0].port);
    try std.testing.expectEqual(@as(u32, 1), h.low.out.port_probes.items[1].port);
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
    // value. `dispatch.emitStamps` skips a contribution whose value folds to `.f_zero`,
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

test "lower: A.6.2 an initial block of constant assignments lowers; its refusals name their own clause" {
    // The accepting side is six fixtures (ch07/digital_initial_accepted,
    // discrete_bus_narrow, discrete_bus_31, discrete_real_from_analog,
    // annex_c/13, ch08/analog_digital_initial_order), which pin the VALUE end to
    // end. Every body that is not the constant shape (a non-constant
    // right-hand side, a loop, an array element, a system task) is a process
    // and makes the module mixed (`lower_context.isMixed`'s test, #57), so it
    // runs on the kernel rather than being refused. What stays refused here is
    // stated below, each under its own rule.
    const cases = [_]struct { stmt: []const u8, code: diag.Code }{
        // §5.10 event control: the block suspends, so it is a PROCESS and the
        // module is mixed; what it suspends on is `initial_step`, which §5.10
        // does not allow "in the digital context".
        .{ .stmt = "@(initial_step) q = 1;", .code = .E0708 },
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

test "§9.17.3 a limiter's formals are all input, and the simulator supplies two" {
    // "The arguments of the user-defined function shall all be declared input."
    try Lower.expectVerdict(
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
    try Lower.expectVerdict(
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
