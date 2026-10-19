//! Unit analog-a's cross-cutting checks: the lowering pass and the SSA
//! builder under every allocation failure, lowering's determinism, and the
//! small pure helpers checked exhaustively against a naive oracle.
//!
//! LRM clauses this file's code cites: §3.4, §5.8, §5.9, §7.3.1.
//! IEEE 1364-2005 clauses cited: §4.2.1, §5.5.1.

const std = @import("std");
const Lower = @import("../lower.zig");
const Ssa = @import("../ssa.zig");
const Mir = @import("ir").Mir;
const lower_expr = @import("expr.zig");
const lower_constfold = @import("constfold.zig");

/// Sources that between them reach every file of the unit: parameters and an
/// alias, ports, a vector net and a branch, variables and a runtime-indexed
/// array, a function, a conditional, a loop, a §7.3.1 select of a wide
/// discrete input (its `Model` words), and a contribution.
const oom_sources = [_][]const u8{
    \\module m(p, n);
    \\  inout p, n; electrical p, n;
    \\  electrical [1:0] b;
    \\  branch (p, n) br;
    \\  parameter real g = 1.0 from [0:inf);
    \\  localparam integer k = 3;
    \\  aliasparam ga = g;
    \\  real x, a[0:2];
    \\  integer i;
    \\  analog function real sq;
    \\    input v; real v;
    \\    sq = v * v;
    \\  endfunction
    \\  analog begin
    \\    x = 0.0;
    \\    for (i = 0; i < k; i = i + 1) a[i % 3] = sq(V(br)) + i;
    \\    if (V(p) > 0.5) x = a[i % 3]; else x = -g;
    \\    I(br) <+ x * V(br) + 0.0 * V(b[1], b[0]);
    \\  end
    \\endmodule
    ,
    \\module m(p);
    \\  inout p; electrical p;
    \\  reg [63:0] r;
    \\  initial #1 r = 64'h1234_5678_9abc_def0;
    \\  real y;
    \\  analog begin
    \\    y = r[40:33];
    \\    I(p) <+ y * V(p);
    \\  end
    \\endmodule
    ,
};

/// Lowers `src` with every buffer, the SSA builder's tables included, from
/// `gpa`; a failed allocation must come back as `error.OutOfMemory`.
fn lowerAll(gpa: std.mem.Allocator, src: []const u8) !void {
    var h: Lower.Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    h.low.builder.map = gpa;
    const out = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(out.nodes.len != 0);
}

test "lower: every allocation failure unwinds as OutOfMemory and leaks nothing" {
    for (oom_sources) |src| try std.testing.checkAllAllocationFailures(std.testing.allocator, lowerAll, .{src});
}

test "lower: the same source lowers to the same MIR and node table twice" {
    // Determinism oracle: a hash map's iteration order reaching the output
    // would make two lowerings of one source differ.
    for (oom_sources) |src| {
        var runs: [2]Lower.Harness = undefined;
        for (&runs) |*h| try h.init(std.testing.allocator, src);
        defer for (&runs) |*h| h.deinit();
        var outs: [2]Lower.Lowered = undefined;
        for (&runs, &outs) |*h, *o| o.* = (try h.lower()).?;
        try std.testing.expectEqualSlices(Mir.Opcode, runs[0].mir.insts.items(.op), runs[1].mir.insts.items(.op));
        try std.testing.expectEqual(outs[0].nodes.len, outs[1].nodes.len);
        for (outs[0].nodes.items(.name), outs[1].nodes.items(.name)) |a, b| try std.testing.expectEqualStrings(a, b);
        try std.testing.expectEqual(outs[0].params.items.len, outs[1].params.items.len);
        for (outs[0].params.items, outs[1].params.items) |a, b| try std.testing.expectEqualStrings(a.name, b.name);
    }
}

/// A diamond (§5.8) then a loop (§5.9) whose header is sealed after its
/// back edge, every read through the builder, every table from `gpa`.
fn ssaProgram(gpa: std.mem.Allocator) !void {
    var mir: Mir = .{};
    defer mir.deinit(gpa);
    var b = Ssa.SsaBuilder.init(gpa, &mir);
    b.map = gpa;
    defer b.deinit();
    const entry = try mir.addBlock(gpa);
    const then_b = try mir.addBlock(gpa);
    const else_b = try mir.addBlock(gpa);
    const join = try mir.addBlock(gpa);
    const header = try mir.addBlock(gpa);
    const body = try mir.addBlock(gpa);
    const exit = try mir.addBlock(gpa);
    try b.sealBlock(entry);
    try b.addPredecessor(then_b, entry);
    try b.addPredecessor(else_b, entry);
    try b.sealBlock(then_b);
    try b.sealBlock(else_b);
    try b.addPredecessor(join, then_b);
    try b.addPredecessor(join, else_b);
    try b.sealBlock(join);
    const x = b.newPlace();
    const i = b.newPlace();
    try b.writeVariable(x, then_b, .f_one);
    try b.writeVariable(x, else_b, .f_two);
    try b.writeVariable(i, entry, .zero);
    const xj = try b.readVariable(x, join);
    try b.addPredecessor(header, join);
    try b.addPredecessor(body, header);
    try b.sealBlock(body);
    const iv = try b.readVariable(i, body);
    try b.writeVariable(i, body, try mir.emit(gpa, body, .iadd, &.{ iv, .one }));
    try b.addPredecessor(header, body);
    try b.sealBlock(header);
    try b.addPredecessor(exit, header);
    try b.sealBlock(exit);
    // The diamond's phi survives the loop; the induction variable is a real phi.
    try std.testing.expectEqual(mir.resolveAlias(xj), mir.resolveAlias(try b.readVariable(x, exit)));
    try std.testing.expectEqual(iv, mir.resolveAlias(try b.readVariable(i, exit)));
}

test "SsaBuilder: every allocation failure unwinds as OutOfMemory and leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ssaProgram, .{});
}

test "selectPos: every bit of every small range against a walk of the range" {
    // IEEE 1364-2005 §4.2.1: the right-hand bound is the LSB in either
    // direction. Oracle: walk the declared range from its right bound,
    // counting places, and compare with `selectPos` for every k near it.
    var right: i64 = -3;
    while (right <= 3) : (right += 1) for ([_]bool{ false, true }) |asc| for (1..6) |width| {
        const r: Lower.RegRange = .{ .right = right, .asc = asc, .width = @intCast(width) };
        var k: i64 = -12;
        while (k <= 12) : (k += 1) {
            var want: ?u32 = null;
            for (0..width) |pos| {
                const bit = if (asc) right - @as(i64, @intCast(pos)) else right + @as(i64, @intCast(pos));
                if (bit == k) want = @intCast(pos);
            }
            try std.testing.expectEqual(want, lower_expr.selectPos(r, k));
        }
    };
}

test "integerSourceSigned: an untyped local parameter carries its default's signedness" {
    // IEEE 1364-2005 §5.5.1 through a chain of `localparam` names: `c`
    // reads `a`, a signed literal, so `c < d` with `d` unsigned is §4.2.9's
    // unsigned comparison; `c < e` with `e` signed is not.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  localparam a = 4'sd3;
        \\  localparam c = a;
        \\  localparam d = 4'd2;
        \\  localparam e = 4'sd2;
        \\  integer u, s;
        \\  analog begin
        \\    u = c < d;
        \\    s = c < e;
        \\    I(p) <+ (u + s) * V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.lower() orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
    const ex = &h.file.exprs;
    var unsigned: u32 = 0;
    var signed: u32 = 0;
    for (0..ex.len()) |n| {
        const e: @import("frontend").Ast.ExprId = @fromBackingInt(@intCast(n));
        if (ex.tag(e) != .binary or ex.binOp(e) != .lt) continue;
        if (lower_constfold.unsignedCompare(&h.low, e) != null) unsigned += 1 else signed += 1;
    }
    try std.testing.expectEqual(1, unsigned);
    try std.testing.expect(signed >= 1);
}
