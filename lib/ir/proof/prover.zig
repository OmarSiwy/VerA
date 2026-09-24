//! The prover: one dominator-order walk that rates every unit `.optimized` or `.strict`.
//!
//! In: MIR, analysis facts and Lower's parameter ranges. Out: an interval, a finite bit and a guard
//! set per value, and a compile error only for a provably out-of-domain argument (§4.3.2).
//!
//! LRM clauses this file's code cites: §2.7, §3.4.2, §4.2, §4.2.4, §4.2.5, §4.2.8, §4.2.12, §4.3.1, §4.3.2, §4.5.13, §9.5, §9.5.1.
//!
//! Cut verbatim from `proof.zig`. Functions take `self: *proof` and are called
//! directly, `proof_prover.f(self, ...)`; `proof.zig` aliases only what other modules call.

const std = @import("std");
const proof = @import("../proof.zig");
const proof_lattice = @import("lattice.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("../mir.zig");
const Lower = @import("../lower.zig");
const Analysis = @import("../analysis.zig");
const diag = @import("diag");
const math = proof.math;
const FloatMode = proof.FloatMode;
const Verdict = proof.Verdict;
const Options = proof.Options;
const max_errors = proof.max_errors;
const unitCount = proof.unitCount;

// ---------------------------------------------------------------------------
// The prover
// ---------------------------------------------------------------------------

/// A guard fact: "this Value is confined to this interval here".
pub const Fact = struct { v: u32, iv: proof_lattice.Interval };

/// Where a value's select-arm guard facts live in `facts`.
pub const GuardRef = struct { start: u32 = 0, count: u32 = 0 };

pub const none_u32 = std.math.maxInt(u32);

pub const Prover = struct {
    gpa: std.mem.Allocator,
    /// Scratch arena — dies with `prove`.
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    opts: Options,

    // --- SoA, indexed by @intFromEnum(Mir.Value) ---
    iv: []proof_lattice.Interval = &.{},
    /// SOUNDNESS MODEL: "is a finite IEEE double", recorded at definition time.
    ///
    /// `[]bool`, MEASURED: nv median 38, p99 213, max 929 over the 1164
    /// fixtures, and every access is a random probe by value index (`isFinite`,
    /// the transfer functions, `verdict`'s slice walk). One byte load. A
    /// `bit_set` saves 33 bytes in the median compilation and charges a shift
    /// and a mask for it — see unit_plan.zig's "THE SIDE TABLES STAY `[]bool`".
    finite: []bool = &.{},
    /// Use count, for the single-use test that scopes a §4.2.12 select guard.
    uses: []u32 = &.{},
    guard: []GuardRef = &.{},
    /// Congruence class per value (`none_u32` = alone). Two structurally
    /// identical pure instructions compute the SAME number, so a guard fact
    /// about one is a fact about all of them — that is what lets
    /// `if (V(p,n) > 0) … ln(V(p,n))` prove, given that lowering emits a fresh
    /// `fsub` per `V(p,n)` occurrence. Internal to this pass; it must never
    /// leak into codegen, which deliberately recomputes per unit.
    /// ponytail: structural key on already-resolved operands only (no
    /// transitive numbering). Upgrade to a real GVN if a fixture needs it.
    class_of: []u32 = &.{},
    class_member: []u32 = &.{},
    class_start: []u32 = &.{},

    facts: std.ArrayList(Fact) = .empty,
    /// Save stack for guard application (dominator-tree DFS + select arms).
    saved: std.ArrayList(Fact) = .empty,

    /// The CFG, dominator tree and natural loops — built by `analysis.zig`,
    /// which is the file that owns them. Read-only here.
    an: Analysis = undefined,
    /// `[]bool` for the same measured reason as `finite`: nb median 1, max 103,
    /// and `walkBlock` probes it one block at a time.
    visited_block: []bool = &.{},

    /// Where every class-6 diagnostic goes. Shared with the other stages.
    bag: *diag.Bag,
    /// §4.3.2 violations reported so far — the accept/reject decision.
    error_count: u32 = 0,

    /// Source span of an instruction — the whole reason `Mir.InstRow.tok`
    /// exists. Before it, every class-6 diagnostic reported at line 0, col 0,
    /// which made the hardest pass in the engine the least debuggable.
    fn span(self: *const Prover, inst: Mir.Inst) diag.Span {
        const tok = self.mir.instTok(inst);
        // An unattributed instruction has NO location. Reporting one anyway put
        // the caret on whatever token 0 happened to be — the first line of the
        // annex-D prelude.
        if (tok == Mir.no_tok) return .{};
        return self.lower.tokenSpan(tok);
    }

    /// Span of whatever DEFINED a value, so a label can point at the parameter
    /// or the sub-expression the prover is really complaining about.
    fn valueSpan(self: *const Prover, v: Mir.Value) diag.Span {
        switch (self.mir.valueDef(self.mir.resolveAlias(v))) {
            .inst_result => |inst| return self.span(inst),
            .param_ref => |pi| {
                if (pi >= self.lower.params.items.len) return .{};
                const tok = self.lower.params.items[pi].tok;
                if (tok == Mir.no_tok) return .{};
                return self.lower.tokenSpan(tok);
            },
            else => return .{},
        }
    }

    /// Every read of a Value goes through the alias map (ssa.zig contract).
    fn idxOf(self: *const Prover, v: Mir.Value) u32 {
        return @intFromEnum(self.mir.resolveAlias(v));
    }

    fn ivOf(self: *const Prover, v: Mir.Value) proof_lattice.Interval {
        return self.iv[self.idxOf(v)];
    }

    fn isFinite(self: *const Prover, v: Mir.Value) bool {
        return self.finite[self.idxOf(v)];
    }

    // -------------------------------------------------------------- seeding --

    /// Initial abstract state for every Value. Only `inst_result` is left at ⊤;
    /// the pass fills those in dominator order.
    pub fn seedValues(self: *Prover) !void {
        const n = self.an.nv;
        self.iv = try self.arena.alloc(proof_lattice.Interval, n);
        self.finite = try self.arena.alloc(bool, n);
        self.uses = try self.arena.alloc(u32, n);
        self.guard = try self.arena.alloc(GuardRef, n);
        @memset(self.iv, proof_lattice.Interval.top);
        @memset(self.finite, false);
        @memset(self.uses, 0);
        @memset(self.guard, .{});

        for (0..n) |i| {
            const v: Mir.Value = @enumFromInt(@as(u32, @intCast(i)));
            switch (self.mir.valueDef(v)) {
                // §4.2 constant expressions — exact.
                .float_const => |c| {
                    self.iv[i] = proof_lattice.Interval.point(c);
                    self.finite[i] = math.isFinite(c);
                },
                .int_const => |c| {
                    self.iv[i] = proof_lattice.Interval.point(@floatFromInt(c));
                    self.finite[i] = true;
                },
                // §2.7 strings never reach a float operation.
                .str_const => self.finite[i] = true,
                // §3.4.2 — THE primary bound evidence.
                .param_ref => |pi| {
                    const iv = self.paramInterval(pi);
                    self.iv[i] = iv;
                    self.finite[i] = iv.excludesInf();
                    // A range the user WROTE that admits infinity is almost
                    // always a typo for the open bound — see W0651.
                    if (!self.finite[i]) try self.warnInfiniteRange(pi, iv);
                },
                // §4.4 solver unknown: finite by the host contract, magnitude
                // unknown unless the host declares one (Options.unknown_bound).
                .block_param => {
                    if (self.opts.unknown_bound) |b|
                        self.iv[i] = .{ .lo = -@abs(b), .hi = @abs(b) };
                    self.finite[i] = true;
                },
                .inst_result => {
                    // if-conversion collects select-arm guards before the
                    // transfer walk. A widened literal in `real_value > 0`
                    // already has the same bound as the source integer zero.
                    if (self.literalNumber(v)) |c| {
                        self.iv[i] = proof_lattice.Interval.point(c);
                        self.finite[i] = math.isFinite(c);
                    }
                },
                .undef => {},
            }
        }
    }

    /// LRM §3.4.2 value ranges → an interval. `from` ranges are unioned (their
    /// convex hull — the representation has no holes), `exclude` ranges are
    /// subtracted only where they clip an end, which is exactly the `exclude 0`
    /// / `from (0:inf)` evidence a divisor or a `ln` needs.
    ///
    /// Bounds are folded LITERALLY (`foldBound`), never through
    /// `Lower.constEval`: a bound written in terms of another parameter folds to
    /// that parameter's DEFAULT, which the model card can override — using it
    /// would be an unsound proof.
    fn paramInterval(self: *const Prover, param: u32) proof_lattice.Interval {
        if (param >= self.lower.params.items.len) return .top;
        const info = self.lower.params.items[param];
        if (info.ty == .string) return .top;

        var acc: ?proof_lattice.Interval = null;
        for (info.ranges) |r| {
            if (r.kind != .from or r.strings != null) continue;
            const lo = self.foldBound(r.lo) orelse return .top;
            const hi = if (r.hi == .none) lo else (self.foldBound(r.hi) orelse return .top);
            const one: proof_lattice.Interval = .{
                .lo = lo,
                .hi = hi,
                .lo_open = !r.lo_inclusive,
                .hi_open = !r.hi_inclusive,
            };
            acc = if (acc) |a| a.join(one) else one;
        }
        var iv = acc orelse proof_lattice.Interval.top;

        for (info.ranges) |r| {
            if (r.kind != .exclude or r.strings != null) continue;
            const lo = self.foldBound(r.lo) orelse continue;
            const hi = if (r.hi == .none) lo else (self.foldBound(r.hi) orelse continue);
            // Only an end-clipping exclusion is representable without holes.
            //
            // §3.4.2: "Parentheses, ( and ), indicate exclusion of the end
            // points from the value range." An END POINT of an `exclude` is
            // therefore excluded only when its bracket is square — `exclude
            // (0:5)` still admits 0, and concluding `nonzero` from it is
            // unsound: it discharges the divide-by-zero obligation and hands
            // the unit `@setFloatMode(.optimized)`, under which a division by
            // the very value the range permits is undefined behaviour.
            // `exclude 0` keeps working: `hi == .none` copies `lo`, and both
            // inclusive flags default to true.
            const zero_excluded = (lo < 0 and hi > 0) or
                (lo == 0 and r.lo_inclusive) or
                (hi == 0 and r.hi_inclusive);
            if (zero_excluded) iv.nonzero = true;
            if (lo <= iv.lo and hi >= iv.lo and hi <= iv.hi) {
                iv.lo = hi;
                iv.lo_open = r.hi_inclusive;
            } else if (hi >= iv.hi and lo <= iv.hi and lo >= iv.lo) {
                iv.hi = lo;
                iv.hi_open = r.lo_inclusive;
            }
        }
        // §3.2.1 fixes the `integer` type at 32 bits, so a MODEL-CARD integer
        // can never hold an infinity regardless of what ranges the user wrote
        // (or did not write). Without this meet an unranged `parameter integer`
        // seeded ⊤/non-finite and dragged its whole unit to `.strict`, with a
        // W0650 blaming whatever probe shared the expression. The transfer
        // functions already know this for integer RESULTS (`integerIv`); this
        // is the same fact for integer SOURCES.
        if (info.ty == .integer)
            iv = iv.meet(.{ .lo = -2147483648.0, .hi = 2147483647.0 });
        return iv;
    }

    /// Literal-only constant fold of a §3.4.2 range bound. Deliberately refuses
    /// identifiers (see `paramInterval`); `inf` (§3.4.2) folds to ±infinity.
    fn foldBound(self: *const Prover, e: Ast.ExprId) ?f64 {
        if (e == .none) return null;
        const ex = &self.lower.file.exprs;
        return switch (ex.tag(e)) {
            .int_literal => @floatFromInt(ex.intValue(e)),
            .real_literal => ex.realValue(e),
            .pos_inf => math.inf(f64),
            .neg_inf => -math.inf(f64),
            .unary => blk: {
                const a = self.foldBound(ex.lhs(e)) orelse break :blk null;
                break :blk switch (ex.unOp(e)) {
                    .plus => a,
                    .minus => -a,
                    else => null,
                };
            },
            .binary => blk: {
                const a = self.foldBound(ex.lhs(e)) orelse break :blk null;
                const b = self.foldBound(ex.rhs(e)) orelse break :blk null;
                break :blk switch (ex.binOp(e)) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => if (b == 0) null else a / b,
                    .pow => math.pow(f64, a, b),
                    else => null,
                };
            },
            else => null,
        };
    }

    // ------------------------------------------------------- guard evidence --

    /// Operands of an instruction, into a caller buffer (max 3 + the variadic
    /// classes, which are returned as borrowed slices instead).
    fn operands(self: *const Prover, inst: Mir.Inst, buf: *[3]Mir.Value) []const Mir.Value {
        return switch (self.mir.instData(inst)) {
            .unary => |u| blk: {
                buf[0] = u.operand;
                break :blk buf[0..1];
            },
            .binary => |b| blk: {
                buf[0] = b.lhs;
                buf[1] = b.rhs;
                break :blk buf[0..2];
            },
            .ternary => |t| blk: {
                buf[0] = t.cond;
                buf[1] = t.then_val;
                buf[2] = t.else_val;
                break :blk buf[0..3];
            },
            .branch => |b| blk: {
                buf[0] = b.cond;
                break :blk buf[0..1];
            },
            .jump => buf[0..0],
            .call => |c| c.args,
            // phi operands are (block, value) pairs — callers use `phiPair`.
            .phi => buf[0..0],
        };
    }

    /// Group structurally identical pure instructions. Impure classes (phi,
    /// call, terminators, and the `opt_barrier` fence) are never merged.
    pub fn buildClasses(self: *Prover) !void {
        const n = self.an.nv;
        self.class_of = try self.arena.alloc(u32, n);
        @memset(self.class_of, none_u32);

        const Key = struct { op: Mir.Opcode, a: u32, b: u32, c: u32 };
        var map: std.AutoHashMapUnmanaged(Key, u32) = .empty;
        defer map.deinit(self.arena);
        var n_classes: u32 = 0;

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(i)));
            const op = self.mir.instOp(inst);
            if (op == .phi or op == .call or op == .opt_barrier) continue;
            const result = self.mir.instResult(inst);
            if (result == .undef) continue;
            var buf: [3]Mir.Value = undefined;
            const ops = self.operands(inst, &buf);
            const key: Key = .{
                .op = op,
                .a = if (ops.len > 0) self.idxOf(ops[0]) else 0,
                .b = if (ops.len > 1) self.idxOf(ops[1]) else 0,
                .c = if (ops.len > 2) self.idxOf(ops[2]) else 0,
            };
            const gop = try map.getOrPut(self.arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = n_classes;
                n_classes += 1;
            }
            self.class_of[self.idxOf(result)] = gop.value_ptr.*;
        }

        // CSR of members, in value order (determinism).
        self.class_start = try self.arena.alloc(u32, n_classes + 1);
        @memset(self.class_start, 0);
        for (self.class_of) |c| if (c != none_u32) {
            self.class_start[c + 1] += 1;
        };
        for (1..n_classes + 1) |i| self.class_start[i] += self.class_start[i - 1];
        self.class_member = try self.arena.alloc(u32, self.class_start[n_classes]);
        const fill = try self.arena.alloc(u32, n_classes);
        @memcpy(fill, self.class_start[0..n_classes]);
        for (self.class_of, 0..) |c, v| if (c != none_u32) {
            self.class_member[fill[c]] = @intCast(v);
            fill[c] += 1;
        };
    }

    /// A `select`'s arms carry NO CFG dominance, so without this the canonical
    /// guarded idiom `x > 0 ? ln(x) : 0` would be rejected. An arm's
    /// exclusively-owned backward slice (use count 1) is guarded by the select
    /// condition.
    ///
    /// §4.2.3 makes `?:` short-circuiting, so `lowerTernary` now emits a real
    /// diamond and that idiom reaches the prover with dominance evidence
    /// instead — this pass is what still covers every OTHER `select`: the
    /// masked element writes of a runtime array index (`lowerAssign`) and the
    /// §5.10.3.3 `enable` fold.
    ///
    /// CODEGEN OBLIGATION: `select` must be emitted as a lazy Zig `if`, not as
    /// "evaluate both arms then pick" — otherwise `ln(x)` really does run with
    /// x <= 0 and this guard is a lie.
    pub fn markSelectArms(self: *Prover) !void {
        // Use counts first: the single-use test is what scopes an arm.
        self.countUses();

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(i)));
            if (self.mir.instOp(inst) != .select) continue;
            const t = self.mir.instData(inst).ternary;
            try self.markArm(t.then_val, t.cond, true);
            try self.markArm(t.else_val, t.cond, false);
        }
    }

    /// How often each Value is read, alias-resolved. It walks block CHAINS: a
    /// row in no chain (the branch and jumps if-conversion orphans) is not a
    /// use. And it skips a collapsed phi's operands (ssa.zig contract 1): such
    /// a phi is aliased to the one value its operands resolve to, and its
    /// users already count that value through the alias. Counting both — as
    /// this pass did over `0..insts.len` — made single-use arm values look
    /// shared, and a shared value stops the guard walk. Contribution roots
    /// count once each, so a root is never mistaken for an exclusively-owned
    /// select arm.
    fn countUses(self: *Prover) void {
        const mir = self.mir;
        for (self.lower.contributions.items) |c| {
            self.uses[self.idxOf(c.resist_val)] += 1;
            self.uses[self.idxOf(c.react_val)] += 1;
        }
        for (0..mir.blockCount()) |b| {
            var it = mir.blockInsts(@enumFromInt(@as(u32, @intCast(b))));
            while (it.next()) |inst| {
                if (mir.instOp(inst) == .phi) {
                    if (mir.hasAlias(mir.instResult(inst))) continue;
                    const ph = mir.instData(inst).phi;
                    for (0..ph.count) |k| self.uses[self.idxOf(mir.phiPair(inst, @intCast(k)).value)] += 1;
                    continue;
                }
                var buf: [3]Mir.Value = undefined;
                for (self.operands(inst, &buf)) |v| self.uses[self.idxOf(v)] += 1;
            }
        }
    }

    fn markArm(self: *Prover, arm: Mir.Value, cond: Mir.Value, taken: bool) !void {
        var raw: [2]Fact = undefined;
        const facts = self.condFacts(cond, taken, &raw);
        if (facts.len == 0) return;
        const start: u32 = @intCast(self.facts.items.len);
        try self.facts.appendSlice(self.arena, facts);
        const ref: GuardRef = .{ .start = start, .count = @intCast(facts.len) };

        // DFS the arm's exclusively-owned slice. Budgeted: a shared value stops
        // the walk, so this is linear in the arm, not in the program.
        var stack: std.ArrayList(Mir.Value) = .empty;
        defer stack.deinit(self.arena);
        try stack.append(self.arena, arm);
        var budget: u32 = 4096;
        while (stack.pop()) |v| {
            if (budget == 0) break;
            budget -= 1;
            const i = self.idxOf(v);
            if (self.uses[i] != 1 or self.guard[i].count != 0) continue;
            const def = self.mir.valueDef(@enumFromInt(i));
            if (def != .inst_result) continue;
            self.guard[i] = ref;
            const inst = def.inst_result;
            if (self.mir.instOp(inst) == .phi) continue; // a phi is not arm-local
            var buf: [3]Mir.Value = undefined;
            for (self.operands(inst, &buf)) |o| try stack.append(self.arena, o);
        }
    }

    fn literalNumber(self: *const Prover, v: Mir.Value) ?f64 {
        return switch (self.mir.valueDef(self.mir.resolveAlias(v))) {
            .int_const => |c| @floatFromInt(c),
            .float_const => |c| c,
            .inst_result => |inst| blk: {
                const row = self.mir.instRow(inst);
                if (row.op != .if_cast) break :blk null;
                const def = self.mir.valueDef(self.mir.resolveAlias(@enumFromInt(row.a)));
                break :blk if (def == .int_const) @as(f64, @floatFromInt(def.int_const)) else null;
            },
            else => null,
        };
    }

    fn isZeroConst(self: *const Prover, v: Mir.Value) bool {
        return (self.literalNumber(v) orelse return false) == 0.0;
    }

    /// Facts implied by taking (or not taking) a branch on `cond`.
    /// LRM §4.2.5 relational / §4.2.7 equality operators; `&&`/`||` need no case
    /// because §4.2.8 short-circuit gives them real CFG (see lower.zig).
    fn condFacts(self: *const Prover, cond: Mir.Value, taken: bool, buf: *[2]Fact) []const Fact {
        const def = self.mir.valueDef(self.mir.resolveAlias(cond));
        if (def != .inst_result) return buf[0..0];
        const inst = def.inst_result;
        const d = self.mir.instData(inst);
        switch (d) {
            .unary => |u| if (u.op == .lognot) return self.condFacts(u.operand, !taken, buf),
            .binary => |b| {
                // §4.2.8: lowering materialises a condition as `c != 0`. Peel
                // that off when `c` is itself a comparison, otherwise keep it as
                // the (useful) "non-zero" fact for a §4.2.4 divisor.
                if (b.op == .ine or b.op == .fne or b.op == .ieq or b.op == .feq) {
                    const flip = b.op == .ieq or b.op == .feq;
                    const zl = self.isZeroConst(b.lhs);
                    const zr = self.isZeroConst(b.rhs);
                    const other: ?Mir.Value = if (zr) b.lhs else if (zl) b.rhs else null;
                    if (other) |o| {
                        if (proof_lattice.isPredicateValue(self.mir, o)) return self.condFacts(o, taken != flip, buf);
                        if (taken != flip) {
                            buf[0] = .{ .v = self.idxOf(o), .iv = .{ .nonzero = true } };
                            return buf[0..1];
                        }
                        return buf[0..0];
                    }
                }
                // Normalise every comparison to `lhs REL rhs`.
                const Rel = enum { lt, le, eq, none };
                var rel: Rel = .none;
                var swap = false;
                switch (b.op) {
                    .flt, .ilt => rel = if (taken) .lt else .none,
                    .fle, .ile => rel = if (taken) .le else .none,
                    .fgt, .igt => {
                        swap = true;
                        rel = if (taken) .lt else .none;
                    },
                    .fge, .ige => {
                        swap = true;
                        rel = if (taken) .le else .none;
                    },
                    .feq, .ieq => rel = if (taken) .eq else .none,
                    .fne, .ine => rel = if (taken) .none else .eq,
                    else => {},
                }
                // The negated strict/loose forms: !(a<b) ⇒ b<=a, !(a<=b) ⇒ b<a.
                if (!taken) switch (b.op) {
                    .flt, .ilt => {
                        rel = .le;
                        swap = true;
                    },
                    .fle, .ile => {
                        rel = .lt;
                        swap = true;
                    },
                    .fgt, .igt => {
                        rel = .le;
                        swap = false;
                    },
                    .fge, .ige => {
                        rel = .lt;
                        swap = false;
                    },
                    else => {},
                };
                if (rel == .none) return buf[0..0];
                const lo_v = if (swap) b.rhs else b.lhs;
                const hi_v = if (swap) b.lhs else b.rhs;
                const li = self.idxOf(lo_v);
                const hi = self.idxOf(hi_v);
                const a_iv = self.iv[li];
                const b_iv = self.iv[hi];
                switch (rel) {
                    .eq => {
                        buf[0] = .{ .v = li, .iv = b_iv };
                        buf[1] = .{ .v = hi, .iv = a_iv };
                    },
                    .lt, .le => {
                        // a < b  ⇒  a < b.hi  and  b > a.lo
                        const strict = rel == .lt;
                        buf[0] = .{ .v = li, .iv = .{
                            .hi = b_iv.hi,
                            .hi_open = strict or b_iv.hi_open,
                        } };
                        buf[1] = .{ .v = hi, .iv = .{
                            .lo = a_iv.lo,
                            .lo_open = strict or a_iv.lo_open,
                        } };
                    },
                    .none => unreachable,
                }
                return buf[0..2];
            },
            else => {},
        }
        return buf[0..0];
    }

    /// Apply facts, remembering the previous intervals.
    fn pushFacts(self: *Prover, facts: []const Fact) !void {
        for (facts) |f| {
            const c = self.class_of[f.v];
            const members: []const u32 = if (c == none_u32)
                (&[_]u32{f.v})[0..1]
            else
                self.class_member[self.class_start[c]..self.class_start[c + 1]];
            for (members) |m| {
                try self.saved.append(self.arena, .{ .v = m, .iv = self.iv[m] });
                self.iv[m] = self.iv[m].meet(f.iv);
            }
        }
    }

    fn popFacts(self: *Prover, mark: usize) void {
        while (self.saved.items.len > mark) {
            const f = self.saved.pop().?;
            self.iv[f.v] = f.iv;
        }
    }

    // ------------------------------------------------------------ the walk --

    /// One pass over every instruction, in dominator-tree preorder so that a
    /// guard applied on the edge into a block stays in effect for the whole
    /// subtree it dominates and is undone on the way out.
    ///
    /// SSA guarantees a definition dominates its uses, so every non-phi operand
    /// is already computed. A phi operand coming from an unprocessed
    /// predecessor (a loop back edge, §5.9) is still ⊤/non-finite — i.e. the
    /// loop is widened to ⊤ immediately. That is sound and terminating.
    /// ponytail: immediate widening loses loop-carried bounds. Upgrade path if
    /// a real model needs them: ascending-chain worklist from ⊥ with a widening
    /// after k rounds — and the input that decides WHERE to widen is now in
    /// hand, `analysis.inLoop(b)`, so the worklist can iterate the natural loop
    /// body (`Analysis.loop_of`) instead of the whole CFG. Genvar loops
    /// (§6.6.1) unroll, so this bites `while` only.
    pub fn walk(self: *Prover) !void {
        const nb = self.an.nb;
        if (nb == 0) return;
        self.visited_block = try self.arena.alloc(bool, nb);
        @memset(self.visited_block, false);

        try self.walkDom(0);

        // Blocks unreachable from entry still contain user-written operations;
        // check them with no guard evidence rather than silently skipping.
        for (0..nb) |b| if (!self.visited_block[b]) try self.walkBlock(@intCast(b));
    }

    fn walkDom(self: *Prover, b: u32) !void {
        const mark = self.saved.items.len;
        defer self.popFacts(mark);

        // Evidence from the edge idom(b) → b. Requiring b's ONLY predecessor to
        // be the branching block is what makes "dominated by b" imply "the
        // branch went this way".
        if (b != 0) {
            const parent = self.an.idom[b];
            if (parent != none_u32 and self.an.preds[b].len == 1) {
                // ponytail: reuse the chain-order pool built by Analysis.
                for (self.an.blockInstsFlat(parent)) |inst| {
                    const d = self.mir.instData(inst);
                    if (d != .branch) continue;
                    const taken = @intFromEnum(d.branch.then_block) == b;
                    if (!taken and @intFromEnum(d.branch.else_block) != b) continue;
                    var raw: [2]Fact = undefined;
                    try self.pushFacts(self.condFacts(d.branch.cond, taken, &raw));
                }
            }
        }

        try self.walkBlock(b);
        for (self.an.dom_kids[b]) |c| try self.walkDom(c);
    }

    fn walkBlock(self: *Prover, b: u32) !void {
        self.visited_block[b] = true;
        // ponytail: the immutable instruction pool already preserves emission order.
        for (self.an.blockInstsFlat(b)) |inst| try self.evalInst(inst);
    }

    fn evalInst(self: *Prover, inst: Mir.Inst) !void {
        const result = self.mir.instResult(inst);
        const ri = self.idxOf(result);

        // §4.2.12 select-arm guard, scoped to exactly this instruction.
        const mark = self.saved.items.len;
        defer self.popFacts(mark);
        if (result != .undef) {
            const g = self.guard[ri];
            if (g.count != 0) try self.pushFacts(self.facts.items[g.start..][0..g.count]);
        }

        // An unprovable domain is not an error (LRM §4.3.2, see checkDomain) —
        // it costs the result its finiteness fact, which drops the enclosing
        // unit to `@setFloatMode(.strict)` where NaN/inf are IEEE-defined.
        const domain_proven = try self.checkDomain(inst);
        if (result == .undef) return; // terminator

        const out = self.transfer(inst);
        // MEET, not assign: a guard pushed on this value's congruence class
        // before its definition (the `if (V>0) … ln(V)` shape) must survive its
        // own transfer. `pushFacts` saved the pre-guard interval, so nothing
        // leaks out of the scope.
        self.iv[ri] = out.iv.meet(self.iv[ri]);
        self.finite[ri] = out.finite and domain_proven;
    }

    const Abstract = struct { iv: proof_lattice.Interval, finite: bool };

    /// Transfer function. Intervals are computed for the DOMAIN proof; `finite`
    /// is the separate SOUNDNESS MODEL fact that drives the float mode.
    fn transfer(self: *Prover, inst: Mir.Inst) Abstract {
        const op = self.mir.instOp(inst);

        // §4.2.5/§4.2.8: integer-valued results are finite by construction and
        // never pollute the float mode.
        if (Mir.opIsInteger(op)) return .{ .iv = integerIv(op), .finite = true };

        switch (self.mir.instData(inst)) {
            .unary => |u| {
                const a = self.ivOf(u.operand);
                const af = self.isFinite(u.operand);
                return unaryTransfer(op, a, af);
            },
            .binary => |b| {
                const x = self.ivOf(b.lhs);
                const y = self.ivOf(b.rhs);
                const f = self.isFinite(b.lhs) and self.isFinite(b.rhs);
                return self.binaryTransfer(op, x, y, f);
            },
            .ternary => |t| { // §4.2.12 `?:` — the union of the two arms
                const a = self.ivOf(t.then_val);
                const b = self.ivOf(t.else_val);
                return .{
                    .iv = a.join(b),
                    .finite = self.isFinite(t.then_val) and self.isFinite(t.else_val),
                };
            },
            .phi => |ph| { // §5.8 join
                if (ph.count == 0) return .{ .iv = .top, .finite = false };
                var acc: ?proof_lattice.Interval = null;
                var fin = true;
                for (0..ph.count) |k| {
                    const v = self.mir.phiPair(inst, @intCast(k)).value;
                    const one = self.ivOf(v);
                    acc = if (acc) |x| x.join(one) else one;
                    fin = fin and self.isFinite(v);
                }
                return .{ .iv = acc.?, .finite = fin };
            },
            // §4.5 analog operators / ch9 system functions: known ones carry a
            // spec-given range, everything else is ⊤.
            .call => |c| return callAbstract(c.name),
            .branch, .jump => return .{ .iv = .top, .finite = false },
        }
    }

    /// Integer results (§3.2): clamp to the i64 range so an integer expression
    /// can never make a unit `.strict`. Relational/logical results are 0/1.
    fn integerIv(op: Mir.Opcode) proof_lattice.Interval {
        if (Mir.opcode.get(op).bool01) return .{ .lo = 0, .hi = 1 };
        return .{ .lo = -9.223372036854776e18, .hi = 9.223372036854776e18 };
    }

    fn unaryTransfer(op: Mir.Opcode, a: proof_lattice.Interval, af: bool) Abstract {
        const monotone: ?[2]f64 = switch (op) {
            .exp => .{ @exp(a.lo), @exp(a.hi) },
            .expm1 => .{ math.expm1(a.lo), math.expm1(a.hi) },
            .ln => .{ @log(a.lo), @log(a.hi) },
            .ln1p => .{ math.log1p(a.lo), math.log1p(a.hi) },
            .log10 => .{ @log10(a.lo), @log10(a.hi) },
            .sqrt => .{ @sqrt(a.lo), @sqrt(a.hi) },
            .sinh => .{ math.sinh(a.lo), math.sinh(a.hi) },
            .tanh => .{ math.tanh(a.lo), math.tanh(a.hi) },
            .asinh => .{ math.asinh(a.lo), math.asinh(a.hi) },
            .atan => .{ math.atan(a.lo), math.atan(a.hi) },
            .asin => .{ math.asin(a.lo), math.asin(a.hi) },
            .atanh => .{ math.atanh(a.lo), math.atanh(a.hi) },
            .acosh => .{ math.acosh(a.lo), math.acosh(a.hi) },
            .floor => .{ @floor(a.lo), @floor(a.hi) },
            .ceil => .{ @ceil(a.lo), @ceil(a.hi) },
            // .path_prev/.path_acc take `else` (unbounded): the latch holds a
            // value from an EARLIER solve, which current branch guards do not
            // constrain — an identity interval here would be wrong-narrow.
            .if_cast, .opt_barrier => .{ a.lo, a.hi },
            else => null,
        };
        if (monotone) |bounds| {
            const lo = bounds[0];
            const hi = bounds[1];
            // AUDIT (same class as the pow/fdiv corner holes): a NaN endpoint
            // here means the operand STRADDLES the function's domain edge —
            // ln(-1), sqrt(-4), asin(2), acosh(0.5)… — and the in-domain
            // branch's range is then NOT spanned by these two endpoints
            // (sqrt over [-4,9] is [0,3], but the old NaN→+inf fold claimed
            // [3,+inf]: wrong-NARROW, which can fabricate a downstream domain
            // verdict). checkDomain has already refused to prove this operand,
            // so the only honest interval is ⊤. Endpoints AT the edge stay
            // exact and wide: ln(0) = -inf, atanh(1) = +inf are not NaN.
            if (math.isNan(lo) or math.isNan(hi)) return .{ .iv = .top, .finite = false };
            const iv: proof_lattice.Interval = .{
                .lo = @min(lo, hi),
                .hi = @max(lo, hi),
                .lo_open = a.lo_open,
                .hi_open = a.hi_open,
            };
            const overflows = op == .exp or op == .expm1 or op == .sinh;
            return .{ .iv = iv, .finite = af and (!overflows or iv.bounded()) };
        }
        return switch (op) {
            .fneg => .{ .iv = .{
                .lo = -a.hi,
                .hi = -a.lo,
                .lo_open = a.hi_open,
                .hi_open = a.lo_open,
            }, .finite = af },
            .fabs => .{ .iv = absIv(a), .finite = af },
            // §4.3.2 acos is DECREASING on [-1,1]. Same straddle rule as the
            // monotone path above: an out-of-domain endpoint (acos(2) = NaN)
            // voids the endpoint claim — the old +inf fold even produced an
            // EMPTY interval (lo=+inf > hi) for a high-straddling operand,
            // which vacuously "proved" every downstream domain.
            .acos => blk: {
                const lo = math.acos(a.hi);
                const hi = math.acos(a.lo);
                if (math.isNan(lo) or math.isNan(hi)) break :blk .{ .iv = .top, .finite = false };
                break :blk .{ .iv = .{ .lo = lo, .hi = hi }, .finite = af };
            },
            // §4.3.2 cosh: even, grows — bounded only if |x| is bounded.
            .cosh => blk: {
                const m = absIv(a);
                const iv: proof_lattice.Interval = .{ .lo = 1, .hi = math.cosh(m.hi) };
                break :blk .{ .iv = iv, .finite = af and iv.bounded() };
            },
            .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .finite = af },
            // §4.3.2 tan is unbounded between poles; the domain check has
            // already run, so only finiteness is left and it is not provable.
            .tan => .{ .iv = .top, .finite = false },
            else => .{ .iv = .top, .finite = false },
        };
    }

    fn binaryTransfer(self: *Prover, op: Mir.Opcode, x: proof_lattice.Interval, y: proof_lattice.Interval, f: bool) Abstract {
        const assume = self.opts.arith_overflow == .assume_absent;
        switch (op) {
            .fadd => {
                const iv: proof_lattice.Interval = .{
                    .lo = addLo(x.lo, y.lo),
                    .hi = addHi(x.hi, y.hi),
                    .lo_open = x.lo_open or y.lo_open,
                    .hi_open = x.hi_open or y.hi_open,
                };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fsub => {
                const iv: proof_lattice.Interval = .{
                    .lo = addLo(x.lo, -y.hi),
                    .hi = addHi(x.hi, -y.lo),
                    .lo_open = x.lo_open or y.hi_open,
                    .hi_open = x.hi_open or y.lo_open,
                };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fmul => {
                const iv = combine(x, y, mulOp);
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fdiv => {
                // A divisor that can be zero yields ±inf (§4.2.4 permits it —
                // only `%` errors). That is NOT an overflow, so the
                // `assume_absent` escape must not apply: it covers SOUNDNESS
                // MODEL 3 (arithmetic overflow), and letting it through here
                // would mark an inf-producing value finite and hand the unit
                // `@setFloatMode(.optimized)`, whose `ninf` assertion it then
                // violates — silent, Release-only UB.
                if (!y.excludesZero()) return .{ .iv = .top, .finite = false };
                // A §3.4.2 PUNCTURE (`exclude 0` on a sign-spanning range)
                // proves the divisor NONZERO but not ONE-SIGNED, and corner
                // combination is sound for `/` only on a one-signed divisor:
                // 1/y over [-10,10]\{0} is (-inf,-0.1] ∪ [0.1,+inf), a set no
                // corner attains — the corners 1/±10 fabricate its COMPLEMENT
                // [-0.1,0.1], and that lie once discharged a `ln` domain proof
                // whose argument was NaN at run time. The nonzero fact still
                // stands for FINITENESS (0/0 and x/0 are impossible; ±inf only
                // via genuine overflow, which is SOUNDNESS MODEL 3, same as any
                // other nonzero divisor) — only the interval claim is void.
                const iv = if (y.gt(0) or y.lt(0)) combine(x, y, divOp) else proof_lattice.Interval.top;
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            // §4.2.4 modulus: |result| < |divisor|, sign of the dividend.
            .fmod => {
                const m = absIv(y).hi;
                const iv: proof_lattice.Interval = if (math.isFinite(m))
                    .{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m }
                else
                    .top;
                return .{ .iv = iv, .finite = f };
            },
            .pow => {
                const iv = powIv(x, y);
                return .{ .iv = iv, .finite = f and iv.bounded() };
            },
            .hypot => {
                const iv: proof_lattice.Interval = .{ .lo = 0, .hi = addHi(absIv(x).hi, absIv(y).hi) };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .atan2 => return .{ .iv = .{ .lo = -math.pi, .hi = math.pi }, .finite = f },
            .fmin => return .{ .iv = .{
                .lo = @min(x.lo, y.lo),
                .hi = @min(x.hi, y.hi),
            }, .finite = f },
            .fmax => return .{ .iv = .{
                .lo = @max(x.lo, y.lo),
                .hi = @max(x.hi, y.hi),
            }, .finite = f },
            else => return .{ .iv = .top, .finite = false },
        }
    }

    // ------------------------------------------------------- domain proofs --

    /// LRM §4.3.2: "Input values outside of the valid range for the operator
    /// shall report an error." That obliges reporting when a value IS out of
    /// range; it does not oblige rejecting a program whose values MIGHT be. So
    /// this is a THREE-WAY split, not two:
    ///
    ///   provably OUTSIDE the domain -> compile error (the §4.3.2 obligation,
    ///                                  discharged statically)
    ///   provably INSIDE              -> ok, may stay `.optimized`
    ///   straddles / unprovable       -> ACCEPTED, returns false so the caller
    ///                                  clears `finite` and the unit drops to
    ///                                  `.strict`, where NaN/inf are IEEE-defined
    ///
    /// This is the identical treatment `exp` already gets (SPEC-FAITHFUL, see
    /// the file header) and it is what keeps VerA's accepted set equal to the
    /// LRM's. Interval arithmetic provably cannot decide the common
    /// `x = V/(1+abs(V))` idiom (it needs to correlate two occurrences of V), so
    /// a stronger abstract domain would not rescue the rejected-but-legal cases.
    ///
    /// Returns TRUE when the domain is proven (or not applicable). Returning
    /// false is not an error — it is a loss of the finiteness fact.
    fn checkDomain(self: *Prover, inst: Mir.Inst) !bool {
        const op = self.mir.instOp(inst);
        const dom = proof_lattice.domainOf(op);
        if (dom == .all) return true;

        switch (dom) {
            // Integer `/` and `%` only (§4.2.4). These stay HARD ERRORS: integer
            // division by zero is illegal behavior in Zig, not an IEEE infinity,
            // so there is no `.strict` fallback that makes it well-defined.
            .nonzero_divisor => {
                const d = self.mir.instData(inst).binary;
                const y = self.ivOf(d.rhs);
                if (y.excludesZero() or y.isEmpty()) return true;
                const what = if (op == .fmod or op == .imod) "`%` divisor" else "`/` divisor";
                return self.violated(inst, .E0601, what, d.rhs, y, "cannot be proven non-zero", "constrain the divisor with `exclude 0` or `from (0:inf)`, or guard the division");
            },
            .pow_sign => { // §4.3.1 Table 4-14
                const d = self.mir.instData(inst).binary;
                const x = self.ivOf(d.lhs);
                const y = self.ivOf(d.rhs);
                if (x.isEmpty() or y.isEmpty()) return true;
                if (x.gt(0)) return true; // x > 0, all y
                if (x.ge(0) and y.gt(0)) return true; // x = 0, y > 0
                // The two PROVABLE violations of Table 4-14's domain — E0609,
                // held to the same three-way standard as E0602–E0607: reject
                // only when EVERY admitted value pair violates.
                //   x == 0 always, y < 0 always: pow is +inf on every
                //   execution — "if x = 0, all y > 0". Checked BEFORE the
                //   integer-exponent accept, whose clause is the x < 0 row and
                //   does not rescue a zero base. (y = 0 is left alone: IEEE
                //   pow(0,0) = 1, the same leniency `x/0.0` gets.)
                if (x.lo == 0 and x.hi == 0 and !x.nonzero and y.lt(0))
                    return self.violated(inst, .E0609, "pow() exponent", d.rhs, y, "must be >= 0 — the base is provably zero", "constrain the exponent with `from [0:inf)`, or the base with `exclude 0`");
                if (self.provablyInteger(d.rhs)) return true; // x < 0, integer y
                //   x < 0 always, y fractional always: pow is NaN on every
                //   execution — "if x < 0, all integer y".
                if (x.lt(0) and provablyNonInteger(y))
                    return self.violated(inst, .E0609, "pow() exponent", d.rhs, y, "must be an integer — the base is provably negative", "use `pow(abs(x), y)` with an explicit sign, or constrain the base with `from [0:inf)`");
                // Straddling either clause (a base that MIGHT be negative, an
                // exponent that MIGHT be fractional) is NaN-capable but not
                // provably violating: IEEE-defined under `.strict`, so accept
                // and forfeit finiteness.
                return false;
            },
            .tan_poles => { // §4.3.2, x != n(pi/2), n odd
                const d = self.mir.instData(inst).unary;
                const a = self.ivOf(d.operand);
                if (a.isEmpty()) return true;
                if (a.bounded()) {
                    // The pole-free branch containing a.lo is
                    // (k*pi - pi/2, k*pi + pi/2). Note the f64 pole is exact to
                    // ~1 ulp; a model running that close to a tan pole is
                    // rejected, which is the conservative direction.
                    const k = @floor((a.lo + math.pi / 2.0) / math.pi);
                    const lo_pole = k * math.pi - math.pi / 2.0;
                    const hi_pole = k * math.pi + math.pi / 2.0;
                    if (a.gt(lo_pole) and a.lt(hi_pole)) return true;
                }
                // An interval spanning a pole still contains pole-free points, so
                // "provably always at a pole" is not decidable here. Unprovable
                // -> `.strict`, where the pole yields a defined IEEE infinity.
                //
                // E0608 ("argument of tan is at a pole") is RETIRED on exactly
                // this ground: a pole is a measure-zero set of IRRATIONAL
                // points, and every double is rational, so even a point
                // interval is never provably AT one — the reject arm of the
                // three-way split is empty and the code could never honestly
                // fire (rejecting a straddling range instead would violate the
                // checkDomain straddle policy).
                return false;
            },
            else => {},
        }

        const d = self.mir.instData(inst).unary;
        const a = self.ivOf(d.operand);
        if (a.isEmpty()) return true;
        const name = opLabel(op);
        // Each arm: proven-inside -> true; proven-OUTSIDE -> report + false;
        // straddling -> false with no diagnostic (accepted, unit goes .strict).
        switch (dom) {
            .positive => {
                if (a.gt(0)) return true;
                if (a.le(0)) return self.violated(inst, .E0602, name, d.operand, a, "must be > 0", "add a range like `from (0:inf)` to the parameter, or guard the call with `if (x > 0)`");
                return false;
            },
            .gt_neg_one => {
                if (a.gt(-1)) return true;
                if (a.le(-1)) return self.violated(inst, .E0603, name, d.operand, a, "must be > -1", "add a range like `from (-1:inf)` to the parameter, or guard the call with `if (x > -1)`");
                return false;
            },
            .non_negative => {
                if (a.ge(0)) return true;
                if (a.lt(0)) return self.violated(inst, .E0604, name, d.operand, a, "must be >= 0", "add a range like `from [0:inf)` to the parameter, or write `sqrt(abs(x))` if magnitude is what the model means");
                return false;
            },
            .unit_closed => {
                if (a.ge(-1) and a.le(1)) return true;
                if (a.gt(1) or a.lt(-1)) return self.violated(inst, .E0605, name, d.operand, a, "must satisfy -1 <= x <= 1", "add a range like `from [-1:1]` to the parameter, or clamp with `min`/`max` before the call");
                return false;
            },
            .unit_open => {
                if (a.gt(-1) and a.lt(1)) return true;
                if (a.ge(1) or a.le(-1)) return self.violated(inst, .E0606, name, d.operand, a, "must satisfy -1 < x < 1", "add a range like `from (-1:1)` to the parameter — round brackets exclude the poles");
                return false;
            },
            .ge_one => {
                if (a.ge(1)) return true;
                if (a.lt(1)) return self.violated(inst, .E0607, name, d.operand, a, "must be >= 1", "add a range like `from [1:inf)` to the parameter, or guard the call");
                return false;
            },
            else => unreachable,
        }
    }

    /// §4.3.1 Table 4-14's E0609 direction: the exponent interval fits inside
    /// ONE integer-free open cell (k, k+1), so every value it admits is
    /// fractional. The conservative failure mode is "not provable", which
    /// keeps a possibly-integer exponent on the accept-as-`.strict` path.
    fn provablyNonInteger(iv: proof_lattice.Interval) bool {
        return iv.bounded() and @floor(iv.lo) == @floor(iv.hi) and iv.lo != @floor(iv.lo);
    }

    /// §4.3.1 Table 4-14 pow with a negative base needs "all integer y".
    fn provablyInteger(self: *const Prover, v: Mir.Value) bool {
        const rv = self.mir.resolveAlias(v);
        switch (self.mir.valueDef(rv)) {
            .int_const => return true,
            .float_const => |c| return math.isFinite(c) and c == @trunc(c),
            .param_ref => |pi| return pi < self.lower.params.items.len and
                self.lower.params.items[pi].ty == .integer,
            .inst_result => |inst| {
                const op = self.mir.instOp(inst);
                // §4.2.1.2 integer→real conversion preserves integrality.
                return Mir.opIsInteger(op) or op == .if_cast;
            },
            else => return false,
        }
    }

    // ------------------------------------------------------------- messages --

    /// Provably-outside-the-domain: report it (LRM §4.3.2) and forfeit
    /// finiteness. Always returns false so the caller clears `finite`.
    ///
    /// `requirement` is the short text drawn beside the caret ("must be > 0").
    /// The RULE and the CITATION are no longer strings here — they live in the
    /// code catalogue, so there is exactly one place they can be wrong.
    fn violated(
        self: *Prover,
        inst: Mir.Inst,
        code: diag.Code,
        what: []const u8,
        operand: Mir.Value,
        iv: proof_lattice.Interval,
        requirement: []const u8,
        fix: []const u8,
    ) !bool {
        var b = self.violation(inst, code, operand, iv, what);
        b.point("{s}", .{requirement});
        b.help("{s}", .{fix});
        try self.emit(&b);
        return false;
    }

    /// The shared skeleton of every class-6 error: caret on the offending
    /// instruction, a label on whatever DEFINED the bad operand, and the
    /// operand described in the terms the user wrote it in.
    fn violation(
        self: *Prover,
        inst: Mir.Inst,
        code: diag.Code,
        operand: Mir.Value,
        iv: proof_lattice.Interval,
        what: []const u8,
    ) diag.Builder {
        var buf: [96]u8 = undefined;
        var b = self.bag.build(.proof, code, self.span(inst));
        b.msg("{s} is {s}{s}", .{ what, self.describe(operand), ivText(&buf, iv) });
        const def = self.valueSpan(operand);
        if (!def.isNone() and def.start != self.span(inst).start)
            b.label(def, "{s} originates here", .{self.describe(operand)});
        return b;
    }

    fn emit(self: *Prover, b: *diag.Builder) !void {
        if (self.error_count >= max_errors) return;
        try b.emit();
        self.error_count += 1;
    }

    // ------------------------------------------------------ finiteness warns --

    /// W0650 — THE FINITENESS WARNING.
    ///
    /// A unit that is not provably finite is LEGAL and compiles; it just
    /// compiles with `@setFloatMode(.strict)` instead of `.optimized`, which
    /// costs reassociation, fusion and vectorisation when the host compiles the
    /// emitted unit function.
    /// The engine never rejects such a model and never silently inserts a clamp
    /// or a `limexp` (see the SPEC-FAITHFUL note in the file header) — so the
    /// only honest thing left to do is TELL the user, name the value that broke
    /// the proof, and say what would fix it.
    ///
    /// `culprit` is the first value in the unit's backward slice with no
    /// finiteness evidence, which is exactly the thing to constrain.
    fn warnNotFinite(self: *Prover, unit: usize, c: Lower.Contribution, culprit: Mir.Value) !void {
        if (!self.bag.enabled(.W0650)) return;

        const access: []const u8 = if (c.access == .potential) "V" else "I";
        var b = self.bag.build(.proof, .W0650, self.lower.tokenSpan(c.tok));
        b.msg("unit {d} — {s}({s},{s}) — compiles with @setFloatMode(.strict)", .{
            unit,
            access,
            self.lower.nodeName(c.hi),
            self.lower.nodeName(c.lo),
        });

        const def = self.valueSpan(culprit);
        if (!def.isNone()) {
            b.label(def, "{s} is not provably finite", .{self.describe(culprit)});
        } else {
            b.point("{s} is not provably finite", .{self.describe(culprit)});
        }

        // Name the recovery that actually applies to THIS culprit rather than
        // listing all of them — the catalogue's `--explain` has the full set.
        switch (self.mir.valueDef(self.mir.resolveAlias(culprit))) {
            .param_ref => b.help(
                "give the parameter a range that excludes infinity, e.g. `from (0:inf)`",
                .{},
            ),
            .block_param => b.help(
                "a probe has unbounded magnitude; set `proof.Options.unknown_bound` to the solver's compliance limit",
                .{},
            ),
            .inst_result => |inst| {
                if (self.mir.instOp(inst) == .call) {
                    b.help("the prover does not model `{s}()`, so its range is unknown", .{
                        self.mir.instData(inst).call.name,
                    });
                } else {
                    b.help("constrain the operands with a range or a guard the prover can see", .{});
                }
            },
            else => {},
        }
        b.note("`.strict` is correct and spec-legal — this warning is about speed, not correctness", .{});
        try b.emit();
    }

    /// W0651 — a `from [0:inf]` range says infinity is an ACCEPTABLE VALUE for
    /// the parameter, which costs every unit downstream its proof. Writing the
    /// bound open admits the same finite values and keeps it.
    fn warnInfiniteRange(self: *Prover, pi: u32, iv: proof_lattice.Interval) !void {
        if (!self.bag.enabled(.W0651)) return;
        if (pi >= self.lower.params.items.len) return;
        const pinfo = self.lower.params.items[pi];
        // Only worth saying when the user WROTE a range: a parameter with no
        // range at all is the ordinary case and W0650 already covers it.
        if (pinfo.ranges.len == 0) return;
        // A §3.4.2 string value set (`from '{"NMOS", "PMOS"}`) is a range with
        // no bounds to close: `paramInterval` returns `.top` for every string
        // parameter, which is what reaches here as "admits infinity". Same test
        // as that function's, for the same reason.
        if (pinfo.ty == .string) return;

        var b = self.bag.build(.proof, .W0651, self.lower.tokenSpan(pinfo.tok));
        b.msg("`{s}`", .{pinfo.name});
        b.point("{s} bound is closed on infinity", .{
            if (!math.isFinite(iv.lo) and !iv.lo_open) @as([]const u8, "lower") else "upper",
        });
        b.help("close the bound instead: `[0:inf)` admits the same finite values", .{});
        try b.emit();
    }

    /// Name the operand in terms the user wrote: a parameter, a node probe, or
    /// (for a computed value) the unbounded leaf it depends on.
    fn describe(self: *const Prover, v: Mir.Value) []const u8 {
        const rv = self.mir.resolveAlias(v);
        switch (self.mir.valueDef(rv)) {
            .param_ref => |pi| return if (pi < self.lower.params.items.len)
                std.fmt.allocPrint(self.arena, "parameter `{s}`", .{self.lower.params.items[pi].name}) catch "a parameter"
            else
                "a parameter",
            .block_param => |n| return std.fmt.allocPrint(
                self.arena,
                "a probe of node `{s}`",
                .{self.lower.nodeName(@intCast(n))},
            ) catch "a node probe",
            .float_const => |c| return std.fmt.allocPrint(self.arena, "the constant {d}", .{c}) catch "a constant",
            .int_const => |c| return std.fmt.allocPrint(self.arena, "the constant {d}", .{c}) catch "a constant",
            .inst_result => |inst| {
                if (self.mir.instOp(inst) == .call)
                    return std.fmt.allocPrint(self.arena, "the result of `{s}()`", .{self.mir.instData(inst).call.name}) catch "a call result";
                if (self.unboundedLeaf(rv)) |leaf|
                    return std.fmt.allocPrint(self.arena, "an expression of {s}", .{self.describe(leaf)}) catch "an expression";
                return "a computed expression";
            },
            else => return "an unknown value",
        }
    }

    /// First leaf in the backward slice with no bound evidence — the thing the
    /// user actually has to constrain. Budgeted; purely for the message.
    fn unboundedLeaf(self: *const Prover, root: Mir.Value) ?Mir.Value {
        var stack: [64]Mir.Value = undefined;
        var n: usize = 1;
        stack[0] = root;
        var budget: u32 = 256;
        while (n > 0 and budget > 0) {
            budget -= 1;
            n -= 1;
            const v = stack[n];
            const i = self.idxOf(v);
            switch (self.mir.valueDef(@enumFromInt(i))) {
                .param_ref, .block_param => if (!self.iv[i].bounded()) return v,
                .inst_result => |inst| {
                    if (self.mir.instOp(inst) == .phi) continue;
                    var buf: [3]Mir.Value = undefined;
                    for (self.operands(inst, &buf)) |o| {
                        if (n == stack.len) break;
                        stack[n] = o;
                        n += 1;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn ivText(buf: []u8, iv: proof_lattice.Interval) []const u8 {
        if (iv.lo == -math.inf(f64) and iv.hi == math.inf(f64)) return " with no known bounds";
        return std.fmt.bufPrint(buf, " with known range {c}{d}:{d}{c}", .{
            @as(u8, if (iv.lo_open) '(' else '['),
            iv.lo,
            iv.hi,
            @as(u8, if (iv.hi_open) ')' else ']'),
        }) catch "";
    }

    // -------------------------------------------------------------- verdict --

    /// Per-unit float mode: walk each contribution's backward slice and AND the
    /// `finite` bits. See UNIT ORDERING at the top of the file.
    pub fn verdict(self: *Prover) !Verdict {
        const n = unitCount(self.lower);
        const modes = try self.gpa.alloc(FloatMode, n);
        errdefer self.gpa.free(modes);

        // GENERATION-STAMPED, not re-cleared. `u` is already the unique index
        // of the slice being walked, so "already on this slice" is
        // `seen[i] == u` and the array is cleared exactly once instead of once
        // per contribution. `none_u32` is the pre-first stamp, because `u == 0`
        // is a real generation.
        const seen = try self.arena.alloc(u32, self.an.nv);
        @memset(seen, none_u32);
        var stack: std.ArrayList(Mir.Value) = .empty;
        defer stack.deinit(self.arena);

        for (self.lower.contributions.items, 0..) |c, u| {
            const gen: u32 = @intCast(u);
            stack.clearRetainingCapacity();
            try stack.append(self.arena, c.resist_val);
            try stack.append(self.arena, c.react_val);
            var fin = true;
            // The first value with no finiteness evidence is the one the user
            // has to constrain, and so the one W0650 names.
            var culprit: Mir.Value = .undef;
            while (stack.pop()) |v| {
                const i = self.idxOf(v);
                if (seen[i] == gen) continue;
                seen[i] = gen;
                if (!self.finite[i]) {
                    fin = false;
                    culprit = v;
                    break;
                }
                const def = self.mir.valueDef(@enumFromInt(i));
                if (def != .inst_result) continue;
                const inst = def.inst_result;
                if (self.mir.instOp(inst) == .phi) {
                    const ph = self.mir.instData(inst).phi;
                    for (0..ph.count) |k|
                        try stack.append(self.arena, self.mir.phiPair(inst, @intCast(k)).value);
                    continue;
                }
                var buf: [3]Mir.Value = undefined;
                for (self.operands(inst, &buf)) |o| try stack.append(self.arena, o);
            }
            // A rejected model still gets a verdict, but never `.optimized`.
            modes[u] = if (fin and self.error_count == 0) .optimized else .strict;

            // Only warn when the model is otherwise ACCEPTED: after a domain
            // error every unit is `.strict` as a consequence, and reporting
            // that as news would bury the error that caused it.
            if (!fin and self.error_count == 0) try self.warnNotFinite(u, c, culprit);
        }

        return .{
            .unit_modes = modes,
            .error_count = self.error_count,
        };
    }
};

/// The handful of `call`s whose range the LRM fixes. Everything else is ⊤ —
/// unmodelled costs `.strict`, never a wrong `.optimized`.
pub fn callAbstract(name: []const u8) Prover.Abstract {
    const positive: proof_lattice.Interval = .{ .lo = 0, .lo_open = true, .nonzero = true };
    const non_negative: proof_lattice.Interval = .{ .lo = 0 };
    // §9.10 environment parameter functions; §4.5.13 limexp; §9.18 $mfactor.
    if (std.mem.eql(u8, name, "$vt") or // thermal voltage kT/q > 0
        std.mem.eql(u8, name, "$temperature") or // absolute temperature, kelvin
        std.mem.eql(u8, name, "$mfactor") or // multiplicity factor > 0
        std.mem.eql(u8, name, "limexp")) // §4.5.13: limited, hence finite
        return .{ .iv = positive, .finite = true };
    if (std.mem.eql(u8, name, "$abstime") or std.mem.eql(u8, name, "$realtime"))
        return .{ .iv = non_negative, .finite = true };
    // §9.13 reference algorithms can overflow or underflow (Erlang's product,
    // Student-t's divisor, and unbounded real scale parameters). A distribution
    // name alone proves no finite value; retain strict floating-point mode.
    // §9.5 the descriptor family. FINITE, and here the claim is the easy one:
    // every §9.5 call is integer-valued (`analysis.callTy`), and in a residual
    // unit — the only kind `proof` rates — the emitter renders it as the literal 0
    // §9.5.1 reserves, because the descriptor operation itself happens only in the
    // display unit (`codegen.Gen.emitting_display`). Without this line a model
    // that reads a file into its contribution compiled `.strict` on account of a
    // call the emitter had already folded to a constant.
    //
    // No interval: §9.5.1's fd has bit 31 set, so it is a large positive number
    // rather than a small one, and there is nothing useful to bound.
    if (Lower.isFileCall(name)) return .{ .iv = .top, .finite = true };
    return .{ .iv = .top, .finite = false };
}

/// LRM Table 4-14/4-15 spelling of an opcode, for diagnostics.
pub const opLabel = Mir.opcode.label;

// --- endpoint arithmetic: NaN (inf-inf) folds to the wide side. A UNARY NaN
// endpoint is never folded any more: it means "operand straddles the domain
// edge" and the transfer answers ⊤ (see the monotone path) — the old fold to
// +inf sat on the WRONG side for ln/sqrt/asin and produced narrow intervals.

pub fn addLo(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) -math.inf(f64) else r;
}

pub fn addHi(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) math.inf(f64) else r;
}

pub fn mulOp(a: f64, b: f64) f64 {
    return a * b;
}
pub fn divOp(a: f64, b: f64) f64 {
    return a / b;
}
pub fn powOp(a: f64, b: f64) f64 {
    return math.pow(f64, a, b);
}

/// §4.3.1 Table 4-14 pow(x,y) over a box. Corner combination is sound only
/// where pow is monotone in each argument separately, which fails in exactly
/// the ways a negative base admits:
///   - even integer exponent: interior MINIMUM at x = 0 (corners pow(±2,2)=4
///     fabricated [4,4] where the truth is [0,4] — and from that lie both a
///     wrong `.optimized` sqrt(pow(x,2)-1) and a wrong E0602 reject of
///     ln(2-pow(x,2)) were derived);
///   - non-integer exponent: pow(neg, frac) is NaN (§4.3.1's "if x < 0, all
///     integer y"), which corners at integer endpoints never see;
///   - negative exponent: pole at x = 0, and IEEE pow(+0,-odd) = +inf is the
///     WRONG side of the two-sided pole a base interval reaching 0 straddles.
pub fn powIv(x: proof_lattice.Interval, y: proof_lattice.Interval) proof_lattice.Interval {
    // x >= 0: pow = exp(y·ln x) is monotone in x for fixed y and in y for
    // fixed x, so box extrema sit at corners; IEEE fills the x = 0 edge
    // (pow(0,neg)=+inf, pow(0,0)=1) on the corners too. `combine`'s NaN guard
    // covers the exotic corners.
    if (x.ge(0)) return combine(x, y, powOp);
    // Base can be negative: only an exponent pinned to ONE known integer k
    // supports any claim (an integer-valued RANGE mixes parities, and a
    // possibly-fractional exponent means possible NaN) — else ⊤.
    const k = y.lo;
    if (!(y.lo == y.hi and math.isFinite(k) and k == @trunc(k))) return .top;
    if (k >= 0) {
        // Even k: x^k = |x|^k exactly, monotone in |x|; absIv restores the
        // interior 0 a sign-spanning base reaches. Odd k: monotone on all of R.
        // (Doubles >= 2^53 are all even integers, so @mod stays honest there.)
        if (@mod(k, 2) == 0) {
            const m = absIv(x);
            return .{ .lo = powOp(m.lo, k), .hi = powOp(m.hi, k) };
        }
        return .{ .lo = powOp(x.lo, k), .hi = powOp(x.hi, k) };
    }
    // k < 0: pole at 0. Sound only for a STRICTLY negative base (x.hi < 0 —
    // an open-at-0 bound is not enough: IEEE pow(+0, -odd) is +inf while the
    // one-sided limit from below is -inf). x^k is then monotone on the side.
    if (x.hi < 0) {
        const a = powOp(x.lo, k);
        const b = powOp(x.hi, k);
        return .{ .lo = @min(a, b), .hi = @max(a, b) };
    }
    // Punctured or zero-touching negative base with a negative exponent: the
    // same both-sided pole as the fdiv puncture ⇒ ⊤.
    return .top;
}

/// Endpoint-combination for the non-monotone binary ops: all four corners,
/// closed result (openness is not derivable through a product). A NaN corner
/// (0*inf, 0/0, inf/inf) means the abstraction cannot say anything ⇒ ⊤.
///
/// SOUNDNESS PRECONDITION: corners bound f over the box only when f is
/// monotone in each argument separately there. `*` is bilinear (always
/// eligible); `/` is eligible only for a ONE-SIGNED divisor (the `.fdiv`
/// transfer guards this — a punctured sign-spanning divisor has a two-branch
/// range no corner attains); `pow` is eligible only for x >= 0 (`powIv`
/// guards the negative-base parity/pole cases).
pub fn combine(x: proof_lattice.Interval, y: proof_lattice.Interval, f: *const fn (f64, f64) f64) proof_lattice.Interval {
    const c = [4]f64{ f(x.lo, y.lo), f(x.lo, y.hi), f(x.hi, y.lo), f(x.hi, y.hi) };
    var lo = math.inf(f64);
    var hi = -math.inf(f64);
    for (c) |v| {
        if (math.isNan(v)) return .top;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    return .{ .lo = lo, .hi = hi };
}

pub fn absIv(a: proof_lattice.Interval) proof_lattice.Interval {
    if (a.ge(0)) return a;
    if (a.le(0)) return .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open };
    return .{ .lo = 0, .hi = @max(@abs(a.lo), @abs(a.hi)) };
}
