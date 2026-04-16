//! Value and instruction rendering: MIR value → Zig expression text (§4.2.1 conversions).
//!
//! In: one MIR value or instruction. Out: the Zig text for it, with the §4.2.1.1/§4.2.1.2
//! integer↔real conversions made explicit.
//!
//! LRM clauses this file's code cites: §2.7, §3.2, §3.2.1, §4.2.1.1, §4.2.1.2, §4.2.11, §4.3.1, §4.3.2, §4.5, §9.4, §9.21, §9.21.1.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_render.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_setup = @import("setup.zig");
const gen_cfg = @import("cfg.zig");
const gen_unit = @import("unit.zig");
const opcode_zig = codegen.opcode_zig;
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("ir").proof;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

/// `.ipow`'s device text: `Lower.ipow32` spelled as a callable expression.
/// Its locals carry a `zp_` prefix because Zig refuses a name that shadows
/// one in ANY enclosing scope, and the enclosing function's are `x`, `model`….
pub const ipow_fn = "(struct { fn zp_f(zp_b: i64, zp_n: i64) i64 { " ++
    "if (zp_n < 0) return if (zp_b == 1) 1 else if (zp_b == -1) (if (@rem(zp_n, 2) == 0) 1 else -1) else 0; " ++
    "var zp_x: i32 = @truncate(zp_b); var zp_e = zp_n; var zp_r: i32 = 1; " ++
    "while (zp_e > 0) : (zp_e >>= 1) { if (zp_e & 1 != 0) zp_r *%= zp_x; zp_x *%= zp_x; } " ++
    "return zp_r; } }.zp_f)";

/// Integer `/` with a zero divisor defined as 0 — see `renderOp`'s `.idiv`.
const idiv_fn = "(struct { fn zd_f(zd_a: i64, zd_b: i64) i64 { " ++
    "return if (zd_b == 0) 0 else @divTrunc(zd_a, zd_b); } }.zd_f)";

// ---- value / instruction rendering --------------------------------------

/// Emit a value reference, converting per §4.2.1.1/§4.2.1.2 when the use
/// wants the other LRM type.
/// `renderVal` into a string instead of into `out`.
///
/// Rendering only ever APPENDS, so the scratch buffer is `out` itself: emit,
/// copy the tail, rewind. That keeps one growable buffer for the whole
/// emission and keeps `uses_x`/`uses_model` accounting identical to a direct
/// render — the same reserve-and-rewind trick `emitCode`'s peephole and
/// `emitUnit`'s parameter slots use.
///
/// Only for the handful of §4.5 operator inputs that have to appear inside a
/// `{s}` of a kernel call; everything else renders straight into `out`.
pub fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8 {
    const at = self.out.items.len;
    try renderVal(self, v, want);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    return s;
}

pub fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void {
    const v = self.an.rv(v0);
    const def = self.mir.valueDef(v);
    if (def == .undef) {
        // ponytail: undefined operands share the slot initializer's spelling.
        try self.b("{s}", .{gen_unit.zeroOf(want)});
        return;
    }
    if (self.an.tyOf(v) == want) return renderValueRef(self, v);
    switch (want) {
        .real => {
            if (def == .int_const) {
                try self.b("S.con({s})", .{try gen_file.fmtF64(self, @floatFromInt(def.int_const))});
                return;
            }
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try renderValueRef(self, v);
            try self.b(")))", .{});
        },
        .int => {
            if (def == .float_const) {
                // `lossyCast`, not an isFinite branch: `isFinite(1e300)` is
                // true and the old `@intFromFloat` panicked on it. Saturate
                // exactly like the emitted runtime cast below, so folding a
                // constant cannot change what the device would compute.
                const x = def.float_const;
                try self.b("{d}", .{std.math.lossyCast(i64, @round(x))});
                return;
            }
            // §2.7: a string LITERAL used as an operand is the unsigned
            // base-256 integer its bytes spell, which is what a §9.4
            // numeric conversion applied to one prints — `$strobe("%d",
            // "\n")` is 10. Lowering converts one everywhere it can see a
            // numeric context; the format string is the one context it
            // cannot, since the specifier is only paired with its operand
            // here (cg_display.appendConv).
            if (self.an.tyOf(v) == .str) return switch (def) {
                .str_const => |s| self.b("@as(i64, {d})", .{Lower.strToInt(s, 64)}),
                // Not a literal, so §3.3 leaves it with no numeric value.
                .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => self.b("@as(i64, 0)", .{}),
            };
            float_lanes.pinLanes(self, v); // a real→int collapse is a scalar decision
            // Saturating (§4.2.1.1 only defines the rounding): the device
            // is built ReleaseFast by real hosts, where `@intFromFloat` of
            // an out-of-range or NaN value is UB, not a trap.
            try self.b("std.math.lossyCast(i64, @round((", .{});
            try renderValueRef(self, v);
            try self.b(").val()))", .{});
        },
        .str => try self.b("\"\"", .{}),
    }
}

/// LRM §4. Constants → `S.con(literal)`, parameters → `model.<name>`, node
/// probes → `x[@intFromEnum(U.<node>)]`, instruction results → the
/// UNIT-LOCAL slot name (never `v{MIR index}` — naming.zig's ABSOLUTE RULE).
pub fn renderValueRef(self: *Gen, v: Mir.Value) Error!void {
    const i = @intFromEnum(v);
    // Out of the run entirely: `setup` wrote the field when the model card,
    // the instance or its temperature last changed.
    if (i < self.an.nv and self.plan.isRoot(v)) {
        const f = try gen_setup.rootRef(self, v, false);
        return if (self.an.vty[i] == .int) self.b("{s}", .{f}) else self.b("S.con({s})", .{f});
    }
    // Hoisted: computed once by the common declaration, read here out of the
    // cache the body opened with — see "the shared core" in `Plan`.
    if (i < self.an.nv and self.plan.cached(v)) return self.b("c.f{d}", .{self.core.lo_idx[i]});
    if (i < self.an.nv and self.plan.slot[i] != none_u32) {
        gen_unit.probeUse(self, self.plan.slot[i]);
        try gen_unit.writeSlotRef(self, i);
        return;
    }
    switch (self.mir.valueDef(v)) {
        .undef => try self.b("S.con(0.0)", .{}),
        .float_const => |x| try self.b("S.con({s})", .{try gen_file.fmtF64(self, x)}),
        .int_const => |x| try self.b("@as(i64, {d})", .{x}),
        .str_const => |s| try self.b("\"{f}\"", .{std.zig.fmtString(s)}),
        .param_ref => |p| {
            self.uses_model = true;
            switch (Analysis.tyOfParam(self.lowered.params.items[p].ty)) {
                .real => try self.b("S.con(model.{s})", .{self.names.p_names[p]}),
                .int, .str => try self.b("model.{s}", .{self.names.p_names[p]}),
            }
        },
        .block_param => |u| {
            self.uses_x = true;
            // Every probe the core or a unit reads needs its lane: what the
            // op around it does with the lane is not looked at, so this is
            // the sound superset `deriv_reads` is.
            self.deriv_reads |= gen_dispatch.uBit(u);
            try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[u]});
        },
        .inst_result => |inst| try renderInst(self, inst),
    }
}

/// Already computed as a statement (slot), a cache field, or a setup
/// field — rendering it is a name, not an expression. The stop condition
/// `eagerSafe`, `maskCmp` and `foldHidesSlot` share.
pub fn materialized(self: *const Gen, v: Mir.Value) bool {
    const i = @intFromEnum(v);
    return i < self.an.nv and
        (self.plan.isRoot(v) or self.plan.cached(v) or self.plan.slot[i] != none_u32);
}

/// The select cond as an INLINE real comparison — unslotted, so rendering
/// it in mask space leaves no unread `const` behind. Slotted predicates
/// and int comparisons take the `S.con(@floatFromInt(..))` fallback.
fn maskCmp(self: *Gen, cond: Mir.Value) ?Mir.Inst {
    const v = self.an.rv(cond);
    if (materialized(self, v)) return null;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return null;
    return switch (self.mir.instOp(def.inst_result)) {
        .flt, .fgt, .fle, .fge, .feq, .fne => def.inst_result,
        else => null, // else: only the six §4.2.5 REAL comparisons have an `S` mask form
    };
}

pub fn renderInst(self: *Gen, inst: Mir.Inst) Error!void {
    const row = self.mir.instRow(inst);
    const op = row.op;
    if (op == .call) return gen_call.emitCall(self, inst);
    if (op == .phi) return self.b("S.con(0.0)", .{}); // materialised as a var
    if (op == .fload or op == .iload) return renderLoad(self, inst);

    // A whole derivative-free subtree comes out as ONE `S.con` over plain
    // f64 arithmetic, which is contract.zig's rule for physics code:
    // "everything not depending on x stays plain f64". Every S op it
    // replaces was carrying an n_u-wide zero the host cannot fold away
    // under `@setFloatMode(.strict)`. `f64Const` is the whole test — it
    // succeeds only on literals, parameters and arithmetic over them.
    const res = self.mir.instResult(inst);
    if (res != .undef and self.an.vty[@intFromEnum(res)] == .real and self.an.dFree(res)) {
        if (try gen_call.f64Const(self, res, 0, true)) |s| return self.b("S.con({s})", .{s});
    }

    const a: Mir.Value = @enumFromInt(row.a);
    const b2: Mir.Value = @enumFromInt(row.b);
    const c: Mir.Value = @enumFromInt(row.c);

    // §4.2.12 the value-form conditional stays LAZY by default: proof.zig
    // treats the condition as a guard on the arms, so `x > 0 ? ln(x) : 0`
    // is accepted — evaluating both arms would run ln(x) with x <= 0,
    // which is UB under @setFloatMode(.optimized). Do not "simplify" this
    // to a select of two pre-computed values.
    //
    // EXCEPT where laziness buys nothing: in a `.strict` unit every f64
    // op is IEEE-defined, so a real select whose inline arms contain no
    // call and no domain-restricted op (proof.domainOf == .all — which
    // also excludes idiv/imod/fmod, the hard-UB ones) may evaluate BOTH
    // arms and pick with the contract's `sel` mask primitive. A dead
    // arm's NaN/inf is discarded by the pick. That removes the branch the
    // host's predictor would eat per Newton iteration (T7) and is what a
    // lane-parallel S needs — `.val()` has no single answer across lanes.
    if (op == .select) {
        const want = self.an.vty[@intFromEnum(self.mir.instResult(inst))];
        if (want == .real and self.float.strict and
            float_lanes.eagerSafe(self, b2, 0) and float_lanes.eagerSafe(self, c, 0) and
            !float_lanes.eagerCostly(self, b2, 0) and !float_lanes.eagerCostly(self, c, 0))
        {
            // Best mask first: an inline real comparison renders in S
            // space (`lt`/`le`/`eq`) and is TRUE PER LANE on a vector S.
            // gt/ge are operand swaps; ne swaps the select's arms — the
            // contract carries exactly lt/le/eq/sel. ifconv peels the
            // `toBool` wrapper, so the cond IS the bare comparison here.
            // The MASK, best form first: an inline real comparison
            // renders in S space (TRUE PER LANE on a vector S; ne swaps
            // the arms — the contract carries exactly lt/le/eq/sel).
            // Otherwise the emitted predicate is a 0/1 i64 (or a real S
            // tested against zero): still branchless, but the int form is
            // lane-UNIFORM — fine for a scalar S, pinned on a vector S.
            var swap_arms = false;
            if (maskCmp(self, a)) |cmp| {
                const d = self.mir.instData(cmp).binary;
                const swap_ops = d.op == .fgt or d.op == .fge;
                swap_arms = d.op == .fne;
                const prim: []const u8 = switch (d.op) {
                    .flt, .fgt => "lt",
                    .fle, .fge => "le",
                    .feq, .fne => "eq",
                    else => unreachable, // else: `maskCmp` returns only the six real comparisons
                };
                try self.b("((", .{});
                try renderVal(self, if (swap_ops) d.rhs else d.lhs, .real);
                try self.b(").{s}(", .{prim});
                try renderVal(self, if (swap_ops) d.lhs else d.rhs, .real);
                try self.b(")).sel(", .{});
            } else if (self.an.tyOf(self.an.rv(a)) == .int) {
                float_lanes.pinLanes(self, a);
                try self.b("(S.con(@floatFromInt(", .{});
                try renderVal(self, a, .int);
                try self.b("))).sel(", .{});
            } else {
                try self.b("(", .{});
                try renderVal(self, a, .real);
                try self.b(").sel(", .{});
            }
            try renderVal(self, if (swap_arms) c else b2, .real);
            try self.b(", ", .{});
            try renderVal(self, if (swap_arms) b2 else c, .real);
            try self.b(")", .{});
            return;
        }
        try self.b("(if (", .{});
        try gen_cfg.renderCond(self, a);
        try self.b(") ", .{});
        try renderVal(self, b2, want);
        try self.b(" else ", .{});
        try renderVal(self, c, want);
        try self.b(")", .{});
        return;
    }
    return renderOp(self, op, a, b2, self.an.vty[@intFromEnum(self.mir.instResult(inst))]);
}

// ---- §3.2.2 memory-backed arrays ------------------------------------------
//
// Every version of array `id` is ONE local `a<id>: [len]T`: `anew` fills it,
// `store` writes one element, a phi joins nothing (the versions share the
// storage), and a load reads one element where it stands — `plan/unit.zig`
// never inlines a load past a later store. `T` is `S` only when some load
// reads a derivative a store put there (`Gen.arr_s`); otherwise the storage
// is plain `f64`/`i64` and a store keeps the value alone. A version read out
// of the core's cache (the held final value) is the core's plain field.
//
// §5.10 a PLAIN held array is copy-on-write (`cow`): its loads read through
// `p<id>`, which starts at the `Instance` field, and the first store copies
// the field into `a<id>` and repoints `p<id>` there (`zArrW`). So an
// evaluation that stores nothing copies nothing — and `eval`, whose core
// skips the stores only the end-of-block value observes
// (`plan_core.heldOnly`, the `held` flag), mostly stores nothing.

/// Is array `id`'s storage plain `f64`/`i64` rather than `S`?
fn arrPlain(self: *const Gen, id: u32) bool {
    return self.lowered.mem_arrays.items[id].ty == .integer or !self.arr_s[id];
}

/// Is array `id` read in place from its `Instance` field until first written?
pub fn cow(self: *const Gen, id: u32) bool {
    return self.lowered.mem_arrays.items[id].held != none_u32 and arrPlain(self, id);
}

/// The element type array `id` is stored as.
pub fn arrElemTy(self: *const Gen, id: u32) []const u8 {
    if (self.lowered.mem_arrays.items[id].ty == .integer) return "i64";
    return if (self.arr_s[id]) "S" else "f64";
}

/// Write a pointer to the storage array version `v` is read from; true when
/// it holds plain values (a cached version always does).
fn arrRef(self: *Gen, v0: Mir.Value) Error!bool {
    const v = self.an.rv(v0);
    if (self.plan.cached(v)) {
        try self.b("&c.f{d}", .{self.core.lo_idx[@intFromEnum(v)]});
        return true;
    }
    const id = self.an.arrOf(v).?;
    try self.b("{s}{d}", .{ if (cow(self, id)) "p" else "&a", id });
    return arrPlain(self, id);
}

/// `a[i]`, with §3.2.2's zero for an index outside the array (`zArrLd`).
pub fn renderLoad(self: *Gen, inst: Mir.Inst) Error!void {
    const d = self.mir.instData(inst).load;
    if (d.op == .iload) {
        try self.b("zArrLd(i64, ", .{});
        _ = try arrRef(self, d.arr);
        try self.b(", ", .{});
        try renderVal(self, d.index, .int);
        return self.b(", 0)", .{});
    }
    const at = self.out.items.len;
    try self.b("zArrLd(S, ", .{});
    if (try arrRef(self, d.arr)) {
        // Plain storage: re-spell the head, the index follows either way.
        const name = try self.arena.dupe(u8, self.out.items[at + "zArrLd(S, ".len ..]);
        self.out.shrinkRetainingCapacity(at);
        try self.b("S.con(zArrLd(f64, {s}, ", .{name});
        try renderVal(self, d.index, .int);
        return self.b(", 0.0))", .{});
    }
    try self.b(", ", .{});
    try renderVal(self, d.index, .int);
    try self.b(", S.con(0.0))", .{});
}

/// The statement an `anew` or a `store` is, at its place in the block.
pub fn emitArrayStmt(self: *Gen, inst: Mir.Inst, depth: u32) Error!void {
    try self.ind(depth);
    switch (self.mir.instData(inst)) {
        .anew => |d| {
            const m = self.lowered.mem_arrays.items[d.array];
            const plain = arrPlain(self, d.array);
            if (m.held == none_u32) {
                const zero: []const u8 = if (m.ty == .integer) "0" else if (plain) "0.0" else "S.con(0.0)";
                return self.b("@memset(&a{d}, {s});\n", .{ d.array, zero });
            }
            // §5.10 a held array starts from what the last accepted
            // evaluation left in its `Instance` field.
            self.uses_inst = true;
            const f = self.names.held_names[m.held];
            if (plain) return self.b("p{d} = &inst.{s};\n", .{ d.array, f });
            return self.b("for (&a{d}, inst.{s}) |*zd, zs| zd.* = S.con(zs);\n", .{ d.array, f });
        },
        .store => |d| {
            const id = self.an.arrOf(d.arr).?;
            const m = self.lowered.mem_arrays.items[id];
            const r = self.an.rv(self.mir.instResult(inst));
            if (self.emitting_common and self.core.held_only.len != 0 and self.core.held_only[@intFromEnum(r)]) {
                self.uses_held = true;
                try self.b("if (held) ", .{});
            }
            const ty = arrElemTy(self, id);
            // A store made from another store's version writes storage that
            // one has already copied in; the seed, or a join that may be it,
            // goes through `zArrW`.
            const after_store = switch (self.mir.valueDef(self.an.rv(d.arr))) {
                .inst_result => |di| self.mir.instOp(di) == .store,
                else => false, // else: an array version is an instruction result
            };
            if (cow(self, id) and !after_store)
                try self.b("zArrSt({s}, zArrW({s}, {d}, &a{d}, &p{d}), ", .{ ty, ty, m.len, id, id })
            else
                try self.b("zArrSt({s}, &a{d}, ", .{ ty, id });
            try renderVal(self, d.index, .int);
            try self.b(", ", .{});
            if (m.ty == .integer) {
                try renderVal(self, d.value, .int);
            } else if (arrPlain(self, id)) {
                // No load reads this element's derivative, so the value alone
                // is kept — a scalar collapse of an x-dependent value.
                float_lanes.pinLanes(self, d.value);
                try self.b("(", .{});
                try renderVal(self, d.value, .real);
                try self.b(").val()", .{});
            } else try renderVal(self, d.value, .real);
            return self.b(");\n", .{});
        },
        .unary, .binary, .ternary, .phi, .branch, .jump, .call, .load => unreachable, // `emitBlockInsts` sends only array versions
    }
}

/// A held array's end-of-block version as the core's plain `[len]f64`/`i64`.
pub fn renderArrayOut(self: *Gen, v: Mir.Value) Error!void {
    const id = self.an.arrOf(v).?;
    if (cow(self, id)) return self.b("p{d}.*", .{id});
    if (arrPlain(self, id)) return self.b("a{d}", .{id});
    try self.b("zArrVal(S, {d}, &a{d})", .{ self.lowered.mem_arrays.items[id].len, id });
}

/// One opcode, rendered. Shared with the `$`-prefixed spellings of the same
/// math functions (IEEE 1364 §17.11, carried into Verilog-AMS ch9).
pub fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void {
    // §3.3.1 string relations: lowering types both operands `.string` and
    // picks the integer comparison opcodes for them.
    if (self.an.tyOf(self.an.rv(a)) == .str or self.an.tyOf(self.an.rv(b2)) == .str) {
        const rel: ?[]const u8 = switch (op) {
            .ieq, .feq => "== 0",
            .ine, .fne => "!= 0",
            .ilt, .flt => "< 0",
            .ile, .fle => "<= 0",
            .igt, .fgt => "> 0",
            .ige, .fge => ">= 0",
            else => null, // else: §3.3.1 relates strings with these six; any other op falls to its numeric form
        };
        if (rel) |r| {
            try self.b("@as(i64, @intFromBool(zStrCmp(", .{});
            try renderVal(self, a, .str);
            try self.b(", ", .{});
            try renderVal(self, b2, .str);
            try self.b(") {s}))", .{r});
            return;
        }
    }
    switch (op) {
        // §4.2.4 real arithmetic. The mixed case — ONE operand
        // derivative-free — reaches the scalar half of the contract
        // (`scale`, `addC`) instead of the dual half, which is where the
        // saving is: `x.mul(S.con(k))` costs n_u multiplies against
        // `splat(0)` plus an n_u-wide add that `.strict` will not fold,
        // where `x.scale(k)` costs n_u multiplies and nothing else.
        //
        // Every rewrite here is value-preserving under IEEE 754: `a - k` is
        // defined as `a + (-k)`, and `k - a` as `(-a) + k`. `fdiv` has no
        // scalar form in the primitive set and `a * (1/k)` is NOT `a / k`,
        // so it keeps the dual op — see `renderOp`'s callers in the header.
        .fadd, .fsub, .fmul => {
            if (self.an.dFree(b2)) {
                try self.b("(", .{});
                try renderVal(self, a, .real);
                try self.b(").{s}(", .{if (op == .fmul) "scale" else "addC"});
                if (op == .fsub) try writeNegConst(self, b2) else try writeConst(self, b2);
                return self.b(")", .{});
            }
            if (self.an.dFree(a)) {
                try self.b("(", .{});
                try renderVal(self, b2, .real);
                // k - b: negate first, so the constant still arrives through
                // `addC` and the derivative costs one negation.
                try self.b("){s}.{s}(", .{
                    if (op == .fsub) ".neg()" else "",
                    if (op == .fmul) "scale" else "addC",
                });
                try writeConst(self, a);
                return self.b(")", .{});
            }
            try method2(self, a, switch (op) {
                .fadd => "add",
                .fsub => "sub",
                else => "mul", // else: the prong is `.fadd, .fsub, .fmul`
            }, b2);
        },
        // `fdiv` keeps the dual op (see above), and §4.3.1/§4.3.2 math is one
        // `S` method or one kernel per opcode — `opcode_zig`'s `s` column.
        // §4.3.1 Table 4-14 names the C library's expm1/log1p, which exist
        // BECAUSE exp(x)-1 and log(1+x) cancel for small x, so they are
        // scalar PRIMITIVES there, not helpers composed from exp/log — a
        // composed helper is the exact form the clause tells us to avoid.
        // zFmod truncates a `.val()` quotient, zFloor/zCeil collapse to
        // `S.con` of a `.val()`, zHypot linearizes around `.val()` of both
        // operands and zAtan2 branches on their signs: all five pin lanes
        // (the `pins_lanes` column).
        // Resolved at comptime: an opcode here whose row says `.custom` is a
        // compile error, not a runtime surprise.
        inline .fdiv, .fneg, .fmod, .sqrt, .exp, .ln, .sin, .cos, .tanh, .sinh, .cosh, .atan,
        .fabs, .expm1, .ln1p, .log10, .tan, .asin, .acos, .asinh, .acosh, .atanh, .floor, .ceil,
        .hypot, .atan2, .fmin, .fmax,
        => |o| {
            const r = comptime opcode_zig.get(o);
            const binary = comptime Mir.opClass(o) == .binary;
            if (r.pins_lanes) {
                float_lanes.pinLanes(self, a);
                if (binary) float_lanes.pinLanes(self, b2);
            }
            switch (r.s) {
                .method => |m| if (binary) try method2(self, a, m, b2) else try method1(self, a, m),
                .helper => |h| if (binary) try helper2(self, h, a, b2) else try helper1(self, h, a),
                .custom => @compileError("renderOp: opcode_zig gives `" ++ @tagName(o) ++ "` no S spelling"),
            }
        },
        .pow => {
            // The scalar interface only has pow(S, f64); a constant exponent
            // (the overwhelming case) uses it, anything else goes through
            // `zPow`. `resolve_params = false` — the fold's own rule: only
            // a Model DEFAULT may look through a parameter. Folding with
            // `true` here baked the DECLARED default into `.pow(k)` and a
            // model-card override was silently ignored (value AND
            // Jacobian). A parameter exponent renders as a value
            // (`S.con(model.<p>)`) and `zPow` handles it — a model param
            // is solve-constant, so its derivative half is zero and the
            // c·a^(c−1) treatment is intact. `UnitPlan.foldedExponent` is
            // the exact mirror of this test; change both or neither.
            // A SOLVE-CONSTANT exponent takes the same `pow(S, f64)` route
            // as a literal one, with the f64 spelled as an expression
            // instead of a number. `dFree` is the whole test: the exponent
            // carries no derivative, so `zPow`'s ∂/∂y machinery has nothing
            // to build and its `.val()` on the BASE — which is x-dependent
            // and would pin lanes — buys nothing either. This is the case
            // that fires for every junction grading coefficient in every
            // SPICE model (`pow(1 - v/pj, 1 - mj)`, `pow(vgon, nc)`), so it
            // is worth taking off the pinning path: `S.pow` is one protocol
            // call a lane-parallel S implements per lane, where `zPow`
            // collapses to lane 0. `UnitPlan.foldedExponent` still marks the
            // exponent live here (it only skips a LITERAL fold), so the
            // "change both or neither" mirror is intact.
            const par_exp: ?[]const u8 = if (self.an.foldConst(b2, false) == null and self.an.dFree(b2))
                try gen_call.f64Const(self, b2, 1, true)
            else
                null;
            if (self.an.foldConst(b2, false)) |k| {
                try self.b("(", .{});
                try renderVal(self, a, .real);
                try self.b(").pow({s})", .{try gen_file.fmtF64(self, k.f)});
            } else if (par_exp) |s| {
                try self.b("(", .{});
                try renderVal(self, a, .real);
                try self.b(").pow({s})", .{s});
            } else {
                // zPow linearizes around `.val()` of BOTH operands
                // (§4.3.1's negative-base/integer-y steering included),
                // so either being x-dependent pins lanes — the batch
                // gate's fixture-158 catch.
                float_lanes.pinLanes(self, a);
                float_lanes.pinLanes(self, b2);
                // ∂/∂y is dropped when the exponent cannot move with the
                // solve — `b.addC(-y)` is then value-0 and derivative-0, so
                // the term it scales contributes nothing and the `ln` that
                // built its coefficient is pure cost. Every junction
                // exponent in every SPICE model is a model PARAMETER, so
                // this is the case that fires.
                try self.b("zPow(S, ", .{});
                try renderVal(self, a, .real);
                try self.b(", ", .{});
                try renderVal(self, b2, .real);
                try self.b(", {})", .{!self.an.dFree(b2)});
            }
        },
        // §4.2.1 conversions
        .if_cast => {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try renderVal(self, a, .int);
            try self.b(")))", .{});
        },
        .fi_cast => {
            // §4.2.1.1 rounds; overflow is the language's silence and the
            // artifact's UB under ReleaseFast — `lossyCast` (saturate,
            // NaN→0) is the defined answer, and `Analysis.asI64` folds
            // with the identical rule.
            float_lanes.pinLanes(self, a); // a real→int collapse is a scalar decision
            try self.b("std.math.lossyCast(i64, @round((", .{});
            try renderVal(self, a, .real);
            try self.b(").val()))", .{});
        },
        .opt_barrier => try renderVal(self, a, res_ty),
        // §5.6.1.2 path-integrated reactive latches: value only, no
        // derivative, FIXED across one Newton attempt (advanced by
        // stateCtl(.commit) at the operating-point exit and per accepted
        // transient step). The residual is one smooth function per
        // attempt, so its AD Jacobian is exact — the coefficient's dA
        // enters only multiplied by (B − pb), which is zero at every
        // committed point (AC reads the pure capacitance form there).
        .path_prev, .path_acc => {
            const v = self.an.rv(a);
            const fam = if (op == .path_prev) self.core.prev_vals else self.core.acc_vals;
            const k = for (fam, 0..) |fv, fk| {
                if (fv == v) break fk;
            } else unreachable; // plan_core.plan queued every site
            self.uses_inst = true; // the latch read keeps `inst` in the signature
            try self.b("S.con(inst.{s}__{d})", .{ @as([]const u8, if (op == .path_prev) "pb" else "pq"), k });
        },
        // §3.2 integer arithmetic, at §3.2's 32-bit 2's complement width —
        // see `Lower.wrap32`, which is the definition this and the two
        // constant folds all implement. `%` (remainder) is never wider than
        // its operands and needs no wrap; `/` overflows for exactly one pair,
        // -2^31 / -1, whose 2's complement answer is -2^31 again.
        .iadd => try intBin32(self, a, "+%", b2),
        .isub => try intBin32(self, a, "-%", b2),
        .imul => try intBin32(self, a, "*%", b2),
        .idiv => {
            // A divisor the prover could not show non-zero is ACCEPTED
            // (proof checkDomain, §4.2.4 has no zero rule for `/`), and
            // `@divTrunc(x, 0)` is illegal behavior, so it goes through
            // `idiv_fn`: x / 0 is 0 (IEEE 1364's 'bx has no analog value),
            // announced at compile time by the prover's W0653. A non-zero
            // literal divisor keeps the bare form.
            const lit = self.mir.valueDef(self.an.rv(b2));
            const bare = lit == .int_const and lit.int_const != 0;
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, if (bare) "@divTrunc" else idiv_fn, a, b2);
            try self.b(")))", .{});
        },
        .imod => try intCall2(self, "@rem", a, b2),
        .ineg => {
            try self.b("@as(i64, @as(i32, @truncate(-%(", .{});
            try renderVal(self, a, .int);
            try self.b("))))", .{});
        },
        .iabs => try intCall1(self, "zIabs", a),
        .imin => try intCall2(self, "@min", a, b2),
        .imax => try intCall2(self, "@max", a, b2),
        // `Lower.ipow32`, inline: a helper in `ops_txt` would grow every
        // device for an operator few of them use. An anonymous struct and not
        // a labelled block, so two nested `**` cannot collide on a label.
        .ipow => try intCall2(self, ipow_fn, a, b2),
        // §4.2.5/§4.2.7 relational + equality — integer 0/1
        .flt => try cmpReal(self, a, "<", b2),
        .fgt => try cmpReal(self, a, ">", b2),
        .fle => try cmpReal(self, a, "<=", b2),
        .fge => try cmpReal(self, a, ">=", b2),
        .feq => try cmpReal(self, a, "==", b2),
        .fne => try cmpReal(self, a, "!=", b2),
        .ilt => try cmpInt(self, a, "<", b2),
        .igt => try cmpInt(self, a, ">", b2),
        .ile => try cmpInt(self, a, "<=", b2),
        .ige => try cmpInt(self, a, ">=", b2),
        .ieq => try cmpInt(self, a, "==", b2),
        .ine => try cmpInt(self, a, "!=", b2),
        // §4.2.8 logical
        .logand, .logor => {
            try self.b("@as(i64, @intFromBool((", .{});
            try renderVal(self, a, .int);
            try self.b(") != 0 {s} (", .{if (op == .logand) "and" else "or"});
            try renderVal(self, b2, .int);
            try self.b(") != 0))", .{});
        },
        .lognot => {
            try self.b("@as(i64, @intFromBool((", .{});
            try renderVal(self, a, .int);
            try self.b(") == 0))", .{});
        },
        // §4.2.9 bitwise
        .bitand => try intBin(self, a, "&", b2),
        .bitor => try intBin(self, a, "|", b2),
        .bitxor => try intBin(self, a, "^", b2),
        .bitxnor => {
            try self.b("~(", .{});
            try intBin(self, a, "^", b2);
            try self.b(")", .{});
        },
        .bitnot => {
            try self.b("~(", .{});
            try renderVal(self, a, .int);
            try self.b(")", .{});
        },
        // §4.2.11 shifts. `<<` zero-fills from the right on its own; the
        // truncation is §3.2's width, which is what makes `1 << 31` negative
        // and `1 << 32` zero. `zShl` wraps `std.math.shl` — which defines an
        // over-wide shift as 0 rather than as UB — with the unsigned-count
        // reading a NEGATIVE count needs (see the helper).
        .shl => {
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, "zShl", a, b2);
            try self.b(")))", .{});
        },
        // §4.2.11: "Both the << and >> shift operators fill the vacated bit
        // positions with zeroes (0)." A zero fill only means something
        // against a WIDTH, and §3.2.1 fixes the Verilog-A `integer` at 32
        // bits — so `>>` is not `std.math.shr(i64, ...)`, which sign-fills.
        .shr => try shrLogical(self, a, b2),
        // §3.2.2 array ops are rendered by `renderLoad`/`emitArrayStmt`.
        .phi, .select, .call, .branch, .jump, .anew, .fload, .iload, .store => unreachable,
    }
}

/// Would folding `v` to a single number leave a materialised temporary with
/// no reader? `foldConst` collapses a subtree in one step and knows nothing
/// about slots, and `unit_plan` already emitted a declaration for every one
/// of them — an unread `const` is a Zig compile error, not a missed
/// optimisation.
///
/// Only the shapes `foldConst` itself walks: anything else it declines
/// anyway, so answering `true` there costs nothing.
pub fn foldHidesSlot(self: *Gen, v0: Mir.Value, depth: u32) bool {
    if (depth > 32) return true;
    const v = self.an.rv(v0);
    if (depth > 0 and materialized(self, v)) return true;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const row = self.mir.instRow(def.inst_result);
    return switch (Mir.opClass(row.op)) {
        .unary => foldHidesSlot(self, @enumFromInt(row.a), depth + 1),
        .binary => foldHidesSlot(self, @enumFromInt(row.a), depth + 1) or
            foldHidesSlot(self, @enumFromInt(row.b), depth + 1),
        .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => true,
    };
}

/// The f64 value of a DERIVATIVE-FREE operand, written in place. Callers
/// check `dFree` first; this only decides how to spell it.
///
/// Preferred spelling is the arithmetic itself (`model.is`, `(model.n) *
/// (t0.val())`). The fallback reads the value out of the S the generator
/// would have built anyway, which is what `$temperature` and every
/// transcendental of a parameter need — neither has a plain-f64 spelling
/// that a GPU can execute (`devSafe`), but both are still constants as far
/// as the derivative is concerned.
///
/// Depth 1, not 0: `v` is an OPERAND, so naming its own slot is exactly
/// what is wanted. Depth 0 is reserved for `renderInst` asking about the
/// value it is declaring, where naming that slot is a self-reference.
fn writeConst(self: *Gen, v: Mir.Value) Error!void {
    if (try gen_call.f64Const(self, v, 1, true)) |s| return self.b("{s}", .{s});
    try self.b("(", .{});
    try renderVal(self, v, .real);
    try self.b(").val()", .{});
}

/// `writeConst` negated, for `a - k` rendered as `a.addC(-k)`. A literal
/// negates in the formatter rather than picking up a `-(...)` wrapper,
/// because `addC(-1.0)` is the spelling a reader expects.
fn writeNegConst(self: *Gen, v: Mir.Value) Error!void {
    // Same guard as `f64Const`: negating the folded number is only legal
    // where the fold itself is.
    if (!foldHidesSlot(self, v, 0)) {
        if (self.an.foldConst(v, false)) |k| return self.b("{s}", .{try gen_file.fmtF64(self, -k.f)});
    }
    try self.b("-(", .{});
    try writeConst(self, v);
    try self.b(")", .{});
}

fn method1(self: *Gen, a: Mir.Value, name: []const u8) Error!void {
    try self.b("(", .{});
    try renderVal(self, a, .real);
    try self.b(").{s}()", .{name});
}

fn method2(self: *Gen, a: Mir.Value, name: []const u8, b2: Mir.Value) Error!void {
    try self.b("(", .{});
    try renderVal(self, a, .real);
    try self.b(").{s}(", .{name});
    try renderVal(self, b2, .real);
    try self.b(")", .{});
}

pub fn helper1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    try self.b("{s}(S, ", .{name});
    try renderVal(self, a, .real);
    try self.b(")", .{});
}

pub fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    try self.b("{s}(S, ", .{name});
    try renderVal(self, a, .real);
    try self.b(", ", .{});
    try renderVal(self, b2, .real);
    try self.b(")", .{});
}

pub fn intBin(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("((", .{});
    try renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try renderVal(self, b2, .int);
    try self.b("))", .{});
}

/// The same operation, at §3.2's width: `Lower.wrap32`, emitted. The `%`
/// wrapping ops below it are still needed — an i64 `+` that overflowed would
/// PANIC before this could truncate it — so the two together are "wrap at 64,
/// keep 32", which for in-range operands is the 32-bit answer. `intBin` is
/// left un-wrapped for the bitwise ops that cannot leave the range.
pub fn intBin32(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("@as(i64, @as(i32, @truncate(", .{});
    try intBin(self, a, opx, b2);
    try self.b(")))", .{});
}

pub fn intCall1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    try self.b("{s}(", .{name});
    try renderVal(self, a, .int);
    try self.b(")", .{});
}

/// §9.5.4.2 one `zScan*` call: `(src, fmt)` for the count, plus the item
/// index for the three item flavours. `want` is the type the RESULT lands in,
/// so only the real flavour needs the `S.con` wrapper the scalar interface
/// requires — the other two are already the plain Zig types their slots hold.
pub fn emitScan(self: *Gen, fn_name: []const u8, args: []const Mir.Value, want: VTy) Error!void {
    if (want == .real) try self.b("S.con(", .{});
    try self.b("{s}(", .{fn_name});
    try renderVal(self, if (args.len > 0) args[0] else .undef, .str);
    try self.b(", ", .{});
    try renderVal(self, if (args.len > 1) args[1] else .undef, .str);
    if (args.len > 2) {
        try self.b(", ", .{});
        try renderVal(self, args[2], .int);
    }
    try self.b(")", .{});
    if (want == .real) try self.b(")", .{});
}

/// §9.13 one probabilistic draw. `$rng$auto` is the seedless form's
/// `Instance` latch and reads a field; every other name is a `rng_kernels.zig`
/// call taking the i64 seed and its real parameters.
pub fn emitRng(self: *Gen, c: Mir.Callee, args: []const Mir.Value) Error!void {
    // A draw is one scalar per CALL, not per lane: a batch eval draws once
    // where N scalar evals draw N times. Pins unconditionally.
    float_lanes.pinCrossing(self);
    switch (c) {
        .@"$rng$auto" => {
            // §9.13.1's "internal seed", which "gets updated every time the call
            // ... is made" — by `updateState` on the accepted step, never here.
            self.uses_inst = true;
            const site = intArg(self, args, 0) orelse 0;
            return self.b("S.con(@floatFromInt(inst.rng_auto[{d}]))", .{site});
        },
        .@"$rng$check" => {
            if (args.len != 4) return gen_call.abort(self, "malformed RNG validation effect", .{});
            try self.b("S.con(zRngCheck(S.val(", .{});
            try renderVal(self, args[0], .real);
            try self.b("), {d}, S.val(", .{intArg(self, args, 1) orelse return gen_call.abort(self, "missing RNG validation rules", .{})});
            try renderVal(self, args[2], .real);
            try self.b("), S.val(", .{});
            try renderVal(self, args[3], .real);
            return self.b(")))", .{});
        },
        else => {}, // else: a distribution draw — `emitCall` routes only the `$rng$` tags here, and every other one is a kernel
    }
    const tail = @tagName(c)["$rng$".len..];
    // `zRngIUniform`, `zRngChiSquare`, … — the kernel's camel spelling of the
    // callee's tail, so the two lists cannot drift apart by a typo.
    var fn_name: std.ArrayList(u8) = .empty;
    defer fn_name.deinit(self.gpa);
    try fn_name.appendSlice(self.gpa, "zRng");
    var up = true;
    for (tail) |ch| {
        if (ch == '_') {
            up = true;
            continue;
        }
        try fn_name.append(self.gpa, if (up) std.ascii.toUpper(ch) else ch);
        up = false;
    }
    try self.b("S.con({s}(", .{fn_name.items});
    try renderVal(self, if (args.len > 0) args[0] else .zero, .int);
    for (args[@min(1, args.len)..]) |a| {
        try self.b(", ", .{});
        try renderVal(self, a, .real);
        try self.b(".val()", .{});
    }
    try self.b("))", .{});
}

/// §9.21 `$table_model`, in the shape `Lower.lowerTableModel` rewrote it:
///
///     (ND, NP, NCOL, dep, "<interp/extrap>", snapshot_site, previous_call, in₀…, row₀…)
///
/// Every §9.21.1/§9.21.2 decision was made in lowering, where the control
/// string and the array declarations exist, so this is a transcription: the
/// four counts and the extrapolation characters become `zTable`'s comptime
/// arguments, the lookup point an `[ND]S` and the sample block one flat
/// `[NP*NCOL]f64`.
///
/// The samples go in as f64 and the lookup point as `S`. That is not a
/// simplification: §9.21.1 fixes the data source at the first call ("Any
/// change after this point is ignored"), so a sample carries no derivative,
/// while the lookup point is routinely a probe and its derivative is the
/// Jacobian row the solver needs.
pub fn emitTable(self: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!void {
    // §9.21 zTable brackets on `.val()` — the cell choice is one scalar
    // decision, so a lane off the chosen cell would read a linear
    // extrapolation. Pins.
    for (args) |arg| float_lanes.pinLanes(self, arg);
    const nd = intArg(self, args, 0) orelse 0;
    const np = intArg(self, args, 1) orelse 0;
    const ncol = intArg(self, args, 2) orelse 0;
    const dep = intArg(self, args, 3) orelse 0;
    const ext = gen_call.strArg(self, args, 4) orelse "";
    const site = intArg(self, args, 5) orelse 0;
    const head = 7 + nd;
    // `np == 0` is legal here and only here: §9.21.1's absent data source,
    // whose error `zTable` raises at the call (`ztMissingSource`).
    if (nd == 0 or ncol == 0 or args.len != head + np * ncol)
        return gen_call.abort(self, "malformed `$table_model` call reached codegen", .{});
    if (site != 0) {
        self.uses_inst = true;
        self.float.pinned = true;
        try self.b("tbl_{d}: {{ _ = S.val(", .{@intFromEnum(inst)});
        try renderVal(self, args[6], .real);
        try self.b("); if (!inst.table_ready[{d}]) {{ inst.table_{d} = [_]f64{{", .{ site - 1, site - 1 });
    } else try self.b("zTable(S, {d}, {d}, {d}, {d}, \"{s}\", [_]f64{{", .{ np, ncol, nd, dep, ext });
    for (args[head..], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try self.b("S.val(", .{});
        try renderVal(self, v, .real);
        try self.b(")", .{});
    }
    if (site != 0) {
        try self.b("}}; inst.table_ready[{d}] = true; }} break :tbl_{d} zTable(S, {d}, {d}, {d}, {d}, \"{s}\", inst.table_{d}, [_]S{{", .{ site - 1, @intFromEnum(inst), np, ncol, nd, dep, ext, site - 1 });
    } else try self.b("}}, [_]S{{", .{});
    for (args[7..head], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try renderVal(self, v, .real);
    }
    try self.b("}})", .{});
    if (site != 0) try self.b("; }}", .{});
}

/// §§3.2/5.7 runtime array index, in the shape `Lower.lowerIndex` rewrote it:
///
///     (lo, i, e_lo … e_hi)
///
/// One `switch`, so the read is ONE dispatch and ONE element evaluation
/// however wide the array is. A `sel` chain would evaluate every element
/// and every comparison on every read — `sel` is a mask primitive, not a
/// branch — which made `for (k…) a[k]` quadratic in the DECLARED extent.
///
/// An out-of-range read returns the element type's zero (see the `else`
/// arm). Inherited Verilog UNKNOWNS are still not modelled here, so an
/// integer array cannot yield x; that remaining gap is tracked in
/// CONFORMANCE-GAPS.md.
///
/// Each arm is rendered lazily by the switch, so an element that is an
/// inline expression is evaluated only when it is the one selected. That is
/// sound because a MIR value is pure; the ones with side effects (`$fopen`,
/// `$display`) are statements and never reach an array initializer.
pub fn emitIdx(self: *Gen, args: []const Mir.Value, want: VTy) Error!void {
    // The dispatch is on one integer, so the CHOICE is lane-uniform — the
    // same reason `emitTable` pins: a lane wanting a different element has
    // no spelling here.
    float_lanes.pinLanes(self, args[1]);
    const lo: i64 = blk: {
        const def = self.mir.valueDef(self.an.rv(args[0]));
        break :blk if (def == .int_const) def.int_const else 0;
    };
    if (args.len < 3) return gen_call.abort(self, "malformed `$idx` call reached codegen", .{});
    try self.b("switch (", .{});
    try renderVal(self, args[1], .int);
    try self.b(") {{", .{});
    for (args[2..], 0..) |v, k| {
        try self.b(" {d} => ", .{lo + @as(i64, @intCast(k))});
        try renderVal(self, v, want);
        try self.b(",", .{});
    }
    // §5.7 makes unpacked-array assignment "a subset of the requirements of
    // IEEE Std 1800", and a read at an address the array does not have
    // yields the element type's default there; §3.2 fixes that default here
    // — an integer assigned in an analog context starts at zero, and "real
    // variables are initialized to zero (0) at the start of a simulation".
    //
    // The two properties that do NOT depend on that delegation, and that
    // this arm exists to keep: the read must not ALIAS a neighbouring
    // element (clamping, wrapping or taking a modulus hands back another
    // cell's value, which is a silently wrong model rather than a missing
    // feature), and it must not abort — §4.3.2 reserves "shall report an
    // error" for named cases and a subscript is not one of them, and a
    // device that crashes reports nothing at all. This used to @panic,
    // which killed the whole simulation from inside generated code.
    try self.b(" else => {s} }}", .{gen_unit.zeroOf(want)});
}

/// A structural count lowering put in an argument list as a literal.
pub fn intArg(self: *const Gen, args: []const Mir.Value, i: usize) ?usize {
    if (i >= args.len) return null;
    const def = self.mir.valueDef(self.an.rv(args[i]));
    if (def != .int_const or def.int_const < 0) return null;
    return @intCast(def.int_const);
}

// ponytail: integer callees infer their type; add a typed variant only for a caller.
fn intCall2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    try self.b("{s}(", .{name});
    try renderVal(self, a, .int);
    try self.b(", ", .{});
    try renderVal(self, b2, .int);
    try self.b(")", .{});
}

/// §4.2.11 `>>` — a LOGICAL shift over §3.2.1's 32-bit `integer`.
///
/// A zero count is identity, preserving the operand's signed value. For a
/// positive count, narrow to 32 bits and shift as UNSIGNED so the vacated
/// positions fill with zeroes. §4.2.11's own example is `3 >> 1` giving
/// "0011 shifted to the right one position and zero-filled"; the arithmetic
/// shift this replaced made `-16 >> 2` come out as -4 instead of
/// 0xFFFFFFF0 >> 2 == 1073741820, i.e. it kept the sign the LRM says to drop.
///
/// `zShr` (over `std.math.shr`) does the shifting because it is what
/// defines an over-wide or negative count as 0 rather than as UB or a
/// wrong-way shift — §4.2.11's count is unsigned; see the helper.
///
/// `<<` is now narrowed at its own arm above, on §3.2's width rather than
/// §4.2.11's fill rule — the two are separate clauses that happen to want the
/// same 32 bits, and `Lower.wrap32` is where that width is written down.
pub fn shrLogical(self: *Gen, a: Mir.Value, b2: Mir.Value) Error!void {
    try self.b("zShr(", .{});
    try renderVal(self, a, .int);
    try self.b(", ", .{});
    try renderVal(self, b2, .int);
    try self.b(")", .{});
}

fn cmpReal(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    float_lanes.pinLanes(self, a);
    float_lanes.pinLanes(self, b2);
    try self.b("@as(i64, @intFromBool((", .{});
    try renderVal(self, a, .real);
    try self.b(").val() {s} (", .{opx});
    try renderVal(self, b2, .real);
    try self.b(").val()))", .{});
}

fn cmpInt(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("@as(i64, @intFromBool((", .{});
    try renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try renderVal(self, b2, .int);
    try self.b(")))", .{});
}
