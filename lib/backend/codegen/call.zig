//! Calls: §4.5 analog operators, §4.6 noise, Clause 9 system functions.
//!
//! In: a MIR `call`. Out: the kernel call text, the operator's state slots, and the noise and
//! system-function tables codegen exports.
//!
//! LRM clauses this file's code cites: §1, §4.5, §4.5.7, §4.5.8, §4.6.1, §5.10.3.1, §5.10.3.2, §5.10.3.3, §6.3.4, §9.5, §9.5.1, §9.15.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_call.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_file = @import("file.zig");
const gen_cfg = @import("cfg.zig");
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const cg_display = @import("../cg_display.zig");
const cg_filters = @import("../cg_filters.zig");
const Lower = @import("ir").Lower;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const array_index_types = codegen.array_index_types;
const mathOpByName = codegen.mathOpByName;
const isAnalysisName = codegen.isAnalysisName;
const devSafe = codegen.devSafe;
const OpKind = codegen.OpKind;
const opKind = codegen.opKind;
const opNeedsInput = codegen.opNeedsInput;
const enableArgIdx = codegen.enableArgIdx;

// =======================================================================
// Calls: §4.5 analog operators, §4.6 noise, ch9 system functions
// =======================================================================

/// Reuse the optimizer's select or reconstruct a pure two-way CFG merge.
/// Loop-carried/multiway phis and arms with calls remain unsupported here.
pub fn hostConditional(self: *const Gen, inst: Mir.Inst) ?Mir.InstData {
    if (self.mir.instOp(inst) == .select) return self.mir.instData(inst);
    if (self.mir.instOp(inst) != .phi or self.mir.instData(inst).phi.count != 2) return null;
    const join = self.an.def_block[@intFromEnum(self.mir.instResult(inst))];
    if (join == none_u32) return null;
    const header = self.an.idom[join];
    if (header == none_u32 or header == join) return null;
    // SSA may append a phi after the terminator; Analysis already records
    // the actual branch independently of its position in the chain.
    const last = self.an.term[header];
    if (last == .none or self.mir.instOp(last) != .branch) return null;
    const branch = self.mir.instData(last).branch;
    var arms: [2]Mir.Value = undefined;
    inline for (.{ branch.then_block, branch.else_block }, 0..) |arm, i| {
        var found = false;
        for (0..2) |k| {
            const pair = self.mir.phiPair(inst, @intCast(k));
            const matches = if (@intFromEnum(arm) == join)
                @intFromEnum(pair.block) == header
            else
                self.an.dominates(@intFromEnum(arm), @intFromEnum(pair.block));
            if (matches) {
                if (found) return null;
                arms[i] = pair.value;
                found = true;
            }
        }
        if (!found) return null;
    }
    // Value-only rendering must not lose calls or effects from an arm.
    for (0..self.an.nb) |bi| {
        const block_index: u32 = @intCast(bi);
        if (block_index == header or !self.an.dominates(header, block_index) or self.an.dominates(join, block_index)) continue;
        for (self.an.blockInstsFlat(block_index)) |op|
            if (self.mir.instOp(op) == .call) return null;
    }
    return .{ .ternary = .{ .cond = branch.cond, .then_val = arms[0], .else_val = arms[1] } };
}

pub fn hostConditionalExpr(self: *Gen, inst: Mir.Inst, depth: u32, ty: VTy) Error!?[]const u8 {
    const d = (hostConditional(self, inst) orelse return null).ternary;
    const condition = try i64Const(self, d.cond, depth + 1) orelse return null;
    const yes = (if (ty == .int) try i64Const(self, d.then_val, depth + 1) else try f64Const(self, d.then_val, depth + 1, false)) orelse return null;
    const no = (if (ty == .int) try i64Const(self, d.else_val, depth + 1) else try f64Const(self, d.else_val, depth + 1, false)) orelse return null;
    return try std.fmt.allocPrint(self.arena, "@as({s}, if (({s}) != 0) ({s}) else ({s}))", .{ if (ty == .int) "i64" else "f64", condition, yes, no });
}

/// Parameter derivation must preserve integral bits, including values beyond
/// f64's exact range. Integer operators retain the analog MIR's existing
/// 32-bit arithmetic rules; full expression sizing remains separate work.
/// A host-side `[]const u8` for a STRING operand: the literal, or the model
/// field a §3.4.6 string parameter occupies. Null for anything else, which
/// is how `i64Const` tells a string comparison from arithmetic.
pub fn strConst(self: *Gen, v0: Mir.Value) Error!?[]const u8 {
    switch (self.mir.valueDef(self.an.rv(v0))) {
        .str_const => |s| return try std.fmt.allocPrint(self.arena, "\"{f}\"", .{std.zig.fmtString(s)}),
        .param_ref => |p| {
            if (Analysis.tyOfParam(self.lower.params.items[p].ty) != .str) return null;
            self.uses_model = true;
            return try std.fmt.allocPrint(self.arena, "model.{s}", .{self.p_names[p]});
        },
        else => return null,
    }
}

pub fn i64Const(self: *Gen, v0: Mir.Value, depth: u32) Error!?[]const u8 {
    if (depth > 32) return null;
    const v = self.an.rv(v0);
    switch (self.mir.valueDef(v)) {
        .int_const => |n| return try std.fmt.allocPrint(self.arena, "@as(i64, {d})", .{n}),
        .float_const => |n| return try std.fmt.allocPrint(self.arena, "@as(i64, {d})", .{std.math.lossyCast(i64, @round(n))}),
        .param_ref => |p| {
            if (Analysis.tyOfParam(self.lower.params.items[p].ty) == .str) return null;
            self.uses_model = true;
            return switch (Analysis.tyOfParam(self.lower.params.items[p].ty)) {
                .int => try std.fmt.allocPrint(self.arena, "model.{s}", .{self.p_names[p]}),
                .real => try std.fmt.allocPrint(self.arena, "std.math.lossyCast(i64, @round(model.{s}))", .{self.p_names[p]}),
                .str => unreachable,
            };
        },
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            const av: Mir.Value = @enumFromInt(row.a);
            const bv: Mir.Value = @enumFromInt(row.b);
            if (self.an.tyOf(v) == .real or row.op == .fi_cast) {
                const f = try f64Const(self, if (row.op == .fi_cast) av else v, depth + 1, false) orelse return null;
                return try std.fmt.allocPrint(self.arena, "std.math.lossyCast(i64, @round({s}))", .{f});
            }
            if (row.op == .select or row.op == .phi) return hostConditionalExpr(self, inst, depth, .int);
            if (row.op == .feq or row.op == .fne or row.op == .flt or row.op == .fle or row.op == .fgt or row.op == .fge) {
                const a = try f64Const(self, av, depth + 1, false) orelse return null;
                const rhs = try f64Const(self, bv, depth + 1, false) orelse return null;
                const op = switch (row.op) {
                    .feq => "==",
                    .fne => "!=",
                    .flt => "<",
                    .fle => "<=",
                    .fgt => ">",
                    .fge => ">=",
                    else => unreachable,
                };
                return try std.fmt.allocPrint(self.arena, "@as(i64, @intFromBool(({s}) {s} ({s})))", .{ a, op, rhs });
            }
            if (Mir.opClass(row.op) != .unary and Mir.opClass(row.op) != .binary) return null;
            // Table 3-3's relational row over two strings — "Result is 1 if
            // they are equal and 0 if they are not", the rest by
            // "lexicographical ordering". §3.4.6's own `ebersmoll` example
            // writes exactly this in a parameter default
            // (`sign = (transistortype == "NPN") ? 1.0 : -1.0`), so §6.3.4
            // has to be able to redo it after a card write. `lowerBinary`
            // ran `strNum` over any MIXED pair, so a string reaching here is
            // one of two. Mirrors `foldStrBinary`, operator for operator.
            if (try strConst(self, av)) |sa| if (try strConst(self, bv)) |sb| {
                const so: []const u8 = switch (row.op) {
                    .ieq => "== .eq",
                    .ine => "!= .eq",
                    .ilt => "== .lt",
                    .ile => "!= .gt",
                    .igt => "== .gt",
                    .ige => "!= .lt",
                    else => return null,
                };
                return try std.fmt.allocPrint(self.arena, "@as(i64, @intFromBool(std.mem.order(u8, {s}, {s}) {s}))", .{ sa, sb, so });
            };
            const a = try i64Const(self, av, depth + 1) orelse return null;
            if (Mir.opClass(row.op) == .unary) return switch (row.op) {
                .opt_barrier => a,
                .ineg => try std.fmt.allocPrint(self.arena, "@as(i64, @as(i32, @truncate(-%({s}))))", .{a}),
                .iabs => try std.fmt.allocPrint(self.arena, "zIabs({s})", .{a}),
                .bitnot => try std.fmt.allocPrint(self.arena, "~({s})", .{a}),
                .lognot => try std.fmt.allocPrint(self.arena, "@as(i64, @intFromBool(({s}) == 0))", .{a}),
                else => null,
            };
            const rhs = try i64Const(self, bv, depth + 1) orelse return null;
            const op: []const u8 = switch (row.op) {
                .iadd => "+%",
                .isub => "-%",
                .imul => "*%",
                .bitand => "&",
                .bitor => "|",
                .bitxor, .bitxnor => "^",
                .ieq => "==",
                .ine => "!=",
                .ilt => "<",
                .ile => "<=",
                .igt => ">",
                .ige => ">=",
                else => "",
            };
            return switch (row.op) {
                .iadd, .isub, .imul => try std.fmt.allocPrint(self.arena, "@as(i64, @as(i32, @truncate(({s}) {s} ({s}))))", .{ a, op, rhs }),
                .bitand, .bitor, .bitxor => try std.fmt.allocPrint(self.arena, "(({s}) {s} ({s}))", .{ a, op, rhs }),
                .bitxnor => try std.fmt.allocPrint(self.arena, "~(({s}) ^ ({s}))", .{ a, rhs }),
                .ieq, .ine, .ilt, .ile, .igt, .ige => try std.fmt.allocPrint(self.arena, "@as(i64, @intFromBool(({s}) {s} ({s})))", .{ a, op, rhs }),
                // The quotient can reach +2^63 for minInt(i64)/-1;
                // i65 holds that intermediate before the MIR's wrap32.
                .idiv => try std.fmt.allocPrint(self.arena, "(if (({s}) == 0) @panic(\"VerA: zero divisor in integer parameter derivation is not implemented\") else @as(i64, @as(i32, @truncate(@divTrunc(@as(i65, {s}), @as(i65, {s}))))))", .{ rhs, a, rhs }),
                .imod => try std.fmt.allocPrint(self.arena, "(if (({s}) == 0) @panic(\"VerA: zero divisor in integer parameter derivation is not implemented\") else @as(i64, @intCast(@rem(@as(i65, {s}), @as(i65, {s})))))", .{ rhs, a, rhs }),
                .logand, .logor => try std.fmt.allocPrint(self.arena, "@as(i64, @intFromBool((({s}) != 0) {s} (({s}) != 0)))", .{ a, if (row.op == .logand) "and" else "or", rhs }),
                .shl => try std.fmt.allocPrint(self.arena, "@as(i64, @as(i32, @truncate(zShl({s}, {s}))))", .{ a, rhs }),
                .shr => try std.fmt.allocPrint(self.arena, "zShr({s}, {s})", .{ a, rhs }),
                .imin, .imax => try std.fmt.allocPrint(self.arena, "@as(i64, {s}({s}, {s}))", .{ if (row.op == .imin) "@min" else "@max", a, rhs }),
                // `Lower.ipow32` as device text; its 'bx corner reads 0 here
                // exactly as it does in `renderOp`.
                .ipow => try std.fmt.allocPrint(self.arena, "{s}({s}, {s})", .{ gen_render.ipow_fn, a, rhs }),
                // Real-valued binaries: `tyOf(v) == .real` and the float
                // comparisons both returned above.
                .fadd, .fsub, .fmul, .fdiv, .fmod, .flt, .fgt, .fle, .fge, .feq, .fne, .pow, .hypot, .fmin, .fmax, .atan2 => null,
                // The `.unary` return and the opClass filter above keep every
                // other class out.
                .fneg,
                .ineg,
                .lognot,
                .bitnot,
                .sqrt,
                .exp,
                .expm1,
                .ln,
                .ln1p,
                .log10,
                .floor,
                .ceil,
                .fabs,
                .iabs,
                .sin,
                .cos,
                .tan,
                .asin,
                .acos,
                .atan,
                .sinh,
                .cosh,
                .tanh,
                .asinh,
                .acosh,
                .atanh,
                .fi_cast,
                .if_cast,
                .opt_barrier,
                .path_prev,
                .path_acc,
                .select,
                .phi,
                .branch,
                .jump,
                .call,
                => unreachable,
            };
        },
        else => return null,
    }
}

/// A plain-f64 expression for an operator CONTROL argument (delay,
/// transition time, initial condition, …), or null when the argument is not
/// one the host can evaluate outside the S domain.
///
/// The `Model` struct IS the parameter set, so a control argument that is an
/// arithmetic expression over parameters is just that expression with
/// `model.<p>` leaves — `td = len * sqrt(l * c)` renders as
/// `model.len * @sqrt(model.l * model.c)`. Real models write the delay of a
/// transmission line that way (lossy_tline.va:135, coupled_tlines.va:110),
/// and §4.5.7 permits it: `absdelay(input, td [, maxdelay])` gives td as an
/// `analog_expression`, and with no `maxdelay` "the value of td when the
/// absdelay() is first evaluated shall be used and any future changes to td
/// shall be ignored" — which for a parameter expression is every evaluation.
///
/// `foldConst` first at EVERY node, so a subtree of literals still comes out
/// as one folded number rather than as rendered arithmetic.
//
// ponytail: the op set is arithmetic, min/max, and the whole of Table 4-14
// and Table 4-15 — every scalar math operator, because §6.3.4 puts no
// restriction on which ones a dependent parameter's default may use and a
// missing case must be diagnosed there, rather than freezing the field at
// its declared value after a host write. Pure two-way conditionals render
// as lazy Zig if expressions; arbitrary control flow remains unsupported.
// Ceiling: unlike `foldConst` this never looks through a parameter's
// DEFAULT, because the host overrides parameters at run time.
//
// ponytail: loop-carried and multiway phis are not expression fragments.
// Supporting them needs execution of the constant-function CFG; the
// two-way renderer deliberately does not guess their values.
///
/// `in_unit` says the expression lands in a UNIT BODY rather than in a
/// host-side `derive` line or `updateState`, and that changes two things.
///
/// It may name a unit-local temporary — it must, in fact: without that a
/// shared chain of parameter arithmetic re-renders its whole prefix at
/// every link, which is quadratic in the chain length and BSIM4's
/// temperature prep is hundreds of links long.
///
/// And it is restricted to `devSafe` opcodes, because a unit body also
/// compiles for nvptx, where there is no libm: `@exp`/`@log` on an f64
/// become "no libcall available for fexp" at PTX assembly time. Those stay
/// S operations, whose implementation is the host's problem and not this
/// generator's — which is the same division of labour the whole S protocol
/// rests on.
pub fn f64Const(self: *Gen, v0: Mir.Value, depth: u32, in_unit: bool) Error!?[]const u8 {
    if (depth > 32) return null;
    const v = self.an.rv(v0);
    if (in_unit) {
        // Already materialised: NAME it, and never fold past it.
        //
        // `unit_plan` decided this slot was live by walking the MIR, and no
        // rendering choice here can revise that — fold past it and the
        // declaration it already emitted has no reader, which Zig rejects
        // outright ("unused local constant"). Naming it is also the cheaper
        // answer: the temporary holds a dual whose derivative half is a
        // structural zero, so reading the value out beats recomputing the
        // subtree. `depth > 0` because at depth 0 the caller IS this slot's
        // own declaration.
        if (depth > 0 and self.an.dFree(v)) {
            const i = @intFromEnum(v);
            // A precompute field IS the plain f64 — no `.val()` needed.
            if (i < self.an.nv and self.plan.pcHoisted(v)) {
                self.uses_inst = true;
                return try std.fmt.allocPrint(self.arena, "inst.pc__{d}", .{self.pc_idx[i]});
            }
            if (i < self.an.nv and self.plan.cached(v))
                return try std.fmt.allocPrint(self.arena, "c.f{d}.val()", .{self.lo_idx[i]});
            if (i < self.an.nv and self.plan.slot[i] != none_u32) {
                gen_unit.probeUse(self, self.plan.slot[i]);
                return try std.fmt.allocPrint(self.arena, "{s}.val()", .{try gen_unit.slotRefStr(self, i)});
            }
        }
        // Folding a whole literal chain to one number is still the right
        // answer where it is available — `foldConst` works in f64, so the
        // number it lands on is the one the hardware would have — but it
        // takes the subtree in ONE step and cannot see the check above.
        // So ask first whether it would swallow a slot.
        if (!gen_render.foldHidesSlot(self, v, 0)) {
            if (self.an.foldConst(v, 0, false)) |k| return try gen_file.fmtF64(self, k.f);
        }
    } else {
        // A real parameter may depend on integer arithmetic. Evaluate that
        // subtree at its integer width before converting its final value.
        if (self.an.tyOf(v) == .int) {
            const integer = try i64Const(self, v, depth + 1) orelse return null;
            return try std.fmt.allocPrint(self.arena, "@as(f64, @floatFromInt({s}))", .{integer});
        }
        if (self.an.foldConst(v0, 0, false)) |k| return try gen_file.fmtF64(self, k.f);
    }
    switch (self.mir.valueDef(v)) {
        .param_ref => |p| {
            self.uses_model = true;
            return switch (Analysis.tyOfParam(self.lower.params.items[p].ty)) {
                .real => try std.fmt.allocPrint(self.arena, "model.{s}", .{self.p_names[p]}),
                .int => try std.fmt.allocPrint(self.arena, "@as(f64, @floatFromInt(model.{s}))", .{self.p_names[p]}),
                .str => "0.0",
            };
        },
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            if (in_unit and !devSafe(row.op)) return null;
            if (!in_unit and (row.op == .select or row.op == .phi)) return hostConditionalExpr(self, inst, depth, .real);
            // §9.15 a host-published `$simparam` IS a Model field, so a
            // §3.4 parameter default written over it renders here and
            // `emitDerive` picks it up. Without this the default folded to
            // nothing, `paramDefault` wrote 0 and W1050 fired.
            if (row.op == .call) {
                const d = self.mir.instData(inst).call;
                if (!std.mem.eql(u8, d.name, "$simparam")) return null;
                const f = Lower.simparamHostField(strArg(self, d.args, 0) orelse "") orelse return null;
                self.uses_model = true;
                return try std.fmt.allocPrint(self.arena, "model.{s}", .{f});
            }
            switch (Mir.opClass(row.op)) {
                // Rendered as open/close (and separator) fragments rather
                // than as a format string per opcode: `allocPrint` wants a
                // comptime format, and a `{s}`-per-case switch would be the
                // same table written twice as long.
                .unary => {
                    const a = try f64Const(self, @enumFromInt(row.a), depth + 1, in_unit) orelse return null;
                    const fix: [2][]const u8 = switch (row.op) {
                        .fneg, .ineg => .{ "-(", ")" },
                        .fabs, .iabs => .{ "@abs(", ")" },
                        .sqrt => .{ "@sqrt(", ")" },
                        // §4.3.1 Table 4-14 and §4.3.2 Table 4-15 in full.
                        // Every one is a pure f64→f64 function of a value
                        // the host already has, so a §6.3.4 default over one
                        // derives exactly as an arithmetic default does —
                        // the clause puts no operator restriction on a
                        // dependent parameter, so neither does this.
                        .exp => .{ "@exp(", ")" },
                        .ln => .{ "@log(", ")" },
                        .log10 => .{ "@log10(", ")" },
                        .expm1 => .{ "std.math.expm1(", ")" },
                        .ln1p => .{ "std.math.log1p(", ")" },
                        .floor => .{ "@floor(", ")" },
                        .ceil => .{ "@ceil(", ")" },
                        .sin => .{ "@sin(", ")" },
                        .cos => .{ "@cos(", ")" },
                        .tan => .{ "@tan(", ")" },
                        .asin => .{ "std.math.asin(", ")" },
                        .acos => .{ "std.math.acos(", ")" },
                        .atan => .{ "std.math.atan(", ")" },
                        .sinh => .{ "std.math.sinh(", ")" },
                        .cosh => .{ "std.math.cosh(", ")" },
                        .tanh => .{ "std.math.tanh(", ")" },
                        .asinh => .{ "std.math.asinh(", ")" },
                        .acosh => .{ "std.math.acosh(", ")" },
                        .atanh => .{ "std.math.atanh(", ")" },
                        // An int→real widening and a reassociation barrier
                        // are both identities in the f64 domain.
                        .if_cast, .opt_barrier => .{ "", "" },
                        else => return null,
                    };
                    return try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ fix[0], a, fix[1] });
                },
                .binary => {
                    if (row.op == .fmod) {
                        const a = try f64Const(self, @enumFromInt(row.a), depth + 1, in_unit) orelse return null;
                        const b2 = try f64Const(self, @enumFromInt(row.b), depth + 1, in_unit) orelse return null;
                        return try std.fmt.allocPrint(self.arena, "(if (({s}) == 0.0) @panic(\"VerA: real parameter remainder divisor is zero\") else @rem({s}, {s}))", .{ b2, a, b2 });
                    }
                    // Integer ops render in the f64 domain like `foldConst`
                    // folds them there; `idiv` is left out because its
                    // truncation is NOT what `/` does on an f64.
                    const fix: [3][]const u8 = switch (row.op) {
                        .fadd, .iadd => .{ "(", ") + (", ")" },
                        .fsub, .isub => .{ "(", ") - (", ")" },
                        .fmul, .imul => .{ "(", ") * (", ")" },
                        .fdiv => .{ "(", ") / (", ")" },
                        .fmin, .imin => .{ "@min(", ", ", ")" },
                        .fmax, .imax => .{ "@max(", ", ", ")" },
                        .pow => .{ "std.math.pow(f64, ", ", ", ")" },
                        .hypot => .{ "std.math.hypot(", ", ", ")" },
                        .atan2 => .{ "std.math.atan2(", ", ", ")" },
                        else => return null,
                    };
                    const a = try f64Const(self, @enumFromInt(row.a), depth + 1, in_unit) orelse return null;
                    const b2 = try f64Const(self, @enumFromInt(row.b), depth + 1, in_unit) orelse return null;
                    return try std.fmt.allocPrint(self.arena, "{s}{s}{s}{s}{s}", .{
                        fix[0], a, fix[1], b2, fix[2],
                    });
                },
                else => return null,
            }
        },
        else => return null,
    }
}

/// `f64Const` for a position where the LRM requires one. A control argument
/// that does not resolve is a SOURCE-LEVEL diagnostic (E0515) plus a refused
/// unit — never an `@compileError` string pasted into the generated Zig,
/// which surfaces as "unreachable code" at a line of generated code with
/// nothing pointing back at the `.va`.
pub fn f64Expr(self: *Gen, v0: Mir.Value) Error![]const u8 {
    if (try f64Const(self, v0, 0, false)) |s| return s;
    // The argument's own defining expression is the thing to point at; the
    // operator call is the fallback for a leaf with no instruction of its
    // own (a node probe, a phi), which is the common case here.
    const v = self.an.rv(v0);
    const def = self.mir.valueDef(v);
    const tok = if (def == .inst_result) self.mir.instTok(def.inst_result) else Mir.no_tok;
    if (self.diags) |bag| try bag.add(
        .codegen,
        .E0515,
        self.lower.tokenSpan(if (tok == Mir.no_tok) self.ctrl_tok else tok),
        "this argument is computed during the solve; only literals, parameters " ++
            "and arithmetic over them are available where the host evaluates it",
        .{},
    );
    self.any_fatal = true;
    if (self.fatal == null) self.fatal = "LRM 4.5: an analog operator control argument " ++
        "must be a constant or parameter expression";
    return "0.0";
}

pub fn argF64(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    return f64Expr(self, args[i]);
}

/// Does this §4.5 control argument need the core, i.e. is it a solve result
/// rather than a constant/parameter expression? Speculative — `f64Const`'s
/// `uses_model` side effect is rolled back, because whether the rendered
/// text is ever emitted is decided later.
pub fn ctrlIsDynamic(self: *Gen, v: Mir.Value) Error!bool {
    const saved = self.uses_model;
    defer self.uses_model = saved;
    return (try f64Const(self, v, 0, false)) == null;
}

/// §4.5 Table 4-20 lists some operator control arguments as DYNAMIC, which
/// `argF64` cannot render: it goes through `f64Const`, whose frame is the
/// host's Model and which refuses a solve result with E0515. These two read
/// the same argument in the two frames that actually evaluate one, and both
/// fall back to `f64Const`'s text when it folds — so a literal or a model
/// parameter renders exactly as it always did.
///
/// `ctrlEval` is the RESIDUAL's frame: the argument is an ordinary rendered
/// expression there, S-valued, and only its value is wanted.
pub fn ctrlEval(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    if (try f64Const(self, args[i], 0, false)) |s| return s;
    // `.val()` is a COLLAPSE: on the batch scalar it reads lane 0, so an
    // x-dependent control argument gives every lane the operating point of
    // the first one. That is exactly what `lane_pinned` records — and the
    // collapse itself is right, not a bug to route around: a control
    // argument is a number the operator is configured WITH, and §4.6.3's
    // stimulus magnitude is an independent source's amplitude at the
    // operating point, so neither belongs in the Jacobian.
    gen_render.pinLanes(self, self.an.rv(args[i]));
    return std.fmt.allocPrint(self.arena, "({s}).val()", .{
        try gen_render.renderToArena(self, args[i], .real),
    });
}

/// §4.5.7 the effective delay of one `absdelay` site, in the caller's
/// frame (`step` selects `updateState`'s over the residual's). Without
/// `maxdelay` a signal-valued td is read out of the field `updateState`
/// froze it in; with a constant td there is nothing to freeze.
pub fn absdelayTd(self: *Gen, n: []const u8, args: []const Mir.Value, step: bool) Error![]const u8 {
    if (try absdelayFreezes(self, args))
        return std.fmt.allocPrint(self.arena, "inst.{s}__td", .{n});
    const td = if (step)
        try ctrlStep(self, args, 1, "0.0")
    else
        try ctrlEval(self, args, 1, "0.0");
    if (args.len < 3) return td;
    // §4.5.7 "If the optional maxdelay is specified, THEN td CAN VARY. If
    // td becomes greater than maxdelay, MAXDELAY WILL BE USED AS A
    // SUBSTITUTE FOR td." Argument 2 was read by nothing at all — the
    // three-argument form behaved as the two-argument one, with no clamp
    // and no varying td. Table 4-20 makes maxdelay the constant argument,
    // so it renders over Model where td renders over the core.
    return std.fmt.allocPrint(self.arena, "@min({s}, {s})", .{
        td, try argF64(self, args, 2, "0.0"),
    });
}

/// §4.5.7 "If maxdelay is not specified, the value of td when the
/// absdelay() is first evaluated shall be used and ANY FUTURE CHANGES TO td
/// SHALL BE IGNORED." A td that folds already IS its first value and needs
/// nothing; only a signal-valued one has to be frozen into `Instance`.
pub fn absdelayFreezes(self: *Gen, args: []const Mir.Value) Error!bool {
    if (args.len != 2) return false;
    return ctrlIsDynamic(self, args[1]);
}

/// `ctrlStep` is `updateState`'s frame, where the only thing evaluated is
/// the single `core(R, …)` sweep — so the argument has to be a field of it,
/// which `buildJobs` is what arranges. A dynamic argument with no core
/// field left is still E0515: that is a planning defect, not a legal
/// program, and answering it with a wrong number would hide it.
pub fn ctrlStep(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    if (try f64Const(self, args[i], 0, false)) |s| return s;
    const k = self.lo_idx[@intFromEnum(self.an.rv(args[i]))];
    if (k == none_u32) return f64Expr(self, args[i]);
    return std.fmt.allocPrint(self.arena, "m.f{d}.v", .{k});
}

/// "the signal crossed zero since the last accepted step, in the direction
/// argument 1 asks for": `+1` rising, `-1` falling, `0` (or absent) either.
/// §4.5.10 `last_crossing` and §5.10.3 `cross` take the SAME argument with
/// the same meaning, so they share the test — `last_crossing` used to fire
/// on any sign change and report a falling edge to a `(V(p), +1)` call.
///
/// The argument is a `constant_expression` in both grammars — and a
/// PARAMETER is one, so `resolve_params = false`: folding through the
/// declared default froze `cross(x, dir)` at the default's direction and
/// the model card's override was silently ignored. A direction that folds
/// without parameters still picks its comparison here; a parameter one
/// becomes a `zCrossDir` call on the model's value, and a genuinely
/// solve-time one is E0515 out of `f64Expr` (§4.5.14's constant-or-
/// parameter rule).
/// `in` is the CURRENT input as a plain `f64` expression: the local
/// `updateState` binds, or the rendered operand `.val()` in `eval`. Both
/// spellings compare against the same `__prev`, which holds the last
/// ACCEPTED input either way.
/// §5.10.3.3's period, as `updateState` reads it. A folded one renders
/// inline; a period computed during the solve is a core live-out queued by
/// `buildJobs`, and reading it out of `m` is what "the next event will be
/// scheduled based on the LATEST value" means for a value the host cannot
/// spell.
pub fn timerPeriod(self: *Gen, args: []const Mir.Value) Error![]const u8 {
    if (args.len < 2) return "0.0";
    if (self.an.foldConst(args[1], 0, false) == null) {
        const lo = self.lo_idx[@intFromEnum(self.an.rv(args[1]))];
        if (lo != none_u32) return std.fmt.allocPrint(self.arena, "m.f{d}.v", .{lo});
    }
    return argF64(self, args, 1, "0.0");
}

/// §5.10.3.3: "If the period expression evaluates to a value less than or
/// equal to 0.0, the timer shall trigger only once at the specified
/// start_time." An absent period is the same case — `updateState` defaults
/// it to 0.0 — and a period that does not fold cannot be decided here.
pub fn timerIsOneShot(self: *Gen, args: []const Mir.Value) bool {
    if (args.len < 2) return true;
    const c = self.an.foldConst(args[1], 0, false) orelse return false;
    return c.f <= 0.0;
}

pub fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value, in: []const u8) Error![]const u8 {
    const arg: Mir.Value = if (args.len > 1) args[1] else .zero;
    if (self.an.foldConst(arg, 0, false)) |c| {
        // §5.10.3.1's fourth case, the one with a number in it: "For any
        // other values of dir, the cross() function does not generate an
        // event and does not act to control the timestep", restated in the
        // same clause as "there are two ways to disable the cross function,
        // either by specifying enable as 0, or giving a value other than
        // -1, 0, or 1 to dir". The `else` arm used to be the BOTH-EDGES
        // test, which made dir = 2 a synonym for dir = 0 and left a model
        // handed an out-of-range direction firing on every edge instead of
        // going quiet. §4.5.10's direction is the same closed set ("shall
        // evaluate to an integer expression +1, -1, or 0"), so
        // `last_crossing` reads it the same way.
        if (c.f == 1.0) return std.fmt.allocPrint(self.arena, "inst.{0s}__prev <= 0.0 and {1s} > 0.0", .{ n, in });
        if (c.f == -1.0) return std.fmt.allocPrint(self.arena, "inst.{0s}__prev >= 0.0 and {1s} < 0.0", .{ n, in });
        if (c.f != 0.0) return "false";
        return std.fmt.allocPrint(
            self.arena,
            "(inst.{0s}__prev <= 0.0 and {1s} > 0.0) or (inst.{0s}__prev >= 0.0 and {1s} < 0.0)",
            .{ n, in },
        );
    }
    return std.fmt.allocPrint(self.arena, "zCrossDir({s}, inst.{s}__prev, {s})", .{
        try f64Expr(self, arg), n, in,
    });
}

/// §5.10.3.1/§5.10.3.2/§5.10.3.3, one sentence repeated verbatim for
/// `cross`, `above` and `timer`: "If enable argument is specified and it is
/// zero, then <op>() is inactive, meaning that it does not generate an
/// event". Absent means active, so an operator without the argument gets a
/// literal `true` and the emitted `and` folds away.
///
/// The enable is the ONE operator argument that is a live expression rather
/// than a codegen-time constant — `enableArgIdx` is what makes `UnitPlan`
/// give it a slot, so a `cross(…, enable)` whose enable is a variable
/// assigned in the block renders as that variable and not as its phi's zero.
pub fn enableTest(self: *Gen, name: []const u8, args: []const Mir.Value) Error![]const u8 {
    const i = enableArgIdx(name) orelse return "true";
    if (i >= args.len) return "true";
    const at = self.out.items.len;
    try gen_cfg.renderCond(self, args[i]);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    return s;
}

/// §5.10 the `held_vars` index a `$held_*` call carries as its only
/// argument. Always a literal `Lower` emitted, so the fold cannot fail.
pub fn heldIdx(self: *const Gen, args: []const Mir.Value) usize {
    const c = self.an.foldConst(if (args.len != 0) args[0] else .zero, 0, false) orelse return 0;
    const i: usize = @intFromFloat(c.f);
    return @min(i, self.held_names.len -| 1);
}

/// System/environment and operator calls. LRM ch9, §4.5, §4.6.
pub fn emitCall(self: *Gen, inst: Mir.Inst) Error!void {
    const d = self.mir.instData(inst).call;
    const name = d.name;
    const k = opKind(name);
    // Lane accounting for the batch differential gate. ddt/idt and the
    // §4.5.11/§4.5.12 filters stay lane-exact: their helpers branch only
    // on `dt` (lane-uniform) and are otherwise S-linear over shared f64
    // state, so evaluating N points against one Instance is exactly N
    // scalar evaluations. Every other operator either steers on a
    // `.val()` of its x-dependent input (events, transition, slew) or
    // collapses it (delays), so it pins.
    switch (k) {
        .none, .ddt, .idt, .laplace, .zi, .bound_step, .discontinuity => {},
        else => for (d.args) |arg| gen_render.pinLanes(self, arg),
    }
    if (k != .none) return emitOperator(self, inst, d.args, k);

    // §4.5.13 limexp — user-invoked only; the engine never inserts it.
    // Pins: zLimexp branches on its argument's `.val()`.
    if (std.mem.eql(u8, name, "limexp")) {
        if (d.args.len > 0) gen_render.pinLanes(self, d.args[0]);
        return gen_render.helper1(self, "zLimexp", if (d.args.len > 0) d.args[0] else .f_zero);
    }

    // §4.5.14 ddx(f, V(node)) — the unknown index came through as an int.
    // Pins: `.ddxAt` reads one scalar partial, which a value-form batch S
    // does not carry.
    if (std.mem.eql(u8, name, "ddx")) {
        if (d.args.len > 0) gen_render.pinLanes(self, d.args[0]);
        const u = if (d.args.len > 1) self.an.foldConst(d.args[1], 0, true) else null;
        try self.b("S.con((", .{});
        try gen_render.renderVal(self, if (d.args.len > 0) d.args[0] else .f_zero, .real);
        // The index is a literal lowering minted, but the cast is still
        // saturating: a compiler panic is never the answer to bad MIR.
        try self.b(").ddxAt({d}))", .{if (u) |x| std.math.lossyCast(i64, x.f) else 0});
        return;
    }

    // §5.2.1 the `analog initial` guard. Its own flag and not
    // `is_initial_step`: §5.2.1 re-executes the block for each SUB-TASK of a
    // parameter sweep, and Table 5-1's initial_step is the first point of the
    // whole analysis. See `Lower.lowerModule`.
    if (std.mem.eql(u8, name, "analog_initial")) {
        self.uses_inst = true;
        try self.b("S.con(if (inst.is_analog_initial) 1.0 else 0.0)", .{});
        return;
    }

    // §5.10.2 global events.
    if (std.mem.eql(u8, name, "initial_step") or std.mem.eql(u8, name, "final_step")) {
        self.uses_inst = true;
        const flag = if (name[0] == 'i') "is_initial_step" else "is_final_step";
        try self.b("S.con(if (inst.{s}", .{flag});
        if (d.args.len != 0) {
            try self.b(" and (", .{});
            try analysisMatch(self, d.args);
            try self.b(")", .{});
        }
        try self.b(") 1.0 else 0.0)", .{});
        return;
    }

    // §4.6.1 analysis("dc"|"tran"|…).
    if (std.mem.eql(u8, name, "analysis")) {
        self.uses_inst = true;
        try self.b("S.con(if (", .{});
        try analysisMatch(self, d.args);
        try self.b(") 1.0 else 0.0)", .{});
        return;
    }

    // §4.6.4 noise sources contribute in a small-signal noise analysis only;
    // their residual contribution is identically zero. The generator
    // topology is exported through `noise_gens` and the PSD — which IS the
    // call's argument, not anything derivable from the residual — through
    // `noisePsd`, whose core fields the argument slice already holds.
    const noise = [_][]const u8{ "white_noise", "flicker_noise", "noise_table", "noise_table_log" };
    for (noise) |n| {
        if (std.mem.eql(u8, name, n)) return self.b("S.con(0.0)", .{});
    }
    // §4.6.3 ac_stim(analysis_name, mag, phase) is NOT a noise source: it
    // is a small-signal stimulus. "The AC stimulus function returns zero
    // (0) during large-signal analyses (such as DC and transient) as well
    // as on all small-signal analyses using names which do not match
    // analysis_name" — so the whole function is one conditional on the
    // analysis in force, with the §4.6.1 name comparison `analysis()`
    // already spells. The name defaults to "ac", mag to 1.0, phase to 0.0.
    //
    // ponytail: the residual is REAL, so a matching analysis contributes
    // the phasor's real part, mag·cos(phase). The quadrature component is
    // dropped, which costs nothing for the phase = 0 form every model in
    // the suite writes and is wrong by cos for the rest. Upgrade path is
    // an `ac_gens` export beside `noise_gens`, carrying (mag, phase) for a
    // host that solves a complex system — the same shape §4.6.4 uses, and
    // the reason this is a conditional rather than an export today is that
    // the contract has no complex side to hand it to.
    if (std.mem.eql(u8, name, "ac_stim")) {
        self.uses_inst = true;
        // A.8.2 gives BOTH numeric arguments as `analog_expression`, the
        // same production a contribution's right-hand side uses, and puts
        // `constant_expression` only where it means one (the filters'
        // trailing argument, two productions above). §4.5's Table 4-20 is
        // the constant-argument register and `ac_stim` is not in it,
        // because it is not an analog operator and keeps no state. So
        // `ctrlEval`, not `argF64`: a magnitude the solve computes —
        // `ac_stim("ac", k*V(ctrl))`, a swept-amplitude source — is a
        // rendered expression here, and only a literal or a parameter
        // still folds to the number it always did.
        const mag = try ctrlEval(self, d.args, 1, "1.0");
        const phase = try ctrlEval(self, d.args, 2, "0.0");
        try self.b("S.con(if (", .{});
        if (d.args.len == 0)
            try self.b("inst.analysis_kind == .ac", .{})
        else
            try analysisMatch(self, d.args[0..1]);
        try self.b(") ({s}) * @cos({s}) else 0.0)", .{ mag, phase });
        return;
    }

    if (name.len != 0 and name[0] == '$') return emitSysCall(self, name, d.args, inst);

    return abort(self, "VerA: unhandled call `{s}`", .{name});
}

pub fn abort(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    self.any_fatal = true;
    if (self.fatal == null) self.fatal = try std.fmt.allocPrint(self.arena, fmt, args);
    try self.b("S.con(0.0)", .{});
}

/// §4.6.1 the analysis-name arguments are string constants; the comparison
/// against the runtime pass is what the host answers.
pub fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void {
    var first = true;
    for (args) |a| {
        const def = self.mir.valueDef(self.an.rv(a));
        if (def != .str_const) continue;
        if (!first) try self.b(" or ", .{});
        first = false;
        const s = def.str_const;
        if (std.mem.eql(u8, s, "static")) {
            // §4.6.1 "static" is true in any analysis that computes a DC
            // operating point.
            try self.b("(inst.analysis_kind == .static or inst.analysis_kind == .ic or " ++
                "inst.analysis_kind == .nodeset or inst.analysis_kind == .dc)", .{});
        } else if (std.mem.eql(u8, s, "tran")) {
            // §4.6.1 "tran" is true during "the initial DC and time-sweep
            // phases of a transient" — the ic phase counts. This is what
            // lets a source spell ngspice's TRANOP/DCOP split: the
            // transient's own operating point evaluates waveform(0) while
            // .op/.dc/.ac bias at the DC value
            // (`analysis("static") && !analysis("tran")`).
            try self.b("(inst.analysis_kind == .tran or inst.analysis_kind == .ic)", .{});
        } else if (isAnalysisName(s)) {
            try self.b("inst.analysis_kind == .{s}", .{s});
        } else {
            try self.b("false", .{});
        }
    }
    if (first) try self.b("false", .{});
}

/// `inst` is the call's own MIR instruction, and it is here for exactly one
/// reason: §9.5.3's formatter needs storage for the bytes it produces that
/// outlives the expression (a string slot is a `[]const u8`), and the
/// instruction id is the per-call-site name `zSBuf` keys that storage by.
pub fn emitSysCall(self: *Gen, name: []const u8, args: []const Mir.Value, inst: Mir.Inst) Error!void {
    if (std.mem.eql(u8, name, "$display$width")) return gen_render.renderVal(self, args[0], .int);
    const eq = std.mem.eql;
    // §9.4/§9.7.3 — only when the caller asked for a printing artifact. In a
    // device they fall through to `void_tasks` below.
    if (self.display == .emit and Lower.isDisplayTask(name))
        return cg_display.emitDisplayTask(self, name, args, @intFromEnum(inst));
    // §9.7.1/§9.7.2 — same gate: in the printing artifact the run ends at
    // the call's position among the prints; in a device the call is dead
    // (`Lower.isSimCtlTask` calls join the display chain and nothing else,
    // so under `.drop` nothing ever renders one — the fall-through to
    // `void_tasks` below is for a model that reads the void result).
    if (self.display == .emit and Lower.isSimCtlTask(name))
        return cg_display.emitSimCtl(self, name, args);
    // §9.4.1 a monitor's registration (`Lower.armMonitor`): a side effect, so
    // only the display unit performs it; anywhere else it is the void below.
    if (self.emitting_display and eq(u8, name, "$monitor$arm"))
        return cg_display.emitMonitorArm(self, args);
    // §9.5 the descriptor family. Real kernels only in the display unit (see
    // `emitting_display`); rendered but discarded in any other unit of the
    // same artifact, so the slice `callArgIsValue` asked for is consumed.
    //
    // NOT gated on the display mode, and that is the point: `buildJobs`
    // queues a display unit only under `.emit`, so `emitting_display` is
    // already false throughout a `.drop` build and every §9.5 name lands in
    // `emitFileCallDropped` — the one place that answers with the type
    // `Analysis.callTy` gave the call. Gating here instead sent them to
    // `void_tasks`' blanket `S.con(0.0)`, which put an `S` in the `i64` slot
    // §9.5.1 says a descriptor is: `const t0: i64 = S.con(0.0);`, `--emit-zig`
    // exit 0, and the failure deferred to whoever compiled the device.
    if (Lower.isFileCall(name)) {
        if (!self.emitting_display) return emitFileCallDropped(self, name, args, @intFromEnum(inst));
        return cg_display.emitFileCall(self, name, args, @intFromEnum(inst));
    }
    // §9.10 environment.
    if (eq(u8, name, "$temperature")) {
        self.uses_inst = true;
        return self.b("S.con(inst.temperature)", .{});
    }
    if (eq(u8, name, "$vt")) {
        // k/q = 8.617333262e-5 V/K (§9.10 $vt = kT/q).
        if (args.len == 0) {
            self.uses_inst = true;
            return self.b("S.con(inst.temperature * 8.617333262145179e-5)", .{});
        }
        try self.b("(", .{});
        try gen_render.renderVal(self, args[0], .real);
        return self.b(").scale(8.617333262145179e-5)", .{});
    }
    if (eq(u8, name, "$abstime") or eq(u8, name, "$realtime")) {
        self.uses_inst = true;
        return self.b("S.con(inst.abstime)", .{});
    }
    // §5.10 the retained value of an event-assigned variable. `Lower` put
    // this in the entry block in place of the declared initializer, so
    // reading the variable before the event has ever fired reads the
    // `Instance` default and after it the last accepted value.
    if (eq(u8, name, "$held_real") or eq(u8, name, "$held_int")) {
        self.uses_inst = true;
        const f = self.held_names[heldIdx(self, args)];
        return if (eq(u8, name, "$held_int"))
            self.b("inst.{s}", .{f})
        else
            self.b("S.con(inst.{s})", .{f});
    }
    if (eq(u8, name, "$mfactor")) { // §6.3.6
        self.uses_inst = true;
        return self.b("S.con(inst.mfactor)", .{});
    }
    // §9.18 Table 9-29 hierarchical system parameters. Their value is the
    // top-level value combined down the instantiation hierarchy; VerA
    // elaborates exactly ONE flat module, so the device IS the top level
    // and the table's "Top-Level Value" column is exact — not a substitute.
    // ($mfactor is the exception above: the host scales the whole stamp by
    // it, so it stays a settable Instance field.)
    if (eq(u8, name, "$xposition") or eq(u8, name, "$yposition"))
        return self.b("S.con(0.0)", .{}); // 0.0 m
    if (eq(u8, name, "$angle"))
        return self.b("S.con(0.0)", .{}); // 0 degrees
    if (eq(u8, name, "$hflip") or eq(u8, name, "$vflip"))
        return self.b("S.con(1.0)", .{}); // +1
    // §9.15 $simparam(name [, fallback]), in the clause's own order: the
    // KNOWN value first, the fallback only for a name this engine does not
    // have ("its value is returned IF param_name is not known"). The list
    // and the values are `Lower.simparamValue`, so the name that reaches
    // here answered is the same set that escaped E0811 at lowering.
    if (eq(u8, name, "$simparam")) {
        const nm = strArg(self, args, 0) orelse "";
        if (Lower.simparamIsRuntime(nm)) {
            self.uses_inst = true;
            return self.b("S.con(@floatFromInt(inst.newton_iteration))", .{});
        }
        // Host-published first: `simparamValue` also answers `tnom`, but
        // only as the DECLARED default (`Lower.simparamHostField`).
        if (Lower.simparamHostField(nm)) |f| {
            self.uses_model = true;
            return self.b("S.con(model.{s})", .{f});
        }
        if (self.lower.simparamValue(nm)) |v| return self.b("S.con({s})", .{try gen_file.fmtF64(self, v)});
        if (args.len > 1) return self.b("S.con({s})", .{try f64Expr(self, args[1])});
        // Unknown, no fallback: E0811 already refused this compile unless
        // the name was not a literal, in which case zero is the only answer
        // available and the model asked for a name nothing could resolve.
        return self.b("S.con(0.0)", .{});
    }
    // §9.15 "Table 9-28 gives a list of simulation string parameter names
    // that shall be supported by $simparam$str" — no "if they support the
    // parameter" escape, unlike Table 9-27's numeric side, so the two names
    // this engine actually knows are answered. The rest ("cwd", "instance",
    // "path") describe the host's filesystem and instantiation hierarchy,
    // which a flat elaborated device has no view of: "" is the honest answer
    // there, an invented path is not.
    if (eq(u8, name, "$simparam$str")) {
        // §9.15: "The argument param_name is a string value, either a string
        // literal, a string parameter, or a STRING VARIABLE." A variable's
        // value is only known while the block runs, so the table is
        // consulted at RUN TIME and not folded here. The name folds to a
        // literal in the common case and `zig` collapses the chain back to
        // one branch; `strArg orelse ""` used to answer every unfoldable
        // name with the empty string, which is a constant folder wearing
        // §9.15's signature.
        //
        // §4.6.1's analysis names ARE the `AnalysisKind` tag spellings, so
        // the enum is the table — no second list to drift out of step.
        // Table 9-28's hierarchy rows are answered by `Lower` (they are
        // elaboration facts, and this function has one flattened module):
        // "module" survives here only for the callers that build a `Gen`
        // with no elaborated unit table.
        self.uses_inst = true;
        try self.b("(if (std.mem.eql(u8, ", .{});
        try gen_render.renderValueRef(self, self.an.rv(args[0]));
        try self.b(", \"analysis_type\")) @tagName(inst.analysis_kind) else if (std.mem.eql(u8, ", .{});
        try gen_render.renderValueRef(self, self.an.rv(args[0]));
        return self.b(", \"module\")) \"{f}\" else \"\")", .{std.zig.fmtString(self.mir.name)});
    }
    // §9.19 $param_given / $port_connected.
    if (eq(u8, name, "$param_given")) {
        const def = if (args.len > 0) self.mir.valueDef(self.an.rv(args[0])) else Mir.Def.undef;
        if (def == .param_ref) {
            self.uses_model = true;
            return self.b("@as(i64, @intFromBool(model.{s}__given))", .{self.p_names[def.param_ref]});
        }
        return self.b("@as(i64, 0)", .{});
    }
    if (eq(u8, name, "$port_connected")) {
        // Every port of an elaborated device instance is connected; an
        // unconnected one is the host's business (§6.5.6).
        return self.b("@as(i64, 1)", .{});
    }
    // §9.20 node aliases do NOT appear here, and used to: this arm answered
    // the constant 0 on the argument that "this engine elaborates ONE FLAT
    // MODULE, so there is no instance hierarchy for such a string to resolve
    // into". The premise was false. Elaboration FLATTENS a hierarchy, and a
    // flattened child's net keeps its path as its name (`Elaborate.sep` is a
    // period), so the string §9.20 hands the compiler and the name the
    // design carries are the same bytes. `Lower.bindAlias` resolves it
    // against `node_voltages`, performs the clause's topology edit there —
    // an alias is that map's business, since it is what every probe goes
    // through — and folds the call to its 1 or its 0. This backend never
    // sees one of these names.
    // §9.12 command-line plusargs: absent.
    if (eq(u8, name, "$test$plusargs") or eq(u8, name, "$value$plusargs"))
        return self.b("@as(i64, 0)", .{});
    // §9.22/§9.23 driver & receiver access do NOT appear here. They used to,
    // answering the constant 0 (and -1.0 for $driver_delay's no-pending-value
    // sentinel) on the argument that a flat analog device has no digital
    // drivers so zero is the true count. The argument is wrong at the first
    // step: §9.22 paragraph 3 says "Driver access functions can only be
    // called from connect modules", so the call itself is illegal in every
    // module VerA can compile and there is no result to render. Refused at
    // lowering now (E0818, `isConnectModuleOnlySysFunc`), which is where the
    // call site is known — so this backend never sees one of these names.
    // §4.5.15 $limit: the limiting ALGORITHM is a convergence aid the host
    // owns (contract `limit`); the LRM lets a simulator that does not apply
    // it return the access function unchanged, which is what happens here.
    // §9.17.3 the USER-FUNCTION form. `lower.lowerLimitUser` has already
    // inlined the function body and latched its return into the site's
    // `LimitSlot`; what is left is the one thing only the backend can
    // spell — the returned value carries the ACCESS FUNCTION's derivative,
    // not the limiter's, so the clamp lands as a constant shift on the
    // probe. args = (vnew, vlim). See `zLimitUf`.
    if (eq(u8, name, "$limit$uf") and args.len == 2) {
        // `.val()` on two x-dependent carriers: a vector S would collapse
        // per lane, so this pins them for the same reason `zPow` does.
        gen_render.pinLanes(self, args[0]);
        gen_render.pinLanes(self, args[1]);
        return gen_render.helper2(self, "zLimitUf", args[0], args[1]);
    }
    if (eq(u8, name, "$limit$old")) {
        self.uses_inst = true;
        return self.b("S.con(inst.limiter_previous[{d}])", .{gen_render.intArg(self, args, 0) orelse unreachable});
    }
    if (eq(u8, name, "$limit"))
        return gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
    if (eq(u8, name, "$clog2"))
        return gen_render.intCall1(self, "zClog2", if (args.len > 0) args[0] else .zero);
    // §9.11 conversions. `$rtoi` truncates (Table 9-7); the saturation is
    // ours — the clause is silent on overflow and `@intFromFloat` is UB in
    // the ReleaseFast artifact a host actually links.
    if (eq(u8, name, "$rtoi")) {
        if (args.len > 0) gen_render.pinLanes(self, args[0]); // scalar collapse
        try self.b("std.math.lossyCast(i64, @trunc((", .{});
        try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
        return self.b(").val()))", .{});
    }
    if (eq(u8, name, "$itor")) {
        try self.b("S.con(@as(f64, @floatFromInt(", .{});
        try gen_render.renderVal(self, if (args.len > 0) args[0] else .zero, .int);
        return self.b(")))", .{});
    }
    // §9.11 Table 9-8 $realtobits/$bitstoreal: the IEEE-754 bit pattern of
    // the real, verbatim. Exactly representable in the i64 that lowering
    // gives integers, so this is the spec function, not an approximation.
    if (eq(u8, name, "$realtobits")) {
        if (args.len > 0) gen_render.pinLanes(self, args[0]); // scalar collapse
        try self.b("@as(i64, @bitCast((", .{});
        try gen_render.renderVal(self, if (args.len > 0) args[0] else .f_zero, .real);
        return self.b(").val()))", .{});
    }
    if (eq(u8, name, "$bitstoreal")) {
        try self.b("S.con(@as(f64, @bitCast(", .{});
        try gen_render.renderVal(self, if (args.len > 0) args[0] else .zero, .int);
        return self.b(")))", .{});
    }
    // §9.5.3 `$swrite`/`$sformat`, arriving as the synthetic `$sformat` whose
    // operands are the format and its arguments — the destination is gone,
    // because lowering made this call the right-hand side of an assignment to
    // it. The text goes into this call site's own scratch row.
    if (eq(u8, name, "$sformat"))
        return cg_display.emitStringFormat(self, args, @intFromEnum(inst));
    // §9.5.4.2 `$sscanf`: the count, and the three item flavours lowering
    // picks from the destination's declared type. All four are pure functions
    // of the same two strings, so nothing here has to sequence them.
    //
    // Unreached item helpers return default payloads, not assignments.
    // Lower.lowerScan guards each destination write with count > index,
    // retaining its incoming SSA value when conversion did not assign it.
    if (eq(u8, name, "$table_model")) return gen_render.emitTable(self, inst, args); // §9.21
    // §§3.2/5.7 runtime array index — one switch, see `emitIdx`.
    if (array_index_types.get(name)) |ty| return gen_render.emitIdx(self, args, ty);
    // §9.13 Table 9-10, in the shape `Lower.lowerRandom` rewrote it: the
    // seed's incoming value, then the distribution's parameters. Every one is
    // a pure function of that seed and carries no derivative — a variate is a
    // constant of the operating point, which is what makes it admissible in a
    // residual at all (see `rng_kernels.zig`).
    if (std.mem.startsWith(u8, name, "$rng$")) return gen_render.emitRng(self, name, args);
    if (eq(u8, name, "$sscanf")) return gen_render.emitScan(self, "zScanN", args, .int);
    if (eq(u8, name, "$sscanf$int")) return gen_render.emitScan(self, "zScanI", args, .int);
    if (eq(u8, name, "$sscanf$real")) return gen_render.emitScan(self, "zScanR", args, .real);
    if (eq(u8, name, "$sscanf$str")) return gen_render.emitScan(self, "zScanS", args, .str);
    // §9.4/§9.7 display and control tasks: void. Lowering keeps them as
    // calls; their result is never read, so this only fires if a model
    // assigns one — and every one of these is real-valued (`Analysis.callTy`
    // types nothing here `.int`), which is what makes ONE answer correct for
    // the whole list.
    //
    // The §9.5 descriptor family is NOT here. It used to be, for the case
    // where a device carries no host file table — but that answer is
    // `emitFileCallDropped`'s, which reads `callTy` and returns `@as(i64, 0)`
    // for the eight integer-valued names §9.5.1 defines a descriptor as. The
    // blanket `S.con(0.0)` below typed them real and the two disagreed.
    // `Lower.isFileCall` above now claims every §9.5 spelling in BOTH display
    // modes, so nothing in that family reaches this list.
    const void_tasks = [_][]const u8{
        "$display", "$displayb",  "$displayo",      "$displayh",
        "$write",   "$writeb",    "$writeo",        "$writeh",
        "$strobe",  "$strobeb",   "$strobeo",       "$strobeh",
        "$monitor", "$monitoron", "$monitoroff",    "$debug",
        "$finish",  "$stop",      "$fatal",         "$error",
        "$warning", "$info",      "$discontinuity", "$bound_step",
        "$monitor$arm",
    };
    for (void_tasks) |t| {
        if (eq(u8, name, t)) return self.b("S.con(0.0)", .{});
    }
    // IEEE 1364 §17.11 math functions, carried into Verilog-AMS: `$ln`,
    // `$exp`, `$pow`, … are the same functions as their bare spellings.
    const bare = name[1..];
    if (mathOpByName(bare)) |op| {
        if (Mir.opClass(op) == .unary and args.len >= 1) return gen_render.renderOp(self, op, args[0], .f_zero, .real);
        if (Mir.opClass(op) == .binary and args.len >= 2) return gen_render.renderOp(self, op, args[0], args[1], .real);
    }
    if (eq(u8, bare, "abs") and args.len >= 1) return gen_render.method1(self, args[0], "abs");
    if ((eq(u8, bare, "min") or eq(u8, bare, "max")) and args.len >= 2)
        return gen_render.helper2(self, if (bare[1] == 'i') "zMin" else "zMax", args[0], args[1]);

    // Nothing above claimed the name, so it is not a Chapter 9 function, not
    // an Annex D macro and not a §4.5 operator: it is an UNREGISTERED system
    // function. §2.8.3 makes `$name` grammatical and lists "defined using the
    // VPI as described in Clause 11 and Clause 12" as one of its definition
    // sites; §12.32's vpi_register_analog_systf() hands the APPLICATION a
    // compiletf routine, so what an unknown systf means is the host's
    // decision and not this compiler's. §12.32.3's own sampnhold listing
    // puts one in a contribution. No clause makes the source an error, so it
    // may not be rejected — see W0852.
    //
    // THE SET THAT ARRIVES HERE IS ACTUALLY EMPTY OF LRM NAMES, which is
    // what makes the answer below safe rather than a blanket amnesty: every
    // Chapter 9 name is either implemented above or diagnosed by a RULE
    // before codegen (E0806 for a digital-only row of the §9.2 tables, E0808
    // for the retired v1.0 `$limexp`, E0812, E0813, E0815, E0816). Probing
    // the whole of ch9 by hand, the only names that reach this line are ones
    // Verilog-AMS defines nowhere — `$countdrivers`, `$rose`, `$fell`, and a
    // typo. Add an unimplemented LRM function above, not here.
    //
    // WHY THIS IS NOT THE SILENT-ZERO THE REST OF THIS FILE REFUSES. Every
    // `abort` here stands where the LRM fixes a number and a substitute
    // would contradict it (E0515's control arguments, a filter VerA cannot
    // build). This name has no such number: the language defines no value
    // for an unregistered systf at all — §12.32.3 never initializes
    // sampler->value before the first update callback and returns that field
    // through vpi_put_value() — so there is nothing to be wrong about, only
    // an absent host. The compromise is that it is LOUD: one warning per
    // call site, `--deny=W0852` restores the refusal for anyone who wants a
    // host-less build to fail instead.
    if (self.diags) |bag| try bag.add(
        .codegen,
        .W0852,
        self.lower.tokenSpan(self.mir.instTok(inst)),
        "`{s}` is not a system function this compiler defines, so it is exported in " ++
            "`systf_calls` for a VPI application to supply; a host that binds none " ++
            "will not build",
        .{name},
    );
    // A systf crosses to the host through concrete f64s (`.val()` per
    // argument, partials written back) — a per-lane crossing does not
    // exist, so it pins regardless of what the host computes.
    self.lane_pinned = self.lane_pinned or !self.emitting_display;
    return emitSystfCall(self, name, args);
}

/// §2.8.3/§12.32: hand one unresolved `$name` to the host's VPI application.
///
/// WHY THIS IS NOT A CALL THROUGH A `fn (args: []S) S` POINTER, which is what
/// every other hook in the contract would look like. `eval` is generic over
/// S and is instantiated at least twice — a plain f64 for the residual, a
/// derivative-carrying dual for the Jacobian — and a function POINTER cannot
/// be generic over S. So the boundary is concrete: the host returns the
/// value and writes the partials, and this rebuilds the dual.
///
/// The reassembly is the whole trick. `arg.addC(-arg.val())` has VALUE zero
/// and DERIVATIVE d(arg), so `.scale(p)` makes a term that contributes p·d(arg)
/// to the derivative and nothing at all to the value. Summed onto `S.con(v)`
/// the result carries the host's value with the host's partials grafted on —
/// and on the plain-f64 instantiation every one of those terms is exactly
/// zero, so the residual reads `v` and nothing else. That is §12.22.1's
/// `derivtf` arrived at from the other side, and it is what keeps `eval` a
/// pure function of x, which the host's own Newton iteration depends on.
///
/// The arguments are bound to `const`s first rather than rendered twice:
/// each is needed once for its value and once for its derivative, and an
/// argument expression can be an arbitrary subtree.
pub fn emitSystfCall(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
    const k = for (self.systf_names.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) break i;
    } else blk: {
        try self.systf_names.append(self.arena, name);
        break :blk self.systf_names.items.len - 1;
    };
    // `inst` is the generated device's own parameter, and `emitUnit` patches
    // it to `_` when nothing read it. This reads it.
    self.uses_inst = true;

    const label = self.systf_sites;
    self.systf_sites += 1;
    try self.b("zs{d}: {{\n", .{label});
    for (args, 0..) |a, j| {
        try self.b("        const zs{d}a{d} = ", .{ label, j });
        try gen_render.renderVal(self, a, .real);
        try self.b(";\n", .{});
    }
    // `validateHost` is what makes this unwrap safe, and it is the reason
    // the check exists: with no application bound there is no value here,
    // not a wrong one — §12.32.3 never initializes its sampler's value
    // before the first callback, so the language fixes no default to fall
    // back to. Refusing the HOST's build is the only outcome that cannot be
    // mistaken for a working device.
    try self.b("        const zsh = inst.systf.?;\n", .{});
    try self.b("        const zsv = [_]f64{{", .{});
    for (args, 0..) |_, j| try self.b("{s} zs{d}a{d}.val()", .{ if (j == 0) "" else ",", label, j });
    try self.b(" }};\n", .{});
    try self.b("        var zsp: [{d}]f64 = undefined;\n", .{args.len});
    try self.b("        var zsr = S.con(zsh.call(zsh.ctx, {d}, &zsv, &zsp));\n", .{k});
    for (args, 0..) |_, j|
        try self.b("        zsr = zsr.add(zs{d}a{d}.addC(-zsv[{d}]).scale(zsp[{d}]));\n", .{ label, j, j, j });
    try self.b("        break :zs{d} zsr;\n    }}", .{label});
}

/// The `$name`s this device leaves to a VPI application. Emitted after the
/// units because that is when the set is known — nothing before `renderCall`
/// can say which names it will fail to resolve without repeating all of it.
pub fn emitSystfTable(self: *Gen) Error!void {
    if (self.systf_names.items.len == 0) return;
    try self.w(
        \\/// §2.8.3 `$name`s this device leaves to a VPI application
        \\/// (§12.32 `vpi_register_analog_systf`). Position k is the `k` the
        \\/// device passes to `Instance.systf.?.call`. A host linking this
        \\/// device shall bind them — see `contract.validateHost`.
        \\pub const systf_calls = [_]contract.Systf{{
        \\
    , .{});
    for (self.systf_names.items) |n| try self.w("    .{{ .name = \"{s}\" }},\n", .{n});
    try self.w("}};\n\n", .{});
}

/// A §9.5 call in a unit that is NOT the display unit: the descriptor answers
/// what §9.5.1 says a device with no file table has to answer, and the
/// operands are consumed rather than dropped.
///
/// Consumed, because `callArgIsValue` said they were live and the slice
/// therefore declared them — an unused local is a hard error in Zig, so the
/// two have to agree. The alternative, teaching `callArgIsValue` which unit it
/// is being asked about, would thread the display flag through `UnitPlan`'s
/// whole marking pass to save four characters of generated text.
///
/// The whole of a `display == .drop` build is "not the display unit", so this
/// is also every §9.5 call in a device. `callArgIsValue` marks nothing live
/// there, which agrees the other way round: no slot is declared, and there is
/// nothing to consume. What matters in both modes is the TYPE below — the
/// caller's slot is `Analysis.callTy`'s, and §9.5's descriptors are integers.
pub fn emitFileCallDropped(self: *Gen, name: []const u8, args: []const Mir.Value, site: usize) Error!void {
    _ = args; // `UnitPlan.dispHere` did not mark them: there is nothing here to read them
    // A printing artifact HAS a file table: the display unit performed this
    // call and latched its integer result (`file_kernels.zFRes`), so a
    // descriptor assigned in the analog block reads back as the descriptor.
    // A device (`.drop`) never performs one and keeps the zero below.
    if (self.display == .emit and Analysis.callTy(name) == .int)
        return self.b("zFRes({d}).*", .{site});
    // §9.5.1 reserves 0 for `$fopen`'s failure, §9.5.4.1 for "an error occurs
    // reading", §9.5.8 for "no EOF has been detected" and §9.5.7 for "the most
    // recent operation did not result in an error" — so zero is the right
    // answer here and not a stub. §9.5.5's positioning family is the one
    // exception: its error return is EOF, but `$ftell` on a descriptor that
    // was never opened has no offset to report either way.
    try self.b("{s}", .{switch (Analysis.callTy(name)) {
        .real => "S.con(0.0)",
        .int => "@as(i64, 0)",
        .str => "\"\"",
    }});
}

pub fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8 {
    if (i >= args.len) return null;
    const def = self.mir.valueDef(self.an.rv(args[i]));
    return if (def == .str_const) def.str_const else null;
}

/// §4.5 stateful analog operators. The operator's INPUT is a named unit of
/// its own, so the state field and `updateState`'s read of the input share
/// one stable key and adding an unrelated operator renumbers nothing.
pub fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void {
    self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
    const unit = self.op_unit[@intFromEnum(inst)];
    if (unit == none_u32) return self.b("S.con(0.0)", .{});
    const n = self.unit_names[unit];
    // Only the operators whose kernel needs the CURRENT input read it; the
    // pure-history ones answer from `Instance` alone. Rendering the input
    // for one of those would set `uses_x`/`uses_model` for text that is
    // never emitted, and `patchParam` would then leave a named parameter
    // nothing references — which Zig rejects.
    const needs_in = opNeedsInput(k);
    // The input is a `Mir.Value` of the body being rendered, not a call to a
    // declaration of its own: `planCommon` makes every operator input a
    // field of the core, so inside the core it is the local that already
    // holds it and inside the §9.4 `display` unit it is a cache read.
    // `callArgIsValue` still returns false for an operator argument — the
    // value is live because it is a core target, not because this call
    // marked it, which is what keeps the §4.5.2 one-evaluation-per-step rule.
    const in = if (needs_in)
        try gen_render.renderToArena(self, if (args.len == 0) .f_zero else args[0], .real)
    else
        "";
    self.uses_inst = true;
    switch (k) {
        // §4.5.11 the cascade reads its sections from Model on every
        // evaluation and is LINEAR in the current input, so the Jacobian
        // `b0/a0` it hands the solver is exact.
        .laplace => {
            const p = try cg_filters.filterPlan(self, inst, args);
            if (p.err) |m| return abort(self, "{s}", .{m});
            // `__sec` takes a `*const Model` whatever its coefficients read,
            // so the call site is a use of `model` even when `filterPlan`
            // saw no Model read — without this the enclosing unit's
            // parameter gets patched to `_` and the device does not compile.
            self.uses_model = true;
            try self.b("zLaplace(S, {d}, {d}, {s}, {s}__sec(model), inst.dt, &inst.{s}__u, &inst.{s}__y)", .{
                p.ns, p.deg, in, n, n, n,
            });
        },
        // §4.5.12 "acts like a simple sample-and-hold which samples every T
        // seconds and EXHIBITS NO DELAY": between samples the output does
        // not depend on the current unknowns and enters the residual as a
        // constant — the same companion model `absdelay` uses — but AT a
        // sample instant it is the output of THAT sample. `zZiEval` decides
        // which, off the same `__next` clock `updateState` advances; it
        // used to be handed `inst.__out` alone, which `updateState` writes
        // after the timepoint is evaluated, so every zi_* ran one whole
        // sample period late.
        .zi => {
            const p = try cg_filters.filterPlan(self, inst, args);
            if (p.err) |m| return abort(self, "{s}", .{m});
            // Same reason `.laplace` above forces it: `__sec` takes a
            // `*const Model` whatever its coefficients read.
            self.uses_model = true;
            try self.b(
                "zZiEval(S, {0d}, {1d}, {2s}, {3s}__sec(model), inst.dt, inst.{3s}__out, " ++
                    "inst.abstime, inst.{3s}__nk, {4s}, &inst.{3s}__u, &inst.{3s}__y)",
                .{ p.ns, p.deg, in, n, p.period orelse "0.0" },
            );
        },
        .ddt => try self.b("zDdt(S, {s}, inst.{s}__prev, inst.dt)", .{ in, n }),
        // §4.5.4 `idt(expr, ic, assert)`: "idt() returns the initial
        // conditions during DC and IC analyses, and whenever assert is
        // nonzero. Once assert becomes zero, idt() returns the integral of
        // the argument starting from the last instant where assert was
        // nonzero." The reset is a plain select on the accumulator, which
        // `updateState` holds at `ic` for as long as assert is nonzero.
        .idt => if (args.len >= 3) try self.b(
            "zIdtReset(S, {s}, inst.{s}__acc, inst.dt, {s}, {s})",
            .{ in, n, try ctrlEval(self, args, 1, "0.0"), try ctrlEval(self, args, 2, "0.0") },
        ) else try self.b("zIdt(S, {s}, inst.{s}__acc, inst.dt, {s})", .{
            in, n, try ctrlEval(self, args, 1, "0.0"),
        }),
        .idtmod => try self.b("zIdtmod(S, {s}, inst.{s}__acc, inst.dt, {s}, {s}, {s})", .{
            in,                                 n,
            try ctrlEval(self, args, 1, "0.0"), try ctrlEval(self, args, 2, "0.0"),
            try ctrlEval(self, args, 3, "0.0"),
        }),
        .absdelay => try self.b(
            "zAbsdelay(S, {s}, &inst.{s}__t, &inst.{s}__v, inst.{s}__head, inst.abstime, inst.dt, {s})",
            .{ in, n, n, n, try absdelayTd(self, n, args, false) },
        ),
        // §4.5.8 the ramp reads its ORIGIN out of `Instance` — where the
        // output was when the current excursion began, and when that was —
        // and takes its TARGET from the current input, so the companion
        // model is linear in the unknowns with slope `(t-t0)/tt`. That is
        // the derivative of the piecewise-linear function itself, not an
        // approximation of it.
        .transition => {
            const t = try transitionTimes(self, args);
            try self.b(
                "zTransition(S, {0s}, inst.{1s}__from, inst.{1s}__to, inst.{1s}__t0, " ++
                    "inst.abstime, inst.dt, {2s}, {3s})",
                .{ in, n, t[0], t[1] },
            );
        },
        .slew => {
            const r = try slewRates(self, args);
            try self.b("zSlew(S, {s}, inst.{s}__prev, inst.dt, {s}, @abs({s}))", .{
                in, n, r[0], r[1],
            });
        },
        .last_crossing => try self.b("S.con(inst.{s}__t_last)", .{n}),
        // §5.10.3 THE EVENT IS DECIDED HERE, not in `updateState`. The flag
        // used to be read out of `Instance`, and `updateState` runs on the
        // ACCEPTED solution — after this point has been evaluated — so every
        // cross()/timer() event was observed one timepoint late, the exact
        // mirror of "at that time point, the event evaluates to True".
        // `updateState` now only advances `__prev`/`__next`.
        // §5.10.3.1 "The cross() function will not generate events for
        // non-transient analyses, such as ac, dc, or noise analyses … it can
        // only generate an event after the simulation time has advanced from
        // zero." Both halves are the guard: the analysis has to be a
        // transient AND a step has to have been taken, which is what a
        // positive `dt` means everywhere else in this file. (§5.10.3.2
        // `above` is the operator that is explicitly exempt from both.)
        .cross => try self.b("S.con(if (inst.analysis_kind == .tran and inst.dt > 0.0 and ({s}) and ({s})) 1.0 else 0.0)", .{
            try crossTest(self, n, args, try std.fmt.allocPrint(self.arena, "({s}).val()", .{in})),
            try enableTest(self, "cross", args),
        }),
        // §5.10.3.3 fires at `start_time` and every `period` after it.
        // `__next` carries the schedule, but it initialises to 0.0 and is
        // only clamped up to `start_time` by `updateState`, so the clamp is
        // repeated here — without it a `timer(1n, …)` fires at t = 0.
        // §5.10.3.3's parenthetical is a CONDITION on the single fire, not
        // an aside: "the timer shall trigger only once at the specified
        // start_time (IF THE START_TIME IS IN THE FUTURE WITH RESPECT TO
        // THE CURRENT SIMULATION TIME)". Simulation time never runs
        // negative, so a negative start_time is in the past at every
        // timepoint of every analysis and the clause licenses no fire —
        // where the bare `abstime >= @max(__next, start)` fired once at the
        // origin, because `__next` clamps up from 0.0 and never down.
        //
        // ponytail: applied only when the period FOLDS non-positive. A
        // period computed during the solve is treated as periodic here, and
        // §5.10.5's `zNextTimer` reads a past start the same way ("a start
        // before the origin fires at the origin") for the periodic case.
        .timer => try self.b("S.con(if (inst.abstime >= @max(inst.{s}__next, ({s}).val()){s} and ({s})) 1.0 else 0.0)", .{
            n,
            in,
            if (timerIsOneShot(self, args))
                try std.fmt.allocPrint(self.arena, " and ({s}).val() >= 0.0", .{in})
            else
                "",
            try enableTest(self, "timer", args),
        }),
        // §5.10.3.2 "above() generates a monitored analog event to detect
        // threshold crossings in analog signals when the expression crosses
        // zero (0) from below". CROSSES, not "is above": the test is
        // edge-triggered against the last accepted value, exactly like
        // `cross`, and it was a bare `expr > 0.0` — which re-fires on every
        // solution while the expression stays positive, so a `@(above(x))`
        // latch tracked its probe instead of holding the value it sampled.
        //
        // No `.tran and dt > 0.0` guard, unlike `cross`: above() is the
        // operator §5.10.3.2 explicitly exempts from both restrictions
        // ("can generate an event during initialization", "during a dc
        // sweep, the above() function shall also generate an event when the
        // expression crosses zero from below"). The initialisation case is
        // the `__prev = 0.0` initialiser — see `emitInstance`.
        .above => try self.b("S.con(if (inst.{0s}__prev <= 0.0 and ({1s}).val() > 0.0 and ({2s})) 1.0 else 0.0)", .{
            n, in, try enableTest(self, "above", args),
        }),
        // §9.17 tasks return no value ("It does not return a value").
        // Unreachable in practice — lowering never leaves one in an eval
        // expression — but a void task read as a value is a zero, not a
        // crash.
        .bound_step, .discontinuity => try self.b("S.con(0.0)", .{}),
        .none => unreachable,
    }
}

/// §4.5.8 `transition(expr, td, rise_time, fall_time)`: the two times, as
/// emitted f64 expressions, in that order.
///
/// TWO, not one. This used to return a single first-order lag constant
/// `(rise + fall)*0.5/2.2`, which made `transition(V, 0, 4n, 8n)` and
/// `transition(V, 0, 8n, 4n)` the same filter — while §4.5.8 says the
/// output "forces all positive transitions of expr to occur over rise_time
/// and all negative transitions to occur in fall_time". Averaging them is
/// not an approximation of that sentence, it is a different filter.
///
/// §4.5.8's defaulting is a two-step fall-through and both steps are here:
///
///   "If only a positive rise_time value is specified, the simulator uses
///    it for both rise and fall times."  → `fall` defaults to `rise`.
///   "If neither rise_time nor fall_time are specified OR ARE EQUAL TO ZERO
///    (0.0), the rise and fall time default to the value defined by
///    `default_transition."  → and §10.3 scopes that to the directive
///    "which immediately precedes the transition filter".
///
/// Zero is spelled as absent by the clause itself, which is why the fold is
/// consulted and not just the argument count: `transition(x, 0, 0.0)` takes
/// the directive exactly as `transition(x)` does. A time that is not
/// foldable is left alone — it is a parameter expression, and the clause
/// conditions on the VALUE, which is a run-time fact there.
pub fn transitionTimes(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    const dflt = try defaultTransition(self);
    const rise = try transitionTime(self, args, 2, dflt orelse "0.0");
    const fall = try transitionTime(self, args, 3, dflt orelse rise);
    return .{ rise, fall };
}

pub fn transitionTime(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    if (i >= args.len) return dflt;
    // `resolve_params = false`: a zero through the DECLARED default is not
    // a zero — `transition(x, 0, tr)` with `tr` defaulting to 0.0 but
    // overridden on the model card used to take `default_transition
    // forever. Only a time that is zero WITHOUT parameters is spelled-
    // absent at compile time.
    if (self.an.foldConst(args[i], 0, false)) |c| {
        if (c.f == 0.0) return dflt;
        return f64Expr(self, args[i]); // a known-nonzero literal, as before
    }
    const e = try f64Expr(self, args[i]);
    // §4.5.8 conditions on the VALUE ("… or are equal to zero (0.0)"),
    // which for a parameter time is a run-time fact — so the fall-through
    // to `dflt` is emitted as a select. Skipped when `dflt` is the bare
    // 0.0 fallback: `zTransFrac` already reads a non-positive time as the
    // simulator's own default (an instantaneous edge), so the select would
    // choose between two spellings of the same thing.
    if (std.mem.eql(u8, dflt, "0.0")) return e;
    return std.fmt.allocPrint(self.arena, "(if (({s}) != 0.0) ({s}) else ({s}))", .{ e, e, dflt });
}

/// §10.3 the `` `default_transition `` in force AT THE CALL BEING EMITTED,
/// as an emitted f64 literal, or null when no directive precedes it.
///
/// Positional, because the clause is: "the default rise and fall times for
/// a transition filter are derived from the transition_time value of the
/// directive which IMMEDIATELY PRECEDES the transition filter." So the walk
/// is backwards from the call's own token offset and stops at the first
/// directive at or before it — which is what makes a second directive
/// supersede a first rather than being ignored by a latched value.
///
/// `ctrl_tok` is the operator call's token, set by `emitOperator` and by
/// the `updateState` loop before either asks for the times, so both sides
/// of the operator resolve the same directive.
pub fn defaultTransition(self: *Gen) Error!?[]const u8 {
    const list = self.lower.default_transitions;
    if (list.len == 0) return null;
    if (self.ctrl_tok == Mir.no_tok or self.ctrl_tok >= self.lower.tok_starts.len) return null;
    const at = self.lower.tok_starts[self.ctrl_tok];
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (list[i].at <= at) return try gen_file.fmtF64(self, list[i].time);
    }
    return null;
}

/// §4.5.9's two rate limits, for the two places that emit a `zSlew` call.
///
/// "If the max_neg_slew_rate is not specified, it defaults to the opposite
/// of the max_pos_slew_rate." The kernel takes `@abs` of the negative limit,
/// so "the opposite" is spelled by reusing the positive expression verbatim.
/// The old default of `1e300` left every falling edge UNLIMITED while the
/// rising edge was held — an asymmetry the source never asked for, and one
/// that only showed up in a transient.
pub fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
    const pos = try argF64(self, args, 1, "1e300");
    return .{ pos, try argF64(self, args, 2, pos) };
}
