//! One expression -> one Zig expression over `rt.logic`, for `emit.zig`.
//!
//! In: an AST expression in the scope `Emitter.r.scope` names, and the type
//! its context gives it. Out: Zig text of type `rt.logic.W`, whose value is
//! what `exec.evalContext` computes for the same expression in the same
//! context. The walk is `evalContext`'s, arm for arm: which operand is
//! context-determined, which self-determined and which takes the common type
//! of a comparison is decided here exactly as there (IEEE 1364-2005 §5.5.1
//! Table 5-22, §5.5.2), and every constant is folded by `evalContext` itself.
//!
//! Clauses: §5.1 operators, §5.2.1 selects, §3.9 array elements, §5.1.14
//! concatenation, §17.7.1 `$time`, §17.11 `$clog2`, §4.2.1.4 casts.
const std = @import("std");
const Ast = @import("frontend").Ast;
const compile = @import("compile.zig");
const exec = @import("exec.zig");
const emit = @import("emit.zig");
const Emitter = emit.Emitter;
const Error = emit.Error;
const Type = compile.Type;

/// The natural type of `e` (§5.5.1).
pub fn natural(self: *Emitter, e: Ast.ExprId) Error!Type {
    return compile.typeOf(self.r, e);
}

/// `exec.eval(e, 0)`: `e` in its own type, a real as its §4.8.2 64-bit
/// integer. Returns that type.
pub fn selfDetermined(self: *Emitter, e: Ast.ExprId) Error!Type {
    var t = try natural(self, e);
    if (t.real) t = .{ .width = 64, .signed = true };
    try value(self, e, t);
    return t;
}

/// `exec.truthOf(e)` as a `logic.Bit` (§9.4): a real is true when not 0.
pub fn truth(self: *Emitter, e: Ast.ExprId) Error!void {
    if ((try natural(self, e)).real) {
        try self.print("L.realTruth(", .{});
        try real(self, e);
        return self.print(")", .{});
    }
    try self.print("L.truth(", .{});
    _ = try selfDetermined(self, e);
    try self.print(")", .{});
}

/// `exec.evalReal(e)`: `e` as a Zig `f64` (§4.8).
pub fn real(self: *Emitter, e: Ast.ExprId) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const n = try natural(self, e);
    if (!n.real) {
        try self.print("L.toReal(", .{});
        const t = try selfDetermined(self, e);
        return self.print(", {d}, {})", .{ t.width, t.signed });
    }
    if (compile.constantExpression(r, e)) {
        const v = exec.evalReal(r, self.arena, e) catch return self.refuse("a constant the engine does not fold");
        return self.print("@as(f64, @bitCast(@as(u64, 0x{x})))", .{@as(u64, @bitCast(v))});
    }
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            try self.print("L.real(", .{});
            try self.get(try self.slot(e));
            try self.print(")", .{});
        },
        .unary => switch (ex.unOp(e)) {
            .minus => {
                try self.print("-(", .{});
                try real(self, ex.lhs(e));
                try self.print(")", .{});
            },
            else => try real(self, ex.lhs(e)), // else: `+`, the only other real-valued unary
        },
        .binary => {
            const op = ex.binOp(e);
            try self.print("{s}", .{if (op == .pow) "std.math.pow(f64, " else "("});
            try real(self, ex.lhs(e));
            try self.print("{s}", .{switch (op) {
                .add => " + ",
                .sub => " - ",
                .mul => " * ",
                .div => " / ",
                else => ", ", // else: `**`, the one other operator infer types real
            }});
            try real(self, ex.rhs(e));
            try self.print(")", .{});
        },
        .ternary => {
            try self.print("L.realCond(", .{});
            try truth(self, ex.lhs(e));
            try self.print(", ", .{});
            try real(self, ex.rhs(e));
            try self.print(", ", .{});
            try real(self, ex.ternaryElse(e));
            try self.print(")", .{});
        },
        .sys_call => {
            const args = ex.args(e);
            const f = r.sys_calls[@intFromEnum(e)].?;
            switch (f) {
                .realtime => {
                    const scale = r.timeOf(r.scope).scale;
                    return self.print("s.realtime(.{{ .local_per_unit = {d}, .global_per_local = {d} }})", .{ scale.local_per_unit, scale.global_per_local });
                },
                .itor => return real(self, args[0]),
                .bitstoreal => {
                    const t = try natural(self, args[0]);
                    try self.print("@as(f64, @bitCast(L.word0(", .{});
                    try value(self, args[0], .{ .width = @max(t.width, 64), .signed = t.signed });
                    return self.print(")))", .{});
                },
                else => {}, // else: the math functions below, or refused there
            }
            const name: []const u8 = switch (f) {
                .ln => "@log",
                .log10 => "@log10",
                .exp => "@exp",
                .sqrt => "@sqrt",
                .floor => "@floor",
                .ceil => "@ceil",
                .sin => "@sin",
                .cos => "@cos",
                .tan => "@tan",
                .asin => "std.math.asin",
                .acos => "std.math.acos",
                .atan => "std.math.atan",
                .sinh => "std.math.sinh",
                .cosh => "std.math.cosh",
                .tanh => "std.math.tanh",
                .asinh => "std.math.asinh",
                .acosh => "std.math.acosh",
                .atanh => "std.math.atanh",
                .pow => "std.math.pow",
                .atan2 => "std.math.atan2",
                .hypot => "std.math.hypot",
                else => return self.refuse("a VAMS real system function"), // else: driver access, which stays with the interpreter
            };
            try self.print("{s}(", .{name});
            if (f == .pow or f == .atan2 or f == .hypot) try self.print("f64, ", .{});
            for (args, 0..) |arg, i| {
                if (i != 0) try self.print(", ", .{});
                try real(self, arg);
            }
            try self.print(")", .{});
        },
        else => return self.refuse("a real expression of this form"), // else: an array element or VAMS branch access
    }
}

/// `exec.evalFor(e, target)` of an integral target: `e` in the context the
/// assignment gives it, truncated to the target (§5.5.3).
pub fn assigned(self: *Emitter, e: Ast.ExprId, target: Type) Error!void {
    if (target.real) return value(self, e, target);
    const n = try natural(self, e);
    const ctx: Type = .{ .width = @max(n.width, target.width), .signed = n.signed };
    try self.print("L.rs(", .{});
    try value(self, e, ctx);
    try self.print(", {d}, {d}, false)", .{ ctx.width, target.width });
}

/// `exec.evalContext(e, ty)`.
pub fn value(self: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const w = ty.width;
    const sg = ty.signed;
    if (compile.constantExpression(r, e)) fold: {
        if (self.two_state) try everyCaseEq(self, e);
        const v = exec.evalContext(r, self.arena, e, ty) catch return self.refuse("a constant the engine does not fold");
        // `--two-state`: a literal's x or z bit is 0; an operator of known
        // operands then computes what 4-state computes wherever that has no
        // x (every operator but `===` is monotone in x, and `===` against
        // an x is refused), so only a constant whose value keeps an x is
        // computed from its 0-valued leaves instead.
        var buf: [3]Ast.ExprId = undefined;
        if (self.two_state and v.hasUnknown() and ex.children(e, &buf).len != 0) break :fold;
        return constant(self, v, w, self.two_state);
    }
    // §4.8: a real context holds the value's bits; a real operand in an
    // integral one is its §4.8.2 integer.
    if (ty.real) {
        try self.print("L.realBits(", .{});
        try real(self, e);
        return self.print(")", .{});
    }
    if ((try natural(self, e)).real) {
        try self.print("L.rs(L.ofReal(", .{});
        try real(self, e);
        return self.print("), 64, {d}, {})", .{ w, sg });
    }
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            const at = try self.slot(e);
            try self.print("L.rs(", .{});
            try self.get(at);
            try self.print(", {d}, {d}, {})", .{ try self.slotWidth(at), w, sg });
        },
        .index => try index(self, e, ty),
        .unary => switch (ex.unOp(e)) {
            .plus => try value(self, ex.lhs(e), ty),
            .minus, .bit_not => |op| {
                try self.print("L.{s}(", .{if (op == .minus) "neg" else "not"});
                try value(self, ex.lhs(e), ty);
                try self.print(", {d})", .{w});
            },
            .logical_not => {
                try self.print("L.ctx(L.invert(", .{});
                try truth(self, ex.lhs(e));
                try self.print("), {d}, {})", .{ w, sg });
            },
            .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => |op| {
                try self.print("L.ctx(L.reduce(.{s}, ", .{switch (op) {
                    .reduce_and => "@\"and\"",
                    .reduce_nand => "nand",
                    .reduce_or => "@\"or\"",
                    .reduce_nor => "nor",
                    .reduce_xor => "xor",
                    else => "xnor", // else: `~^`, the sixth reduction
                }});
                const t = try selfDetermined(self, ex.lhs(e));
                try self.print(", {d}), {d}, {})", .{ t.width, w, sg });
            },
        },
        .binary => {
            const op = ex.binOp(e);
            switch (op) {
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                    if (self.two_state) try twoStateMeaning(self, e);
                    const ot = compile.common(compile.typeOf(r, ex.lhs(e)), compile.typeOf(r, ex.rhs(e)));
                    if (ot.real) {
                        try self.print("L.ctx(if (", .{});
                        try real(self, ex.lhs(e));
                        try self.print(" {s} ", .{switch (op) {
                            .eq => "==",
                            .neq => "!=",
                            .lt => "<",
                            .le => "<=",
                            .gt => ">",
                            .ge => ">=",
                            else => return self.refuse("`===` on a real"), // else: infer refuses `===` on a real
                        }});
                        try real(self, ex.rhs(e));
                        return self.print(") .one else .zero, {d}, {})", .{ w, sg });
                    }
                    const eq = op == .eq or op == .neq or op == .case_eq or op == .case_neq;
                    try self.print("L.ctx(L.{s}(.{s}, ", .{ if (eq) "eq" else "rel", @tagName(op) });
                    try value(self, ex.lhs(e), ot);
                    try self.print(", ", .{});
                    try value(self, ex.rhs(e), ot);
                    if (eq) try self.print(")", .{}) else try self.print(", {d}, {})", .{ ot.width, ot.signed });
                    try self.print(", {d}, {})", .{ w, sg });
                },
                // Both truths are read: with no side effect in either operand
                // the short circuit is not observable, and `logical` of a
                // deciding left side is what the short circuit returns.
                .logical_and, .logical_or => if (calls(self, ex.rhs(e))) {
                    // A call has effects: the right side runs only when
                    // the left does not decide (`exec.evalContext`).
                    const lb = self.label();
                    try self.print("L.ctx(sc{d}: {{ const l{d} = ", .{ lb, lb });
                    try truth(self, ex.lhs(e));
                    try self.print("; if (l{d} == .{s}) break :sc{d} l{d}; break :sc{d} L.logical(.{s}, l{d}, ", .{
                        lb, if (op == .logical_and) "zero" else "one", lb, lb, lb, if (op == .logical_and) "@\"and\"" else "@\"or\"", lb,
                    });
                    try truth(self, ex.rhs(e));
                    try self.print("); }}, {d}, {})", .{ w, sg });
                } else {
                    try self.print("L.ctx(L.logical(.{s}, ", .{if (op == .logical_and) "@\"and\"" else "@\"or\""});
                    try truth(self, ex.lhs(e));
                    try self.print(", ", .{});
                    try truth(self, ex.rhs(e));
                    try self.print("), {d}, {})", .{ w, sg });
                },
                .shl, .shr, .ashl, .ashr => {
                    try self.print("L.shift(.{s}, ", .{switch (op) {
                        .shl => "left",
                        .shr => "right",
                        .ashl => "arithmetic_left",
                        else => "arithmetic_right", // else: `>>>`, the fourth shift
                    }});
                    try value(self, ex.lhs(e), ty);
                    try self.print(", {d}, {}, ", .{ w, sg });
                    _ = try selfDetermined(self, ex.rhs(e));
                    try self.print(")", .{});
                },
                .pow => {
                    try self.print("L.pow(", .{});
                    try value(self, ex.lhs(e), ty);
                    try self.print(", {d}, {}, ", .{ w, sg });
                    const t = try selfDetermined(self, ex.rhs(e));
                    try self.print(", {d}, {})", .{ t.width, t.signed });
                },
                .add, .sub, .mul, .div, .mod => {
                    try self.print("L.arith(.{s}, ", .{@tagName(op)});
                    try value(self, ex.lhs(e), ty);
                    try self.print(", ", .{});
                    try value(self, ex.rhs(e), ty);
                    try self.print(", {d}, {})", .{ w, sg });
                },
                .bit_and, .bit_or, .bit_xor, .bit_xnor => {
                    try self.print("L.bitwise(.{s}, ", .{switch (op) {
                        .bit_and => "@\"and\"",
                        .bit_or => "@\"or\"",
                        .bit_xor => "xor",
                        else => "xnor", // else: `~^`, the fourth bitwise operator
                    }});
                    try value(self, ex.lhs(e), ty);
                    try self.print(", ", .{});
                    try value(self, ex.rhs(e), ty);
                    try self.print(", {d})", .{w});
                },
            }
        },
        // §5.1.13: both arms are read; `cond` keeps the one the truth picks,
        // or merges them under an x or z condition.
        .ternary => if (calls(self, ex.rhs(e)) or calls(self, ex.ternaryElse(e))) {
            // A call has effects: a known condition runs one arm.
            const lb = self.label();
            try self.print("t{d}: {{ const c{d} = ", .{ lb, lb });
            try truth(self, ex.lhs(e));
            try self.print("; break :t{d} if (c{d} == .one) ", .{ lb, lb });
            try value(self, ex.rhs(e), ty);
            try self.print(" else if (c{d} == .zero) ", .{lb});
            try value(self, ex.ternaryElse(e), ty);
            try self.print(" else L.cond(c{d}, ", .{lb});
            try value(self, ex.rhs(e), ty);
            try self.print(", ", .{});
            try value(self, ex.ternaryElse(e), ty);
            try self.print("); }}", .{});
        } else {
            try self.print("L.cond(", .{});
            try truth(self, ex.lhs(e));
            try self.print(", ", .{});
            try value(self, ex.rhs(e), ty);
            try self.print(", ", .{});
            try value(self, ex.ternaryElse(e), ty);
            try self.print(")", .{});
        },
        .sys_call => {
            const args = ex.args(e);
            switch (r.sys_calls[@intFromEnum(e)].?) {
                .make_signed, .make_unsigned => {
                    try self.print("L.rs(", .{});
                    const t = try selfDetermined(self, args[0]);
                    try self.print(", {d}, {d}, {})", .{ t.width, w, sg });
                },
                .time, .stime => |f| {
                    const n = compile.typeOf(r, e);
                    const scale = r.timeOf(r.scope).scale;
                    try self.print("L.rs(L.k(s.units(.{{ .local_per_unit = {d}, .global_per_local = {d} }}){s}, 0), {d}, {d}, {})", .{
                        scale.local_per_unit, scale.global_per_local, if (f == .stime) " & 0xffffffff" else "", n.width, w, sg,
                    });
                },
                // §17.10: `vera` takes no plusargs, so every query is "no
                // match" — an integer zero, the variable left alone.
                .test_plusargs, .value_plusargs => try self.print("L.rs(L.k(0, 0), 32, {d}, {})", .{ w, sg }),
                // §17.8: `$rtoi` truncates, `$realtobits` is the 64 bits.
                .rtoi => {
                    try self.print("L.rs(L.rtoi(", .{});
                    try real(self, args[0]);
                    try self.print("), 32, {d}, {})", .{ w, sg });
                },
                .realtobits => {
                    try self.print("L.rs(L.realBits(", .{});
                    try real(self, args[0]);
                    try self.print("), 64, {d}, {})", .{ w, sg });
                },
                // §17.6.5, which also writes its status argument.
                .q_full => {
                    const lb = self.label();
                    try self.print("L.rs(qf{d}: {{\n            const f{d} = s.queueFull(", .{ lb, lb });
                    try emit.int64(self, args[0]);
                    try self.print(");\n", .{});
                    try emit.assignInt(self, args[1], try std.fmt.allocPrint(self.arena, "f{d}.status", .{lb}));
                    try self.print("            break :qf{d} L.k(@bitCast(f{d}.full), 0);\n            }}, 64, {d}, {})", .{ lb, lb, w, sg });
                },
                // §17.2 on the executable's descriptor table.
                .fopen => {
                    try self.print("L.rs(L.k(@as(u32, @truncate(@as(u64, @bitCast(try s.fopen(\"{f}\", ", .{std.zig.fmtString(r.file_name)});
                    const n = try selfDetermined(self, args[0]);
                    try self.print(", {d}, ", .{n.width});
                    if (args.len == 1) try self.print("null, 0", .{}) else {
                        const m = try selfDetermined(self, args[1]);
                        try self.print(", {d}", .{m.width});
                    }
                    try self.print("))))), 0), 32, {d}, {})", .{ w, sg });
                },
                .fgetc, .ungetc, .ftell, .fseek, .rewind, .feof => |f| {
                    try self.print("L.rs(L.k(@as(u32, @truncate(@as(u64, @bitCast(s.fileOp(.{t}", .{f});
                    for (0..3) |i| {
                        try self.print(", ", .{});
                        if (i < args.len) try emit.int64(self, args[i]) else try self.print("null", .{});
                    }
                    try self.print("))))), 0), 32, {d}, {})", .{ w, sg });
                },
                // §17.2.4.3: each output argument as the scan reaches it.
                .sscanf => {
                    if (self.two_state) return self.refuse("`$sscanf`, which answers EOF for an x or z in its input or format");
                    const lb = self.label();
                    try self.print("L.rs(sc{d}: {{\n            var c{d} = try s.scan(", .{ lb, lb });
                    const in = try selfDetermined(self, args[0]);
                    try self.print(", {d}, ", .{in.width});
                    const fm = try selfDetermined(self, args[1]);
                    try self.print(", {d}, {d});\n", .{ fm.width, args.len - 2 });
                    try self.print("            while (c{d}.next()) |x{d}| switch (x{d}.arg) {{\n", .{ lb, lb, lb });
                    for (args[2..], 0..) |arg, k| {
                        try self.print("            {d} => switch (x{d}.value) {{\n            .int => |v{d}| {{\n", .{ k, lb, lb });
                        try emit.assignInt(self, arg, try std.fmt.allocPrint(self.arena, "v{d}", .{lb}));
                        try self.print("            }},\n            .chars => |t{d}| {{\n", .{lb});
                        try emit.assignChars(self, arg, try std.fmt.allocPrint(self.arena, "t{d}", .{lb}));
                        try self.print("            }},\n            }},\n", .{});
                    }
                    try self.print("            else => unreachable,\n            }};\n", .{});
                    try self.print("            break :sc{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(c{d}.result)))), 0);\n            }}, 32, {d}, {})", .{ lb, lb, w, sg });
                },
                // §17.9, which writes its seed argument back.
                .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => |f| {
                    if (args.len == 0) return self.print("L.rs(L.k(@as(u32, @bitCast(s.random())), 0), 32, {d}, {})", .{ w, sg });
                    const lb = self.label();
                    try self.print("L.rs(rd{d}: {{\n            const d{d} = s.dist(.{t}", .{ lb, lb, f.dist().? });
                    for (0..3) |i| {
                        if (i >= args.len) {
                            try self.print(", 0", .{});
                            continue;
                        }
                        try self.print(", @as(i32, @truncate(", .{});
                        try emit.int64(self, args[i]);
                        try self.print(" orelse 0))", .{});
                    }
                    try self.print(");\n            if (d{d}) |g{d}| {{\n", .{ lb, lb });
                    try emit.assignInt(self, args[0], try std.fmt.allocPrint(self.arena, "g{d}.seed", .{lb}));
                    try self.print("            }}\n            break :rd{d} L.k(@as(u32, @bitCast(if (d{d}) |g{d}| g{d}.value else 0)), 0);\n            }}, 32, {d}, {})", .{ lb, lb, lb, lb, w, sg });
                },
                .clog2 => {
                    try self.print("L.rs(L.k(L.clog2(", .{});
                    const t = try selfDetermined(self, args[0]);
                    try self.print(", {d}), 0), 32, {d}, {})", .{ t.width, w, sg });
                },
                else => return self.refuse("a VAMS driver or real system function"), // else: driver access stays with the interpreter; a real function is `real`'s
            }
        },
        .concat => {
            // §5.1.14: self-determined operands, leftmost most significant;
            // a zero replication contributes no bits.
            var parts: std.ArrayList(Ast.ExprId) = .empty;
            for (ex.args(e)) |arg| if (compile.typeOf(r, arg).width != 0) try parts.append(self.arena, arg);
            const n = try natural(self, e);
            try self.print("L.rs(", .{});
            for (parts.items[1..]) |_| try self.print("L.join(", .{});
            var acc = (try selfDetermined(self, parts.items[0])).width;
            for (parts.items[1..]) |arg| {
                try self.print(", {d}, ", .{acc});
                const t = try selfDetermined(self, arg);
                try self.print(", {d})", .{t.width});
                acc += t.width;
            }
            try self.print(", {d}, {d}, {})", .{ n.width, w, sg });
        },
        .multi_concat => {
            const n = try natural(self, e);
            const count = r.replications.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
            try self.print("L.rs(L.rep(", .{});
            const t = try selfDetermined(self, ex.rhs(e));
            try self.print(", {d}, {d}), {d}, {d}, {})", .{ t.width, count, n.width, w, sg });
        },
        // §10.4 a function call: one synchronous activation (`exec.callSync`).
        .call => {
            const idx = r.sub_base.get(r.instanceOf(r.scope)).? + r.call_subs.get(e).?;
            const f = r.subs.items[idx].frame;
            const lb = self.label();
            try self.print("L.rs(c{d}: {{\n", .{lb});
            try emit.call(self, idx, ex.args(e), lb);
            try self.print("            break :c{d} r{d};\n            }}, {d}, {d}, {})", .{ lb, lb, r.values[f.result].width, w, sg });
        },
        else => return self.refuse("this expression form"), // else: every other form infer admits is a constant (folded above) or real (`real`)
    }
}

/// Does `e` call a function, or a system function that may have an effect?
fn calls(self: *Emitter, e: Ast.ExprId) bool {
    const ex = &self.r.file.exprs;
    if (ex.tag(e) == .call) return true;
    // A system function that is not constant may write (`$random`'s seed,
    // a file position) or reads the clock, which is harmless to count.
    if (ex.tag(e) == .sys_call) if (self.r.sys_calls[@intFromEnum(e)]) |f| if (!f.constant()) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (c != .none and calls(self, c)) return true;
    return false;
}

/// A folded constant; `known` makes its x and z bits 0 (`--two-state`).
fn constant(self: *Emitter, v: @import("frontend").Integer.Literal, w: u32, known: bool) Error!void {
    const n = emit.words(w);
    const vs = v.values()[0..n];
    const xs = v.unknowns()[0..n];
    if (w <= 64) return self.print("L.k(0x{x}, 0x{x})", .{ if (known) vs[0] & ~xs[0] else vs[0], if (known) 0 else xs[0] });
    try self.print("L.Wide({d}){{ .v = .{{", .{n});
    for (vs, xs) |x, u| try self.print(" 0x{x},", .{if (known) x & ~u else x});
    try self.print(" }}, .x = .{{", .{});
    for (xs) |x| try self.print(" 0x{x},", .{if (known) 0 else x});
    return self.print(" }} }}", .{});
}

/// A `case` label in the scrutinee's type (§9.5). Under `--two-state` a
/// casez/casex label keeps its z (and x) bits, which are wildcards there
/// (§9.5.1), and a `case` label with one is refused: it matches only an x
/// or z, which a two-state run never holds.
pub fn caseLabel(self: *Emitter, e: Ast.ExprId, ty: Type, kind: Ast.CaseKind) Error!void {
    if (!self.two_state or !compile.constantExpression(self.r, e)) return value(self, e, ty);
    try self.fits(ty);
    const v = exec.evalContext(self.r, self.arena, e, ty) catch return self.refuse("a constant the engine does not fold");
    if (kind == .normal and v.hasUnknown()) return self.refuse("a `case` label with an x or z bit, which only an x or z matches");
    return constant(self, v, ty.width, false);
}

fn everyCaseEq(self: *Emitter, e: Ast.ExprId) Error!void {
    var buf: [3]Ast.ExprId = undefined;
    for (self.r.file.exprs.children(e, &buf)) |c| if (c != .none) try everyCaseEq(self, c);
    try twoStateMeaning(self, e);
}

/// Refuse, under `--two-state`, a `===` or `!==` with an operand that
/// holds x or z: it asks whether a value is unknown (§5.1.8), which a
/// two-state run cannot answer.
fn twoStateMeaning(self: *Emitter, e: Ast.ExprId) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    if (ex.tag(e) != .binary) return;
    const op = ex.binOp(e);
    if (op != .case_eq and op != .case_neq) return;
    for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |side| {
        if (!compile.constantExpression(r, side)) continue;
        const v = exec.eval(r, self.arena, side, 0) catch return self.refuse("a constant the engine does not fold");
        if (v.hasUnknown()) return self.refuse("`===` or `!==` against an x or z, which asks whether a value is unknown");
    }
}

/// §3.9 an array element, or §5.2.1 a bit- or part-select of a vector.
fn index(self: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const w = ty.width;
    const sg = ty.signed;
    const n = compile.typeOf(r, e);
    if (try self.element(e)) {
        // An out-of-range or x/z address reads x of the element's type.
        const lb = self.label();
        try self.print("L.rs(if (", .{});
        try address(self, e, lb);
        const base = try self.slot(r.chainBase(e).base);
        const nw = emit.words(n.width);
        const at = .{ self.off[base], lb, base, nw };
        if (nw == 1)
            try self.print(") |a{d}| s.get({d} + (a{d} - {d}) * {d})", .{lb} ++ at)
        else
            try self.print(") |a{d}| s.getw({d} + (a{d} - {d}) * {d}, {d})", .{lb} ++ at ++ .{nw});
        return self.print(" else L.xs({d}), {d}, {d}, {})", .{ n.width, n.width, w, sg });
    }
    const at = try self.slot(ex.lhs(e));
    const sw = try self.slotWidth(at);
    const range = vecRange(r, at, sw);
    const rg = ex.rhs(e);
    if (ex.tag(rg) == .range) {
        const p = try partPlace(self, e, range);
        try self.print("L.rs(L.part(", .{});
        try self.get(at);
        try self.print(", {d}, {d}, {d}), {d}, {d}, {})", .{ p.shift, p.count, sw, n.width, w, sg });
        return;
    }
    try self.print("L.rs(L.bitAt(", .{});
    try self.get(at);
    try self.print(", L.asInt(", .{});
    const t = try selfDetermined(self, rg);
    try self.print(", {d}, {}), {d}, {d}, {d}), 1, {d}, {})", .{ t.width, t.signed, range.msb, range.lsb, sw, w, sg });
}

/// `exec.address` as a Zig `?u32`: the element's slot, or null. `label`
/// (from `Emitter.label`) names its block and locals.
pub fn address(self: *Emitter, e: Ast.ExprId, label: u32) Error!void {
    const r = self.r;
    const ex = &r.file.exprs;
    const c = r.chainBase(e);
    const base = try self.slot(c.base);
    const arr = r.arrays.get(base).?;
    try self.print("b{d}: {{", .{label});
    // §4.9 row-major: the innermost select is the last dimension.
    var selects: std.ArrayList(Ast.ExprId) = .empty;
    var x = e;
    while (ex.tag(x) == .index) : (x = ex.lhs(x)) try selects.insert(self.arena, 0, ex.rhs(x));
    try self.print(" var o{d}: u64 = 0;", .{label});
    for (selects.items, 0..) |sel, d| {
        const span: @import("root.zig").Span = if (d == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[d - 1];
        try self.print(" const i{d}_{d} = L.asInt(", .{ label, d });
        const t = try selfDetermined(self, sel);
        try self.print(", {d}, {}) orelse break :b{d} null;", .{ t.width, t.signed, label });
        try self.print(" if (i{d}_{d} < {d} or i{d}_{d} > {d}) break :b{d} null;", .{ label, d, span.low, label, d, span.high, label });
        try self.print(" o{d} = o{d} * {d} + @as(u64, @intCast(i{d}_{d} - {d}));", .{ label, label, span.high - span.low + 1, label, d, span.low });
    }
    try self.print(" break :b{d} @as(?u32, {d} + @as(u32, @intCast(o{d}))); }}", .{ label, base, label });
}

pub const VecRange = @import("root.zig").VecRange;

/// A slot's declared `[msb:lsb]`, `[w-1:0]` when it declares none.
pub fn vecRange(r: anytype, at: u32, width: u32) VecRange {
    return r.vec_ranges.get(at) orelse .{ .msb = @as(i64, width) - 1, .lsb = 0 };
}

/// A constant part-select as a shift: select bit i is slot bit `i + shift`
/// where the slot has that bit, and names no bit elsewhere (§5.2.1).
pub const Place = struct { shift: i64, count: u32 };

pub fn partPlace(self: *Emitter, e: Ast.ExprId, range: VecRange) Error!Place {
    const r = self.r;
    const b = r.part_selects.get(.{ .spec = r.specOf(r.scope), .e = e }).?;
    const count: u32 = @intCast(@abs(b.msb - b.lsb) + 1);
    const step: i64 = if (b.msb >= b.lsb) 1 else -1;
    const up = range.msb >= range.lsb;
    // `exec.position` of declared index `lsb + i*step` is `p0 + i*d`.
    const d: i64 = if (up) step else -step;
    if (d != 1 and count > 1) return self.refuse("a part-select against its vector's direction");
    const p0: i64 = if (up) b.lsb - range.lsb else range.lsb - b.lsb;
    return .{ .shift = p0, .count = count };
}

pub fn maskOf(w: u32) u64 {
    return if (w >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
}
