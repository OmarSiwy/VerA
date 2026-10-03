//! The prover: one dominator-order walk that rates every unit `.optimized` or `.strict`.
//! In: MIR, analysis facts and Lower's parameter ranges. Out: an interval, a finite bit and a
//! guard set per value, and a compile error only for a provably out-of-domain argument.
//! LRM §2.7, §3.4.2, §4.2, §4.2.4, §4.2.5, §4.2.8, §4.2.12, §4.3.1, §4.3.2, §4.5.13, §9.5, §9.5.1.

const std = @import("std");
const proof = @import("../proof.zig");
const proof_lattice = @import("lattice.zig");
const proof_transfer = @import("transfer.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("../mir.zig");
const Lower = @import("../lower.zig");
const Lowered = Lower.Lowered;
const Analysis = @import("../analysis.zig");
const diag = @import("diag");
const math = proof.math;
const FloatMode = proof.FloatMode;
const Verdict = proof.Verdict;
const Options = proof.Options;
const max_errors = proof.max_errors;
const unitCount = proof.unitCount;

/// A guard fact: "this Value is confined to this interval here".
pub const Fact = struct { v: u32, iv: proof_lattice.Interval };

/// Where a value's select-arm guard facts live in `facts`.
pub const GuardRef = struct { start: u32 = 0, count: u32 = 0 };

// Row budgets: `Fact` per guard (psp103: 2,732 select-arm facts), `GuardRef`
// per value (psp103: 23,869), `Interval` per value (see its layout note).
comptime {
    std.debug.assert(@sizeOf(Fact) == 32);
    std.debug.assert(@sizeOf(GuardRef) == 8);
    std.debug.assert(@sizeOf(proof_lattice.Interval) == 24);
}

/// "No index" sentinel for `u32` side tables.
pub const none_u32 = std.math.maxInt(u32);

/// The prover's state for one `proveOpts` call. Every slice lives in `arena`.
pub const Prover = struct {
    gpa: std.mem.Allocator,
    /// Scratch arena; dies with `prove`.
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    opts: Options,

    // --- SoA, indexed by @intFromEnum(Mir.Value) ---
    iv: []proof_lattice.Interval = &.{},
    /// "Is a finite IEEE double" (the rules on `proof.FloatMode`), recorded at definition time.
    // `[]bool`, not a bit set: every access is a random probe by value index, and value
    // counts are small, so a bit set saves a few bytes and costs a shift and a mask.
    finite: []bool = &.{},
    /// Use count, for the single-use test that scopes a §4.2.12 select guard.
    uses: []u32 = &.{},
    guard: []GuardRef = &.{},
    /// Congruence class per value (`none_u32` = alone). Two structurally identical pure
    /// instructions compute the same number, so a guard fact about one holds for all of them.
    /// That is what lets `if (V(p,n) > 0) ... ln(V(p,n))` prove, since lowering emits a fresh
    /// `fsub` per `V(p,n)` occurrence. Internal to this pass; codegen recomputes per unit.
    /// ponytail: structural key on already-resolved operands only (no
    /// transitive numbering). Upgrade to a real GVN if a fixture needs it.
    class_of: []u32 = &.{},
    class_member: []u32 = &.{},
    class_start: []u32 = &.{},

    facts: std.ArrayList(Fact) = .empty,
    /// Save stack for guard application (dominator-tree DFS + select arms).
    saved: std.ArrayList(Fact) = .empty,

    /// The CFG, dominator tree and natural loops, owned by `analysis.zig`. Read-only here.
    an: Analysis = undefined,
    /// Blocks `walk` has reached; `[]bool` for the same reason as `finite`.
    visited_block: []bool = &.{},
    /// §4.2.3 suppresses runtime domain errors on a provably untaken edge.
    /// Transfers still run conservatively; source typing happened in lowering.
    domain_active: bool = true,

    /// Where every finiteness diagnostic goes. Shared with the other stages.
    bag: *diag.Bag,
    /// §4.3.2 violations reported so far: the accept/reject decision.
    error_count: u32 = 0,

    /// Source span of an instruction, or none for an unattributed one.
    fn span(self: *const Prover, inst: Mir.Inst) diag.Span {
        const tok = self.mir.instTok(inst);
        // Token 0 is the first line of the annex D prelude, not a location.
        if (tok == Mir.no_tok) return .{};
        return self.lowered.tokenSpan(tok);
    }

    /// Span of whatever DEFINED a value, so a label can point at the parameter
    /// or the sub-expression the prover is really complaining about.
    fn valueSpan(self: *const Prover, v: Mir.Value) diag.Span {
        switch (self.mir.valueDef(self.an.rv(v))) {
            .inst_result => |inst| return self.span(inst),
            .param_ref => |pi| {
                if (pi >= self.lowered.params.items.len) return .{};
                const tok = self.lowered.params.items[pi].tok;
                if (tok == Mir.no_tok) return .{};
                return self.lowered.tokenSpan(tok);
            },
            .undef, .float_const, .int_const, .str_const, .block_param => return .{},
        }
    }

    /// Every read of a Value goes through the alias map (ssa.zig contract),
    /// as `Analysis`'s snapshot: one load, where `Mir.resolveAlias` walks.
    fn idxOf(self: *const Prover, v: Mir.Value) u32 {
        return @backingInt(self.an.rv(v));
    }

    fn ivOf(self: *const Prover, v: Mir.Value) proof_lattice.Interval {
        return self.iv[self.idxOf(v)];
    }

    fn isFinite(self: *const Prover, v: Mir.Value) bool {
        return self.finite[self.idxOf(v)];
    }

    // -------------------------------------------------------------- seeding --

    /// Seeds the abstract state of every value from constants, §3.4.2 ranges and §4.4 probes.
    /// Only `inst_result` values stay `top`; `walk` fills those. Emits W0651.
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
            const v: Mir.Value = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            switch (self.mir.valueDef(v)) {
                // §4.2 constant expressions: exact.
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
                // §3.4.2: the primary bound evidence.
                .param_ref => |pi| {
                    const iv = self.paramInterval(pi);
                    self.iv[i] = iv;
                    self.finite[i] = iv.excludesInf();
                    // A written range that admits infinity is almost always a
                    // typo for the open bound (W0651).
                    if (!self.finite[i]) try self.warnInfiniteRange(pi);
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

    /// LRM §3.4.2 value ranges as one interval. `from` ranges are unioned (their convex hull;
    /// the representation has no holes), and `exclude` ranges are subtracted only where they
    /// clip an end, which is the `exclude 0` / `from (0:inf)` evidence a divisor or `ln` needs.
    ///
    /// Bounds fold literally (`foldBound`), never through `Lower.constEval`: a bound written
    /// in terms of another parameter would fold to that parameter's default, which the model
    /// card can override, so using it would be unsound.
    fn paramInterval(self: *const Prover, param: u32) proof_lattice.Interval {
        if (param >= self.lowered.params.items.len) return .top;
        const info = self.lowered.params.items[param];
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
            // points from the value range." So an end point of an `exclude` is
            // excluded only when its bracket is square: `exclude (0:5)` still
            // admits 0, and reading `nonzero` from it would hand the unit
            // `.optimized` over a division by a value the range permits.
            // `exclude 0` works because `hi == .none` copies `lo` and both
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
        // §3.2.1 fixes `integer` at 32 bits, so a model-card integer never
        // holds an infinity whatever ranges were written. `integerIv` states
        // the same fact for integer results.
        if (info.ty == .integer)
            iv = iv.meet(.{ .lo = -2147483648.0, .hi = 2147483647.0 });
        return iv;
    }

    /// Literal-only constant fold of a §3.4.2 range bound, through the one
    /// constant kernel, so a bound means what lowering enforces (`[1/2:1]` is
    /// [0,1], §4.2.4). Deliberately refuses identifiers (see
    /// `paramInterval`); `inf` (§3.4.2) folds to ±infinity.
    fn foldBound(self: *const Prover, e: Ast.ExprId) ?f64 {
        const c = constfold.fold(self.lowered.file, e, constfold.literal_env) orelse return null;
        return if (c == .str) null else c.asReal();
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
            // phi operands are (block, value) pairs; callers use `phiPair`.
            .phi => buf[0..0],
            .anew => buf[0..0],
            .load => |l| blk: {
                buf[0] = l.arr;
                buf[1] = l.index;
                break :blk buf[0..2];
            },
            .store => |st| blk: {
                buf[0] = st.arr;
                buf[1] = st.index;
                buf[2] = st.value;
                break :blk buf[0..3];
            },
        };
    }

    /// Groups structurally identical pure instructions into congruence classes. Phi, call,
    /// terminators, `opt_barrier`, `anew` and `store` are never merged.
    pub fn buildClasses(self: *Prover) !void {
        const n = self.an.nv;
        self.class_of = try self.arena.alloc(u32, n);
        @memset(self.class_of, none_u32);

        const Key = struct { op: Mir.Opcode, a: u32, b: u32, c: u32 };
        var map: std.AutoHashMapUnmanaged(Key, u32) = .empty;
        defer map.deinit(self.arena);
        var n_classes: u32 = 0;

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            const op = self.mir.instOp(inst);
            // §3.2.2 two `anew`s of one array, or two equal stores, are two
            // versions of one storage at two times, not one value.
            if (op == .phi or op == .call or op == .opt_barrier or op == .anew or op == .store) continue;
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

    /// Marks each `select` arm's exclusively-owned backward slice (use count 1) as guarded by
    /// the select condition, since a `select`'s arms carry no CFG dominance.
    /// `?:` lowers to a real diamond (§4.2.3), so this covers the other selects: masked
    /// element writes at a runtime array index (`lowerAssign`) and the §5.10.3.3 `enable` fold.
    /// Codegen obligation: a guarded `select` must evaluate only the taken arm, or `ln(x)`
    /// runs with x <= 0 and the guard is false.
    pub fn markSelectArms(self: *Prover) !void {
        // Use counts first: the single-use test is what scopes an arm.
        self.countUses();

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            if (self.mir.instOp(inst) != .select) continue;
            const t = self.mir.instData(inst).ternary;
            try self.markArm(t.then_val, t.cond, true);
            try self.markArm(t.else_val, t.cond, false);
        }
    }

    /// How often each value is read, alias-resolved. It walks block chains, so a row in no
    /// chain (the branch and jumps if-conversion orphans) is not a use. It skips a collapsed
    /// phi's operands (ssa.zig contract 1): the phi aliases the value they resolve to, which its
    /// users already count; counting both would make single-use arm values look shared.
    /// Contribution roots count once each, so a root is never taken for an exclusive arm.
    fn countUses(self: *Prover) void {
        const mir = self.mir;
        for (self.lowered.contributions.items) |c| {
            self.uses[self.idxOf(c.resist_val)] += 1;
            self.uses[self.idxOf(c.react_val)] += 1;
        }
        for (0..mir.blockCount()) |b| {
            var it = mir.blockInsts(@fromBackingInt(@intCast(@as(u32, @intCast(b)))));
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
            const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
            if (def != .inst_result) continue;
            self.guard[i] = ref;
            const inst = def.inst_result;
            if (self.mir.instOp(inst) == .phi) continue; // a phi is not arm-local
            var buf: [3]Mir.Value = undefined;
            for (self.operands(inst, &buf)) |o| try stack.append(self.arena, o);
        }
    }

    fn literalNumber(self: *const Prover, v: Mir.Value) ?f64 {
        return switch (self.mir.valueDef(self.an.rv(v))) {
            .int_const => |c| @floatFromInt(c),
            .float_const => |c| c,
            .inst_result => |inst| blk: {
                if (self.mir.instOp(inst) != .if_cast) break :blk null;
                const def = self.mir.valueDef(self.an.rv(self.mir.instData(inst).unary.operand));
                break :blk if (def == .int_const) @as(f64, @floatFromInt(def.int_const)) else null;
            },
            .undef, .str_const, .param_ref, .block_param => null,
        };
    }

    fn isZeroConst(self: *const Prover, v: Mir.Value) bool {
        return (self.literalNumber(v) orelse return false) == 0.0;
    }

    /// Facts implied by taking (or not taking) a branch on `cond`.
    /// LRM §4.2.5 relational / §4.2.7 equality operators; `&&`/`||` need no case
    /// because §4.2.8 short-circuit gives them real CFG (see lower.zig).
    fn condFacts(self: *const Prover, cond: Mir.Value, taken: bool, buf: *[2]Fact) []const Fact {
        const def = self.mir.valueDef(self.an.rv(cond));
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
                const cmp = Mir.opcode.get(b.op).rel orelse return buf[0..0];
                const Rel = enum { lt, le, eq, none };
                var rel: Rel = .none;
                var swap = false;
                switch (cmp) {
                    .lt => rel = if (taken) .lt else .none,
                    .le => rel = if (taken) .le else .none,
                    .gt => {
                        swap = true;
                        rel = if (taken) .lt else .none;
                    },
                    .ge => {
                        swap = true;
                        rel = if (taken) .le else .none;
                    },
                    .eq => rel = if (taken) .eq else .none,
                    .ne => rel = if (taken) .none else .eq,
                }
                // The negated strict/loose forms: !(a<b) ⇒ b<=a, !(a<=b) ⇒ b<a.
                if (!taken) switch (cmp) {
                    .lt => {
                        rel = .le;
                        swap = true;
                    },
                    .le => {
                        rel = .lt;
                        swap = true;
                    },
                    .gt => {
                        rel = .le;
                        swap = false;
                    },
                    .ge => {
                        rel = .lt;
                        swap = false;
                    },
                    .eq, .ne => {},
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
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => {},
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

    /// Evaluates every instruction in dominator-tree preorder, so a guard applied on the edge
    /// into a block holds for the subtree it dominates and is undone on the way out. Checks
    /// every evaluated domain. Untaken constant edges suppress runtime errors
    /// (§4.2.3), while transfer still visits every source instruction.
    ///
    /// SSA puts every non-phi operand before its use. A phi operand from an unprocessed
    /// predecessor (a loop back edge, §5.9) is still top and not finite, so loops widen to
    /// top at once: sound and terminating.
    pub fn walk(self: *Prover) !void {
        // ponytail: immediate widening loses loop-carried bounds. Upgrade path if a
        // real model needs them: an ascending-chain worklist from bottom, widening
        // after k rounds, iterating only the natural loop body (`Analysis.loop_of`).
        // Genvar loops (§6.6.1) unroll, so this bites `while` only.
        const nb = self.an.nb;
        if (nb == 0) return;
        self.visited_block = try self.arena.alloc(bool, nb);
        @memset(self.visited_block, false);

        try self.walkDom(0);

        // Unreachable source has already been parsed and type checked; its
        // runtime domains are not evaluated (§4.2.3).
        self.domain_active = false;
        for (0..nb) |b| if (!self.visited_block[b]) try self.walkBlock(@intCast(b));
        self.domain_active = true;
    }

    fn walkDom(self: *Prover, b: u32) !void {
        const mark = self.saved.items.len;
        defer self.popFacts(mark);
        const active = self.domain_active;
        defer self.domain_active = active;

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
                    const taken = @backingInt(d.branch.then_block) == b;
                    if (!taken and @backingInt(d.branch.else_block) != b) continue;
                    if (self.an.foldConst(d.branch.cond, false)) |c| {
                        if ((c.f != 0) != taken) self.domain_active = false;
                    }
                    var raw: [2]Fact = undefined;
                    try self.pushFacts(self.condFacts(d.branch.cond, taken, &raw));
                }
            }
        }

        try self.walkBlock(b);
        for (self.an.domKids(b)) |c| try self.walkDom(c);
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

        // An unprovable domain is not an error (LRM §4.3.2, see checkDomain);
        // it costs the result its finiteness fact, which drops the enclosing
        // unit to `@setFloatMode(.strict)` where NaN/inf are IEEE-defined.
        const domain_proven = if (self.domain_active) try self.checkDomain(inst) else false;
        if (result == .undef) return; // terminator

        const out = self.transfer(inst);
        // MEET, not assign: a guard pushed on this value's congruence class
        // before its definition (the `if (V>0) … ln(V)` shape) must survive its
        // own transfer. `pushFacts` saved the pre-guard interval, so nothing
        // leaks out of the scope.
        self.iv[ri] = out.iv.meet(self.iv[ri]);
        self.finite[ri] = out.finite and domain_proven;
    }

    /// Transfer function. Intervals are computed for the DOMAIN proof; `finite`
    /// is the separate fact (rules on `proof.FloatMode`) that drives the float mode.
    fn transfer(self: *Prover, inst: Mir.Inst) proof_transfer.Abstract {
        const op = self.mir.instOp(inst);

        // §4.2.5/§4.2.8: integer-valued results are finite by construction and
        // never pollute the float mode.
        if (Mir.opIsInteger(op)) return .{ .iv = proof_transfer.integerIv(op), .finite = true };

        switch (self.mir.instData(inst)) {
            .unary => |u| {
                const a = self.ivOf(u.operand);
                const af = self.isFinite(u.operand);
                return proof_transfer.unaryTransfer(op, a, af);
            },
            .binary => |b| {
                const x = self.ivOf(b.lhs);
                const y = self.ivOf(b.rhs);
                const f = self.isFinite(b.lhs) and self.isFinite(b.rhs);
                return proof_transfer.binaryTransfer(op, x, y, f);
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
            .call => |c| return self.callTransfer(c.callee, c.args),
            .branch, .jump => return .{ .iv = .top, .finite = false },
            // §3.2.2 an array version's interval covers every element. A
            // fresh local array is all zero (§3.2); a held one holds what the
            // last accepted evaluation stored, which nothing here bounds:
            // the `$held_real` seed's ⊤. A store widens by what it stores.
            .anew => |a| return if (self.lowered.mem_arrays.items[a.array].held == Lower.none_u32)
                .{ .iv = proof_lattice.Interval.point(0), .finite = true }
            else
                .{ .iv = .top, .finite = false },
            .store => |st| return .{
                .iv = self.ivOf(st.arr).join(self.ivOf(st.value)),
                .finite = self.isFinite(st.arr) and self.isFinite(st.value),
            },
            // An element, or the zero an index outside the array reads.
            .load => |l| return .{
                .iv = self.ivOf(l.arr).join(proof_lattice.Interval.point(0)),
                .finite = self.isFinite(l.arr),
            },
        }
    }

    /// `callAbstract`, plus the two calls whose range depends on their argument.
    /// `callAbstract`'s argument-free claim (positive, nonzero, finite) would be unsound for
    /// them: `1.0/$vt(V(p,n))` and `1.0/limexp(V(p,n))` can divide by zero.
    fn callTransfer(self: *Prover, c: Mir.Callee, args: []const Mir.Value) proof_transfer.Abstract {
        if (args.len == 1) {
            const a = self.ivOf(args[0]);
            const af = self.isFinite(args[0]);
            switch (c) {
                // §9.15 `$vt(T)` = kT/q: T's sign, T's finiteness. $vt(0) = 0.
                // Only the argument-free form reads the (positive) simulator
                // temperature. The factor is codegen's; only its sign matters to a
                // domain proof.
                .@"$vt" => return .{ .iv = proof_transfer.combine(a, proof_lattice.Interval.point(8.617333262145179e-5), proof_transfer.mulOp), .finite = af },
                // §4.5.13: "The apparent behavior of limexp() is not
                // distinguishable from exp()", so exp's interval; exp(x)
                // underflows to 0.0 below about -745, so not nonzero. Finite
                // exactly when its argument is: the linearised side does not
                // overflow the way exp does (rule 3 covers its slope).
                .limexp => return .{ .iv = proof_transfer.unaryTransfer(.exp, a, af).iv, .finite = af },
                else => {}, // else: every other range is argument-free, `callAbstract`'s
            }
        }
        return proof_transfer.callAbstract(c);
    }

    // ------------------------------------------------------- domain proofs --

    /// LRM §4.3.2: "Input values outside of the valid range for the operator
    /// shall report an error." That obliges reporting a value that is out of
    /// range, not rejecting a program whose values might be, so the check is
    /// three-way:
    ///
    ///   provably outside the domain -> compile error
    ///   provably inside             -> true, may stay `.optimized`
    ///   straddles or unprovable     -> accepted, false: the caller clears
    ///                                  `finite` and the unit goes `.strict`
    ///
    /// This keeps VerA's accepted set equal to the LRM's. Interval arithmetic
    /// cannot decide the common `x = V/(1+abs(V))` idiom (it would have to
    /// correlate two occurrences of V), so a two-way check would reject legal
    /// models. Returns true when the domain is proven or not applicable.
    fn checkDomain(self: *Prover, inst: Mir.Inst) !bool {
        const op = self.mir.instOp(inst);
        const dom = proof_lattice.domainOf(op);
        if (dom == .all) return true;

        switch (dom) {
            // Integer `/`, and `%` of either type (§4.2.4). The same three-way
            // rule as every other domain: "It shall be an error to pass zero
            // (0) as the second argument to the modulus operator" applies when
            // the divisor is zero, so a provably-zero divisor is E0601 and an
            // unprovable one is accepted and forfeits `finite`:
            //   - real `%`: `@rem(x, 0.0)` is NaN, IEEE-defined under `.strict`;
            //   - integer `/`: codegen guards it (`render.zig`'s `.idiv`), since
            //     `@divTrunc(i64, 0)` is illegal behavior in Zig, and a zero
            //     divisor yields 0, which W0653 announces.
            //   - integer `%`: codegen reports E0601 at execution (or traps
            //     in a solver device), without evaluating Zig's `%` by zero.
            .nonzero_divisor => {
                const d = self.mir.instData(inst).binary;
                const y = self.ivOf(d.rhs);
                if (y.excludesZero() or y.isEmpty()) return true;
                const what = if (op == .fmod or op == .imod) "`%` divisor" else "`/` divisor";
                if (y.lo == 0 and y.hi == 0)
                    return self.violated(inst, .E0601, what, d.rhs, y, "is provably zero", "a zero divisor is an error (§4.2.4); check the expression or the parameter's range");
                // Legal, but not silent: the guarded device division yields
                // 0 for a zero divisor, a value the LRM does not give.
                if (op == .idiv) try self.warnIntDivisor(inst, d.rhs, y);
                return false;
            },
            .pow_sign => { // §4.3.1 Table 4-14
                const d = self.mir.instData(inst).binary;
                const x = self.ivOf(d.lhs);
                const y = self.ivOf(d.rhs);
                if (x.isEmpty() or y.isEmpty()) return true;
                if (x.gt(0)) return true; // x > 0, all y
                if (x.ge(0) and y.gt(0)) return true; // x = 0, y > 0
                // The two provable violations of Table 4-14's domain (E0609),
                // held to the same three-way standard as E0602-E0607: reject
                // only when every admitted value pair violates.
                //   x == 0 always, y < 0 always: pow is +inf on every
                //   execution ("if x = 0, all y > 0"). Checked before the
                //   integer-exponent accept, whose clause is the x < 0 row and
                //   does not rescue a zero base. (y = 0 is left alone: IEEE
                //   pow(0,0) = 1, the same leniency `x/0.0` gets.)
                if (x.lo == 0 and x.hi == 0 and !x.nonzero and y.lt(0))
                    return self.violated(inst, .E0609, "pow() exponent", d.rhs, y, "must be >= 0 — the base is provably zero", "constrain the exponent with `from [0:inf)`, or the base with `exclude 0`");
                if (self.provablyInteger(d.rhs)) return true; // x < 0, integer y
                //   x < 0 always, y fractional always: pow is NaN on every
                //   execution ("if x < 0, all integer y").
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
                // No reject arm: the poles are irrational and every double is
                // rational, so even a point interval is never provably at one.
                // Unprovable -> `.strict`, where a pole yields an IEEE infinity.
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
        const rv = self.an.rv(v);
        switch (self.mir.valueDef(rv)) {
            .int_const => return true,
            .float_const => |c| return math.isFinite(c) and c == @trunc(c),
            .param_ref => |pi| return pi < self.lowered.params.items.len and
                self.lowered.params.items[pi].ty == .integer,
            .inst_result => |inst| {
                const op = self.mir.instOp(inst);
                // §4.2.1.2 integer→real conversion preserves integrality.
                return Mir.opIsInteger(op) or op == .if_cast;
            },
            .undef, .str_const, .block_param => return false,
        }
    }

    // ------------------------------------------------------------- messages --

    /// Reports a provably out-of-domain argument (LRM §4.3.2). Always returns false so the
    /// caller clears `finite`. `requirement` is the short text beside the caret
    /// ("must be > 0"); the rule and citation live in the code catalogue.
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

    /// The shared skeleton of every finiteness error: caret on the offending
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

    /// W0650: a unit that is not provably finite. The model is legal, but the unit rates
    /// `.strict`, and codegen compiles the shared core in the strictest mode of its jobs
    /// (`float/mode.zig` `coreMode`), which costs reassociation, fusion and vectorisation.
    /// The engine never inserts a clamp or `limexp`, so it names the value that broke the
    /// proof instead. `culprit` is the first value in the unit's backward slice with no
    /// finiteness evidence.
    fn warnNotFinite(self: *Prover, unit: usize, c: Lower.Contribution, culprit: Mir.Value) !void {
        if (!self.bag.enabled(.W0650)) return;

        const access: []const u8 = if (c.access == .potential) "V" else "I";
        var b = self.bag.build(.proof, .W0650, self.lowered.tokenSpan(c.tok));
        b.msg("unit {d} — {s}({s},{s}) — compiles with @setFloatMode(.strict)", .{
            unit,
            access,
            self.lowered.nodeName(c.hi),
            self.lowered.nodeName(c.lo),
        });

        const def = self.valueSpan(culprit);
        if (!def.isNone()) {
            b.label(def, "{s} is not provably finite", .{self.describe(culprit)});
        } else {
            b.point("{s} is not provably finite", .{self.describe(culprit)});
        }

        // Name the recovery for this culprit only; `--explain` has the full set.
        switch (self.mir.valueDef(self.an.rv(culprit))) {
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
            .undef, .float_const, .int_const, .str_const => {},
        }
        b.note("`.strict` is correct and spec-legal — this warning is about speed, not correctness", .{});
        try b.emit();
    }

    /// W0653: an integer `/` whose divisor the prover cannot show non-zero.
    /// Accepted (§4.2.4 has no zero rule for `/`), but the device's guarded division yields 0
    /// where IEEE 1364 §5.1.5 would yield `x`, which an analog integer cannot hold.
    /// Does not touch `error_count`.
    fn warnIntDivisor(self: *Prover, inst: Mir.Inst, divisor: Mir.Value, iv: proof_lattice.Interval) !void {
        if (!self.bag.enabled(.W0653)) return;
        var b = self.violation(inst, .W0653, divisor, iv, "integer `/` divisor");
        b.point("cannot be proven non-zero; if it is zero at run time the result is 0", .{});
        b.help("give the parameter `exclude 0` or `from [1:inf)`, guard the division with an `if` the prover can see, or pass `--allow=W0653`", .{});
        try b.emit();
    }

    /// W0651: a `from [0:inf]` range admits infinity as a value, which costs every unit
    /// downstream its proof. The open bound admits the same finite values and keeps it.
    fn warnInfiniteRange(self: *Prover, pi: u32) !void {
        if (!self.bag.enabled(.W0651)) return;
        if (pi >= self.lowered.params.items.len) return;
        const pinfo = self.lowered.params.items[pi];
        // A §3.4.2 string value set (`from '{"NMOS", "PMOS"}`) has no bounds
        // to close; `paramInterval` returns `.top` for every string parameter.
        if (pinfo.ty == .string) return;
        // Only a `from` bound WRITTEN as a closed `inf` (§3.4.2 "The keyword inf
        // can be used to indicate infinity") admits infinity. `exclude 0` alone,
        // or a bound naming another parameter, leaves the interval unbounded
        // without admitting it; W0650 covers those.
        const inf = math.inf(f64);
        const side: []const u8 = for (pinfo.ranges) |r| {
            if (r.kind != .from or r.strings != null) continue;
            if (r.lo_inclusive and (self.foldBound(r.lo) orelse 0) == -inf) break "lower";
            const hi = if (r.hi == .none) r.lo else r.hi;
            if (r.hi_inclusive and (self.foldBound(hi) orelse 0) == inf) break "upper";
        } else return;

        var b = self.bag.build(.proof, .W0651, self.lowered.tokenSpan(pinfo.tok));
        b.msg("`{s}`", .{pinfo.name});
        b.point("{s} bound is closed on infinity", .{side});
        b.help("close the bound instead: `[0:inf)` admits the same finite values", .{});
        try b.emit();
    }

    /// Name the operand in terms the user wrote: a parameter, a node probe, or
    /// (for a computed value) the unbounded leaf it depends on.
    fn describe(self: *const Prover, v: Mir.Value) []const u8 {
        const rv = self.an.rv(v);
        switch (self.mir.valueDef(rv)) {
            .param_ref => |pi| return if (pi < self.lowered.params.items.len)
                self.arena.print("parameter `{s}`", .{self.lowered.params.items[pi].name}) catch "a parameter"
            else
                "a parameter",
            .block_param => |n| return self.arena.print(
                "a probe of node `{s}`",
                .{self.lowered.nodeName(@intCast(n))},
            ) catch "a node probe",
            .float_const => |c| return self.arena.print("the constant {d}", .{c}) catch "a constant",
            .int_const => |c| return self.arena.print("the constant {d}", .{c}) catch "a constant",
            .inst_result => |inst| {
                if (self.mir.instOp(inst) == .call)
                    return self.arena.print("the result of `{s}()`", .{self.mir.instData(inst).call.name}) catch "a call result";
                if (self.unboundedLeaf(rv)) |leaf|
                    return self.arena.print("an expression of {s}", .{self.describe(leaf)}) catch "an expression";
                return "a computed expression";
            },
            .undef, .str_const => return "an unknown value",
        }
    }

    /// First leaf in the backward slice with no bound evidence: the thing the user has to
    /// constrain. Budgeted; used only for the message.
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
            switch (self.mir.valueDef(@fromBackingInt(@intCast(i)))) {
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
                .undef, .float_const, .int_const, .str_const => {},
            }
        }
        return null;
    }

    fn ivText(buf: []u8, iv: proof_lattice.Interval) []const u8 {
        if (iv.lo == -math.inf(f64) and iv.hi == math.inf(f64)) return " with no known bounds";
        return std.mem.print(buf, " with known range {c}{d}:{d}{c}", .{
            @as(u8, if (iv.lo_open) '(' else '['),
            iv.lo,
            iv.hi,
            @as(u8, if (iv.hi_open) ')' else ']'),
        }) catch "";
    }

    // -------------------------------------------------------------- verdict --

    /// Rates each unit by ANDing the `finite` bits over its contribution's backward slice
    /// (order: `proof.Verdict.unit_modes`), and emits W0650 for accepted `.strict` units.
    /// Caller owns `unit_modes`, allocated with `gpa`.
    pub fn verdict(self: *Prover) !Verdict {
        const n = unitCount(self.lowered);
        const modes = try self.gpa.alloc(FloatMode, n);
        errdefer self.gpa.free(modes);

        // Generation-stamped, not re-cleared: "already on this slice" is
        // `seen[i] == u`. `none_u32` is the pre-first stamp, because `u == 0`
        // is a real generation.
        const seen = try self.arena.alloc(u32, self.an.nv);
        @memset(seen, none_u32);
        var stack: std.ArrayList(Mir.Value) = .empty;
        defer stack.deinit(self.arena);

        for (self.lowered.contributions.items, 0..) |c, u| {
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
                const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
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

            // Warn only when the model is otherwise accepted: after a domain
            // error every unit is `.strict` anyway, and warning would bury the error.
            if (!fin and self.error_count == 0) try self.warnNotFinite(u, c, culprit);
        }

        return .{
            .unit_modes = modes,
            .error_count = self.error_count,
        };
    }
};

/// LRM Table 4-14/4-15 spelling of an opcode, for diagnostics.
const opLabel = Mir.opcode.label;
