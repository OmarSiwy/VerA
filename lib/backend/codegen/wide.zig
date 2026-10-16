//! IEEE 1364-2005 §5.4 wide integers: a `$wide`/`$wide$int` call's
//! `Lowered.wide_nodes` tree in, one Zig expression over
//! `kernels/wide_kernels.zig` out (`zwAdd(72, a, b)`), every node already of
//! the type `lower/wide.zig` sized it to. Also the Zig type and zero of a
//! `.wide` value (`ZW(n)`), which slots, `Instance` fields and the core's
//! cache spell.
//! LRM clauses cited: §7.3.1; IEEE 1364-2005 §4.8.2, §5.1, §5.4.1, §5.5.

const std = @import("std");
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_render = @import("render.zig");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Error = codegen.Error;

/// The Zig type of a `.wide` value of `width` bits.
pub fn zigTy(self: *Gen, width: u32) Error![]const u8 {
    return self.arena.print("ZW({d})", .{width});
}

/// Writes `$wide(root, operands...)` (the root's bits) or, `as_int`,
/// `$wide$int(root, operands...)` (the §7.3.1 integer a select reads).
pub fn emitWide(self: *Gen, args: []const Mir.Value, as_int: bool) Error!void {
    const root = gen_render.intArg(self, args, 0).?;
    const n = self.lowered.wide_nodes.items[root];
    if (as_int) try self.b("zwInt({d}, {}, ", .{ n.width, n.signed });
    try node(self, args[1..], @intCast(root));
    if (as_int) try self.b(")", .{});
}

/// Writes `v`'s bits as a comptime value when it is a `$wide` call over a
/// tree of literals (a held `reg`'s `Instance` default); false otherwise.
pub fn emitConstInit(self: *Gen, v: Mir.Value) Error!bool {
    const def = self.mir.valueDef(self.an.rv(v));
    if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) return false;
    const d = self.mir.instData(def.inst_result).call;
    if (d.callee != .@"$wide" or d.args.len != 1) return false;
    try emitWide(self, d.args, false);
    return true;
}

fn node(self: *Gen, ops: []const Mir.Value, i: u32) Error!void {
    const nodes = self.lowered.wide_nodes.items;
    const n = nodes[i];
    const w = n.width;
    switch (n.op) {
        .leaf_int => {
            try self.b("zwLeaf({d}, ", .{w});
            try gen_render.renderVal(self, ops[n.arg], .int);
            try self.b(")", .{});
        },
        .leaf_words => {
            try self.b("zwWords({d}, .{{ ", .{w});
            for (0..(w + 31) / 32) |k| {
                if (k != 0) try self.b(", ", .{});
                try gen_render.renderVal(self, ops[n.arg + k], .int);
            }
            try self.b(" }})", .{});
        },
        .leaf_wide => try gen_render.renderVal(self, ops[n.arg], .wide),
        .leaf_real => {
            // The value only: a wide integer carries no derivative.
            float_lanes.pinLanes(self, ops[n.arg]);
            try self.b("(", .{});
            try gen_render.renderVal(self, ops[n.arg], .real);
            try self.b(").val()", .{});
        },
        .lit => {
            try self.b("zwConst({d}, .{{ ", .{w});
            for (self.lowered.wide_lits.items[n.arg..][0 .. (w + 31) / 32], 0..) |d, k| {
                if (k != 0) try self.b(", ", .{});
                try self.b("0x{x}", .{d});
            }
            try self.b(" }})", .{});
        },
        .resize => {
            try self.b("zwResize({d}, {d}, {}, ", .{ w, nodes[n.a].width, n.signed });
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .to_real => {
            try self.b("zwToReal({d}, {}, ", .{ nodes[n.a].width, nodes[n.a].signed });
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .from_real => {
            try self.b("zwFromReal({d}, ", .{w});
            try node(self, ops, n.a);
            try self.b(")", .{});
        },
        .neg => if (w == 0) try unaryReal(self, ops, "-", n.a) else try call(self, ops, "zwNeg", n, &.{n.a}),
        .not => try call(self, ops, "zwNot", n, &.{n.a}),
        .add => if (w == 0) try binaryReal(self, ops, "+", n) else try call(self, ops, "zwAdd", n, &.{ n.a, n.b }),
        .sub => if (w == 0) try binaryReal(self, ops, "-", n) else try call(self, ops, "zwSub", n, &.{ n.a, n.b }),
        .mul => if (w == 0) try binaryReal(self, ops, "*", n) else try call(self, ops, "zwMul", n, &.{ n.a, n.b }),
        .div => if (w == 0) try binaryReal(self, ops, "/", n) else try signedCall(self, ops, "zwDiv", n),
        .rem => if (w == 0) try fnReal(self, ops, "@rem", n) else try signedCall(self, ops, "zwRem", n),
        .@"and" => try call(self, ops, "zwAnd", n, &.{ n.a, n.b }),
        .@"or" => try call(self, ops, "zwOr", n, &.{ n.a, n.b }),
        .xor => try call(self, ops, "zwXor", n, &.{ n.a, n.b }),
        .xnor => try call(self, ops, "zwXnor", n, &.{ n.a, n.b }),
        .shl => {
            try self.b("zwShl({d}, ", .{w});
            try node(self, ops, n.a);
            try self.b(", {d}, ", .{nodes[n.b].width});
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .shr, .ashr => {
            // §5.1.12: `>>>` fills with the sign of a signed operand only.
            try self.b("zwShr({d}, {}, ", .{ w, n.op == .ashr and n.signed });
            try node(self, ops, n.a);
            try self.b(", {d}, ", .{nodes[n.b].width});
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .pow => if (w == 0) try fnReal(self, ops, "std.math.pow(f64, ", n) else {
            // A real exponent makes the operator real (`lower/wide.zig`).
            const e = nodes[n.b];
            try self.b("zwPow({d}, {}, ", .{ w, n.signed });
            try node(self, ops, n.a);
            try self.b(", {d}, {}, ", .{ e.width, e.signed });
            try node(self, ops, n.b);
            try self.b(")", .{});
        },
        .eq, .lt, .le => {
            const a = nodes[n.a];
            try self.b("@as(u1, @intFromBool(", .{});
            if (a.width == 0) {
                try self.b("(", .{});
                try node(self, ops, n.a);
                try self.b(") {s} (", .{switch (n.op) {
                    .eq => "==",
                    .lt => "<",
                    .le => "<=",
                    else => unreachable, // else: the enclosing prong
                }});
                try node(self, ops, n.b);
                try self.b(")", .{});
            } else {
                // `le` is `!(b < a)`: an integer order is total.
                const swap = n.op == .le;
                try self.b("{s}{s}({d}, ", .{ if (swap) "!" else "", if (n.op == .eq) "zwEq" else "zwLt", a.width });
                if (n.op != .eq) try self.b("{}, ", .{a.signed});
                try node(self, ops, if (swap) n.b else n.a);
                try self.b(", ", .{});
                try node(self, ops, if (swap) n.a else n.b);
                try self.b(")", .{});
            }
            try self.b("))", .{});
        },
        .land, .lor => {
            try self.b("@as(u1, @intFromBool(", .{});
            try truth(self, ops, n.a);
            try self.b(" {s} ", .{if (n.op == .land) "and" else "or"});
            try truth(self, ops, n.b);
            try self.b("))", .{});
        },
        .lnot => {
            try self.b("@as(u1, @intFromBool(!", .{});
            try truth(self, ops, n.a);
            try self.b("))", .{});
        },
        .red_and, .red_or, .red_xor => {
            const a = nodes[n.a];
            try self.b("@as(u1, @intFromBool({s}{s}({d}, ", .{
                if (n.op == .red_or) "!" else "",
                switch (n.op) {
                    .red_and => "zwAll",
                    .red_or => "zwIsZero",
                    .red_xor => "zwParity",
                    else => unreachable, // else: the enclosing prong
                },
                a.width,
            });
            try node(self, ops, n.a);
            try self.b(")))", .{});
        },
        .cond => {
            try self.b("(if (", .{});
            try truth(self, ops, n.a);
            try self.b(") ", .{});
            try node(self, ops, n.b);
            try self.b(" else ", .{});
            try node(self, ops, n.c);
            try self.b(")", .{});
        },
    }
}

/// §5.1.9 the truth of node `i`: nonzero (an integer has no x here).
fn truth(self: *Gen, ops: []const Mir.Value, i: u32) Error!void {
    const n = self.lowered.wide_nodes.items[i];
    if (n.width == 0) {
        try self.b("((", .{});
        try node(self, ops, i);
        return self.b(") != 0.0)", .{});
    }
    try self.b("!zwIsZero({d}, ", .{n.width});
    try node(self, ops, i);
    try self.b(")", .{});
}

fn call(self: *Gen, ops: []const Mir.Value, name: []const u8, n: Lowered.WideNode, operands: []const u32) Error!void {
    try self.b("{s}({d}", .{ name, n.width });
    for (operands) |o| {
        try self.b(", ", .{});
        try node(self, ops, o);
    }
    try self.b(")", .{});
}

fn signedCall(self: *Gen, ops: []const Mir.Value, name: []const u8, n: Lowered.WideNode) Error!void {
    try self.b("{s}({d}, {}, ", .{ name, n.width, n.signed });
    try node(self, ops, n.a);
    try self.b(", ", .{});
    try node(self, ops, n.b);
    try self.b(")", .{});
}

fn unaryReal(self: *Gen, ops: []const Mir.Value, op: []const u8, a: u32) Error!void {
    try self.b("({s}(", .{op});
    try node(self, ops, a);
    try self.b("))", .{});
}

fn binaryReal(self: *Gen, ops: []const Mir.Value, op: []const u8, n: Lowered.WideNode) Error!void {
    try self.b("((", .{});
    try node(self, ops, n.a);
    try self.b(") {s} (", .{op});
    try node(self, ops, n.b);
    try self.b("))", .{});
}

/// `f(a, b)` over two reals; `f` ends where its first operand begins.
fn fnReal(self: *Gen, ops: []const Mir.Value, f: []const u8, n: Lowered.WideNode) Error!void {
    try self.b("{s}{s}", .{ f, if (std.mem.endsWith(u8, f, " ")) "" else "(" });
    try node(self, ops, n.a);
    try self.b(", ", .{});
    try node(self, ops, n.b);
    try self.b(")", .{});
}
