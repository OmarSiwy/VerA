//! Target-independent facts about a lowered module: Mir + Lowered → CFG,
//! dominator tree, natural loops, flattened per-block instruction pools, and
//! per-Value tables (type, alias snapshot, derivative dependencies, array
//! owner, constant fold). Built once, then read-only. Nothing here knows the
//! target is Zig, so `ir/` never imports `backend/`; per-unit scheduling tables
//! belong to the emitter.

const std = @import("std");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const Lowered = Lower.Lowered;
const Ast = @import("frontend").Ast;
const Const = @import("frontend").constfold.Const;
const op_kind = @import("op.zig");

/// File-as-struct: `@import("analysis.zig")` is both the namespace and the type.
pub const Analysis = @This();

/// Every builder here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

/// How a Value is emitted: as the generic scalar `S` (real), a plain `i64`
/// (§3.2 integer) or a string. §4.2.1.1/§4.2.1.2 conversions are inserted at the use
/// site, so a typing miss degrades to a redundant cast, never to code that does
/// not compile.
pub const VTy = Mir.callee.Ty;

/// Owns every table below.
arena: std.mem.Allocator,
/// Borrowed; must outlive the Analysis and not change after `build`.
mir: *const Mir,
/// Borrowed, as `mir` is.
lowered: *const Lowered,

/// Block count.
nb: u32 = 0,
/// Reverse-postorder number per block, `none_u32` if unreachable.
rpo_num: []u32 = &.{},
/// Reachable blocks in reverse postorder.
rpo: []u32 = &.{},
/// Immediate dominator per block, `none_u32` if unreachable.
idom: []u32 = &.{},
/// Reachable predecessors per block.
preds: [][]u32 = &.{},
/// Successors per block, in branch order.
succs: [][]u32 = &.{},
/// Dominator-tree children of block `b`, in RPO order:
/// `kid_pool[kid_off[b]..kid_off[b + 1]]` (`domKids`). One pool, not a slice
/// per block: every block has a parent but the entry, so the pool is exactly
/// `nb - 1` words.
kid_pool: []u32 = &.{},
kid_off: []u32 = &.{},
/// Euler-tour numbering of the dominator tree, so `dominates` is O(1)
/// instead of an idom walk (`none_u32` = block not in the tree).
dom_in: []u32 = &.{},
dom_out: []u32 = &.{},
/// Block has two or more predecessors. `[]bool` because every probe is one
/// block at a time and block counts are small.
is_merge: []bool = &.{},
/// Block is a loop header (it dominates one of its predecessors).
is_loop: []bool = &.{},
/// The outermost loop header whose natural loop contains this block, or
/// `none_u32`. Outermost, so a whole nest is one decision for the emitter.
loop_of: []u32 = &.{},
/// Every instruction of block `b`, in emission order:
/// `inst_pool[inst_off[b]..inst_off[b + 1]]`. A flat window so later walks
/// avoid chasing the MIR's intrusive `next` chain.
inst_pool: []Mir.Inst = &.{},
inst_off: []u32 = &.{},
/// Non-aliased phis of block `b`, in emission order:
/// `phi_pool[phi_off[b]..phi_off[b + 1]]`. The emitter reads it once per CFG
/// edge, where re-walking the chain would be quadratic in in-degree.
phi_pool: []Mir.Inst = &.{},
phi_off: []u32 = &.{},
/// Same shape, for the instructions a unit body can emit: everything except
/// phis, terminators, and values aliased away. Read once per block per unit.
stmt_pool: []Mir.Inst = &.{},
stmt_off: []u32 = &.{},
/// Merge-block dominator children of `b`: `mk_pool[mk_off[b]..mk_off[b+1]]`.
mk_pool: []u32 = &.{},
mk_off: []u32 = &.{},
/// MIR `op` column, hoisted once (borrowed from `mir`).
i_op: []const Mir.Opcode = &.{},
/// MIR `result` column, hoisted once (borrowed from `mir`).
i_res: []const Mir.Value = &.{},
/// Terminator per block, `.none` if the block has none.
term: []Mir.Inst = &.{},
/// Block a Value is defined in (`none_u32` for constants/params/probes).
def_block: []u32 = &.{},

/// Value count, sentinels included.
nv: u32 = 0,
/// Emitted type per Value.
vty: []VTy = &.{},
/// `mir.resolveAlias` evaluated once for every Value, so `rv` is one load and
/// readers never write through `resolveAlias`'s path compression.
/// Invariant: nothing calls `Mir.setAlias` after `build`/`buildStructure`.
alias: []Mir.Value = &.{},

/// Per Value: which unknowns its derivative can be nonzero in. Bit `u` set
/// means `∂value/∂x[u]` may be nonzero; no bit at all is `dFree`. This is the
/// structural Jacobian: a clear column is a stamp the host can drop at compile
/// time. Sound in one direction: a set bit is always safe, so every rule
/// over-approximates. When an unknown index reaches 64 the table folds
/// (`deps_folded`): unknown `u` sets bit `u & 63`, so `dFree` stays exact,
/// and `unknownDeps` answers all bits.
deps: []u64 = &.{},
/// Some unknown index is ≥ 64; see `deps`.
deps_folded: bool = false,
/// `deps` with a `dstop` passing its operand's bits through: which unknowns
/// the value can vary with (`xDep`). The same slice as `deps` when the module
/// has no `dstop`.
xdeps: []u64 = &.{},
/// `xdeps` plus the per-instance values a value can vary with: a §5.10 held
/// variable, `$mfactor`, a `$prev`/charge path latch (`pointDep`). The same
/// slice as `xdeps` when the module reads none.
pdeps: []u64 = &.{},
/// Per Value: the unknowns whose derivative reaches it through an operator
/// whose small-signal response depends on frequency (`op.acDynamic`). A
/// subset of `deps`, and empty when the module calls no such operator.
acdyn: []u64 = &.{},
/// §3.2.2 per Value: the `Lowered.mem_arrays` row an array version belongs to
/// (an `anew`, a `store`, or a phi over them), `none_u32` for every scalar.
/// Its `vty` is the element type. Every version of one array is one storage.
arr_of: []u32 = &.{},
/// `foldConst`'s answer per Value: `[0]` sees a parameter as the host sets
/// it, `[1]` looks through it to its declared default.
folds: [2]FoldColumn = .{ .{}, .{} },

/// One `folds` column as two parallel arrays. A `?Const` is 24 bytes, all for
/// the string arm's slice, and nearly every fold is a number: `kind` says
/// which arm a Value folded to, `bits` holds an integer's or a real's bits,
/// or a string's index in `strs`. 9 bytes a Value instead of 24, in the
/// table with one row per Value that codegen keeps for the whole emit.
pub const FoldColumn = struct {
    kind: []Kind = &.{},
    bits: []u64 = &.{},
    strs: std.ArrayList([]const u8) = .empty,

    const Kind = enum(u8) { none, int, real, str };

    fn get(c: *const FoldColumn, v: Mir.Value) ?Const {
        const i = @backingInt(v);
        const b = c.bits[i];
        return switch (c.kind[i]) {
            .none => null,
            .int => .{ .int = @bitCast(b) },
            .real => .{ .real = @bitCast(b) },
            .str => .{ .str = c.strs.items[@intCast(b)] },
        };
    }

    fn set(c: *FoldColumn, arena: std.mem.Allocator, i: usize, x: Const) Error!void {
        switch (x) {
            .int => |n| {
                c.kind[i] = .int;
                c.bits[i] = @bitCast(n);
            },
            .real => |r| {
                c.kind[i] = .real;
                c.bits[i] = @bitCast(r);
            },
            .str => |t| {
                c.kind[i] = .str;
                c.bits[i] = c.strs.items.len;
                try c.strs.append(arena, t);
            },
        }
    }
};

/// Builds every table above. Tables are allocated in `arena` and borrow
/// `mir`/`lowered`, which must outlive the result and not change after.
pub fn build(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
) Error!Analysis {
    var self = try buildStructure(arena, mir, lowered);
    try self.buildValueTypes();
    try self.buildDeps();
    try self.buildFolds();
    return self;
}

/// Builds the structural half alone: alias snapshot, CFG, dominator tree,
/// natural loops, per-block pools. `vty`, `deps`, `arr_of` and `folds` stay
/// empty. For the prover, which runs before codegen's own `build` and needs
/// no value types; building them twice per compile measured slower. It adds
/// only `buildLiteralFolds` to identify provably untaken runtime-error paths.
pub fn buildStructure(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
) Error!Analysis {
    var self: Analysis = .{ .arena = arena, .mir = mir, .lowered = lowered };
    self.nv = @intCast(mir.defs.len + Mir.Value.first_dynamic);
    self.alias = try arena.alloc(Mir.Value, self.nv);
    for (self.alias, 0..) |*p, v| p.* = mir.resolveAlias(@fromBackingInt(@intCast(@as(u32, @intCast(v)))));
    try self.buildCfg();
    return self;
}

/// Returns the Value `v` aliases to (the snapshot of `Mir.resolveAlias`).
pub fn rv(self: *const Analysis, v: Mir.Value) Mir.Value {
    return self.alias[@backingInt(v)];
}

/// Returns block `b`'s dominator-tree children, in RPO order.
pub fn domKids(self: *const Analysis, b: u32) []const u32 {
    return self.kid_pool[self.kid_off[b]..self.kid_off[b + 1]];
}

/// Returns block `bi`'s instructions as a contiguous window (see `inst_pool`).
pub inline fn blockInstsFlat(self: *const Analysis, bi: u32) []const Mir.Inst {
    return self.inst_pool[self.inst_off[bi]..self.inst_off[bi + 1]];
}

// ---------------------------------------------------------------- CFG ----

fn buildCfg(self: *Analysis) Error!void {
    const a = self.arena;
    const nb = self.mir.blockCount();
    self.nb = nb;
    self.i_op = self.mir.insts.items(.op);
    self.i_res = self.mir.insts.items(.result);
    self.term = try a.alloc(Mir.Inst, nb);
    self.succs = try a.alloc([]u32, nb);
    self.preds = try a.alloc([]u32, nb);
    self.rpo_num = try a.alloc(u32, nb);
    self.idom = try a.alloc(u32, nb);
    self.is_merge = try a.alloc(bool, nb);
    self.is_loop = try a.alloc(bool, nb);
    self.loop_of = try a.alloc(u32, nb);
    @memset(self.rpo_num, none_u32);
    @memset(self.idom, none_u32);
    @memset(self.is_loop, false);
    @memset(self.loop_of, none_u32);

    // Flatten the intrusive `next` chain once (count, then fill, so the pool
    // never grows). Order is the chain order, which is emission order and
    // therefore load-bearing.
    self.inst_off = try a.alloc(u32, nb + 1);
    var n_insts: u32 = 0;
    for (0..nb) |bi| {
        self.inst_off[bi] = n_insts;
        var it = self.mir.blockInsts(@fromBackingInt(@intCast(@as(u32, @intCast(bi)))));
        while (it.next()) |_| n_insts += 1;
    }
    self.inst_off[nb] = n_insts;
    self.inst_pool = try a.alloc(Mir.Inst, n_insts);
    var ki: u32 = 0;
    for (0..nb) |bi| {
        var it = self.mir.blockInsts(@fromBackingInt(@intCast(@as(u32, @intCast(bi)))));
        while (it.next()) |inst| {
            self.inst_pool[ki] = inst;
            ki += 1;
        }
    }

    // Terminator + successors. A phi may sit anywhere in the chain (ssa.zig
    // mints them on demand), so the terminator is found by opcode, not by
    // position.
    var pred_count = try a.alloc(u32, nb);
    @memset(pred_count, 0);
    for (0..nb) |bi| {
        self.term[bi] = .none;
        var s: [2]u32 = undefined;
        var ns: usize = 0;
        for (self.blockInstsFlat(@intCast(bi))) |inst| switch (Mir.opClass(self.mir.instOp(inst))) {
            .branch => {
                const d = self.mir.instData(inst).branch;
                self.term[bi] = inst;
                s[0] = @backingInt(d.then_block);
                s[1] = @backingInt(d.else_block);
                ns = 2;
            },
            .jump => {
                self.term[bi] = inst;
                s[0] = @backingInt(self.mir.instData(inst).jump.target);
                ns = 1;
            },
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
        };
        self.succs[bi] = try a.dupe(u32, s[0..ns]);
    }

    // Reachability + postorder (iterative DFS, successor order = branch
    // order ⇒ deterministic).
    var post = try a.alloc(u32, nb);
    var n_post: u32 = 0;
    {
        var seen = try a.alloc(bool, nb);
        @memset(seen, false);
        const Frame = struct { b: u32, i: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(a);
        try stack.append(a, .{ .b = 0, .i = 0 });
        seen[0] = true;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.i < self.succs[top.b].len) {
                const s = self.succs[top.b][top.i];
                top.i += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    try stack.append(a, .{ .b = s, .i = 0 });
                }
            } else {
                post[n_post] = top.b;
                n_post += 1;
                _ = stack.pop();
            }
        }
    }
    for (post[0..n_post], 0..) |bi, i| self.rpo_num[bi] = n_post - 1 - @as(u32, @intCast(i));
    self.rpo = try a.alloc(u32, n_post);
    for (post[0..n_post], 0..) |bi, i| self.rpo[n_post - 1 - i] = bi;

    // Predecessors (reachable only).
    for (0..nb) |bi| {
        if (self.rpo_num[bi] == none_u32) continue;
        for (self.succs[bi]) |s| pred_count[s] += 1;
    }
    for (0..nb) |bi| self.preds[bi] = try a.alloc(u32, pred_count[bi]);
    @memset(pred_count, 0);
    for (self.rpo) |bi| {
        for (self.succs[bi]) |s| {
            self.preds[s][pred_count[s]] = bi;
            pred_count[s] += 1;
        }
    }
    for (0..nb) |bi| self.is_merge[bi] = self.preds[bi].len > 1;
    self.is_merge[0] = false; // entry is never re-entered

    // Cooper/Harvey/Kennedy iterative dominators over reverse postorder.
    self.idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (self.rpo[1..]) |bi| {
            var new: u32 = none_u32;
            for (self.preds[bi]) |p| {
                if (self.idom[p] == none_u32 and p != 0) continue;
                new = if (new == none_u32) p else self.intersect(new, p);
            }
            if (new != none_u32 and self.idom[bi] != new) {
                self.idom[bi] = new;
                changed = true;
            }
        }
    }

    // Dominator children, in RPO order (deterministic emission order):
    // counted, prefix-summed into `kid_off`, then filled.
    self.kid_off = try a.alloc(u32, nb + 1);
    @memset(self.kid_off, 0);
    for (self.rpo[1..]) |bi| self.kid_off[self.idom[bi] + 1] += 1;
    for (1..nb + 1) |bi| self.kid_off[bi] += self.kid_off[bi - 1];
    self.kid_pool = try a.alloc(u32, self.kid_off[nb]);
    const kid_fill = try a.dupe(u32, self.kid_off[0..nb]);
    for (self.rpo[1..]) |bi| {
        const p = self.idom[bi];
        self.kid_pool[kid_fill[p]] = bi;
        kid_fill[p] += 1;
    }

    // Merge-block dominator children, flattened in `domKids` order.
    self.mk_off = try a.alloc(u32, nb + 1);
    var n_mk: u32 = 0;
    for (0..nb) |bi| {
        self.mk_off[bi] = n_mk;
        for (self.domKids(@intCast(bi))) |k| {
            if (self.is_merge[k]) n_mk += 1;
        }
    }
    self.mk_off[nb] = n_mk;
    self.mk_pool = try a.alloc(u32, n_mk);
    var mk: u32 = 0;
    for (0..nb) |bi| {
        for (self.domKids(@intCast(bi))) |k| {
            if (self.is_merge[k]) {
                self.mk_pool[mk] = k;
                mk += 1;
            }
        }
    }

    // Euler tour of the dominator tree (explicit stack: large models nest
    // deeply enough to blow a recursive walk).
    self.dom_in = try a.alloc(u32, nb);
    self.dom_out = try a.alloc(u32, nb);
    @memset(self.dom_in, none_u32);
    @memset(self.dom_out, none_u32);
    const Frame = struct { node: u32, kid: u32 };
    const stack = try a.alloc(Frame, nb);
    var sp: usize = 1;
    var clock: u32 = 0;
    stack[0] = .{ .node = 0, .kid = 0 };
    self.dom_in[0] = clock;
    clock += 1;
    while (sp > 0) {
        const f = &stack[sp - 1];
        const kids = self.domKids(f.node);
        if (f.kid < kids.len) {
            const k = kids[f.kid];
            f.kid += 1;
            self.dom_in[k] = clock;
            clock += 1;
            stack[sp] = .{ .node = k, .kid = 0 };
            sp += 1;
        } else {
            self.dom_out[f.node] = clock;
            clock += 1;
            sp -= 1;
        }
    }

    // Per-block phi and statement pools, counted then filled (same two-pass
    // shape as `kid_pool`, so neither pool needs to grow).
    self.phi_off = try a.alloc(u32, nb + 1);
    self.stmt_off = try a.alloc(u32, nb + 1);
    var n_phis: u32 = 0;
    var n_stmts: u32 = 0;
    for (0..nb) |bi| {
        self.phi_off[bi] = n_phis;
        self.stmt_off[bi] = n_stmts;
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            if (self.livePhi(inst)) n_phis += 1;
            if (self.liveStmt(inst)) n_stmts += 1;
        }
    }
    self.phi_off[nb] = n_phis;
    self.stmt_off[nb] = n_stmts;
    self.phi_pool = try a.alloc(Mir.Inst, n_phis);
    self.stmt_pool = try a.alloc(Mir.Inst, n_stmts);
    var kp: u32 = 0;
    var ks: u32 = 0;
    for (0..nb) |bi| {
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            if (self.livePhi(inst)) {
                self.phi_pool[kp] = inst;
                kp += 1;
            }
            if (self.liveStmt(inst)) {
                self.stmt_pool[ks] = inst;
                ks += 1;
            }
        }
    }

    // A loop header dominates at least one of its predecessors (back edge).
    for (self.rpo) |bi| {
        for (self.preds[bi]) |p| {
            if (self.dominates(bi, p)) self.is_loop[bi] = true;
        }
    }

    // The NATURAL LOOP BODY of every header, for the §5.9 `loop_recompute`
    // fixpoint and for `edgeAct`'s `inLoop` guard. Standard construction:
    // walk predecessors backwards from each back edge, stopping at the
    // header; every block reached is inside that loop.
    //
    // Not "everything the header dominates": that also covers the region past
    // the loop's exit, so a model whose analog block opens with a `for` would
    // lose hoisting for its entire body.
    //
    // `rpo` visits an outer header before an inner one, and the first write
    // wins, so `loop_of` ends up naming the outermost nest. That is what
    // makes a nest one decision: re-materializing an inner loop needs the
    // outer loop's structure too, so they stand or fall together.
    var body: std.ArrayList(u32) = .empty;
    defer body.deinit(self.arena);
    for (self.rpo) |h| {
        if (!self.is_loop[h]) continue;
        if (self.loop_of[h] == none_u32) self.loop_of[h] = h;
        for (self.preds[h]) |p| {
            if (!self.dominates(h, p)) continue; // not a back edge
            if (self.loop_of[p] != none_u32 and p != h) continue;
            if (p != h) {
                self.loop_of[p] = self.loop_of[h];
                try body.append(self.arena, p);
            }
            while (body.pop()) |cur| {
                for (self.preds[cur]) |q| {
                    if (self.loop_of[q] != none_u32) continue;
                    self.loop_of[q] = self.loop_of[h];
                    try body.append(self.arena, q);
                }
            }
        }
    }
}

fn intersect(self: *const Analysis, x0: u32, y0: u32) u32 {
    var x = x0;
    var y = y0;
    while (x != y) {
        while (self.rpo_num[x] > self.rpo_num[y]) x = self.idom[x];
        while (self.rpo_num[y] > self.rpo_num[x]) y = self.idom[y];
    }
    return x;
}

/// Returns whether block `a` dominates block `x`. O(1) via the Euler-tour
/// interval. Unreachable blocks dominate only themselves.
pub fn dominates(self: *const Analysis, a: u32, x: u32) bool {
    const ia = self.dom_in[a];
    const ix = self.dom_in[x];
    if (ia == none_u32 or ix == none_u32) return a == x;
    return ia <= ix and self.dom_out[x] <= self.dom_out[a];
}

// -------------------------------------------------------------- values ----

fn buildValueTypes(self: *Analysis) Error!void {
    const a = self.arena;
    self.vty = try a.alloc(VTy, self.nv); // `nv` was set in `buildStructure`
    self.def_block = try a.alloc(u32, self.nv);
    @memset(self.def_block, none_u32);
    // No `vty` prefill: every arm of the base pass below assigns its index.

    for (0..self.nb) |bi| {
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            const r = self.mir.instResult(inst);
            if (r == .undef) continue;
            self.def_block[@backingInt(r)] = @intCast(bi);
        }
    }

    // Base pass: constants and opcodes decide themselves. Not a SIMD
    // candidate: most elements gather (`instOp`, `params`), and value counts
    // are small.
    try self.buildArrOf();
    var v: u32 = 0;
    while (v < self.nv) : (v += 1) {
        const val: Mir.Value = @fromBackingInt(@intCast(v));
        if (self.arr_of[v] != none_u32) {
            self.vty[v] = if (self.lowered.mem_arrays.items[self.arr_of[v]].ty == .integer) .int else .real;
            continue;
        }
        self.vty[v] = switch (self.mir.valueDef(val)) {
            .undef => .real,
            .float_const => .real,
            .int_const => .int,
            .str_const => .str,
            .param_ref => |p| tyOfParam(self.lowered.params.items[p].ty),
            .block_param => .real,
            .inst_result => |inst| blk: {
                const op = self.mir.instOp(inst);
                if (op == .call) break :blk Mir.callee.ty(self.mir.instData(inst).call.callee);
                if (op == .phi or op == .select) break :blk .real; // refined below
                break :blk if (Mir.opIsInteger(op)) .int else .real;
            },
        };
    }
    // Refine `select` and `phi` from their operands, to a fixpoint as
    // `buildDeps` does: SSA construction creates a chain of joins outer-first,
    // so the outer phi precedes its operand in value order and each sweep
    // settles one more link.
    //
    // Terminates: every refined value copies exactly one other value's type,
    // so the refined values form a functional graph. A chain settles one link
    // per sweep; a cycle (a loop-carried phi whose first operand leads back to
    // itself) is uniform after one sweep and then copies itself.
    var changed = true;
    while (changed) {
        changed = false;
        v = Mir.Value.first_dynamic;
        while (v < self.nv) : (v += 1) {
            const val: Mir.Value = @fromBackingInt(@intCast(v));
            const def = self.mir.valueDef(val);
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const src: Mir.Value = switch (Mir.opClass(self.mir.instOp(inst))) {
                .ternary => self.rv(self.mir.instData(inst).ternary.then_val), // `select`, the only ternary
                .phi => blk: {
                    const d = self.mir.instData(inst).phi;
                    if (d.count == 0) continue;
                    const first = self.rv(self.mir.phiPair(inst, 0).value);
                    if (first == .undef) continue;
                    break :blk first;
                },
                .unary, .binary, .branch, .jump, .call, .anew, .load, .store => continue,
            };
            const t = self.vty[@backingInt(src)];
            if (self.vty[v] == t) continue;
            self.vty[v] = t;
            changed = true;
        }
    }
}

/// Fill `arr_of`. An `anew` names its array and a `store` inherits its
/// operand's; a phi takes any operand's (lowering joins only versions of one
/// place, so they agree). A fixpoint because a loop phi reads a store defined
/// after it; marking only ever adds, so it converges.
fn buildArrOf(self: *Analysis) Error!void {
    self.arr_of = try self.arena.alloc(u32, self.nv);
    @memset(self.arr_of, none_u32);
    if (self.lowered.mem_arrays.items.len == 0) return;
    var grew = true;
    while (grew) {
        grew = false;
        for (Mir.Value.first_dynamic..self.nv) |i| {
            if (self.arr_of[i] != none_u32) continue;
            const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const id: u32 = switch (self.mir.instData(inst)) {
                .anew => |d| d.array,
                .store => |d| self.arr_of[@backingInt(self.rv(d.arr))],
                .phi => |d| blk: {
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1) {
                        const a = self.arr_of[@backingInt(self.rv(self.mir.phiPair(inst, k).value))];
                        if (a != none_u32) break :blk a;
                    }
                    break :blk none_u32;
                },
                .unary, .binary, .ternary, .branch, .jump, .call, .load => none_u32,
            };
            if (id == none_u32) continue;
            self.arr_of[i] = id;
            grew = true;
        }
    }
}

/// §3.2.2 the array a Value is a version of, or null for a scalar.
pub fn arrOf(self: *const Analysis, v: Mir.Value) ?u32 {
    const a = self.arr_of[@backingInt(self.rv(v))];
    return if (a == none_u32) null else a;
}

test "a chain of joins built outer-first types every phi from the integer at its root" {
    // Three nested `if`s, each join's first operand the join inside it,
    // created outer-first as SSA construction does: two sweeps are not enough.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var file: Ast.SourceFile = .empty;
    const lowered: Lowered = .{ .file = &file };
    var b: [4]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    for (0..3) |i| _ = try mir.emitJump(a, b[i], b[i + 1]);
    const p3 = try mir.emitPhi(a, b[3], &.{});
    const p2 = try mir.emitPhi(a, b[2], &.{});
    const p1 = try mir.emitPhi(a, b[1], &.{.{ .block = b[0], .value = .one }});
    try mir.setPhiPairs(a, mir.valueDef(p2).inst_result, &.{.{ .block = b[1], .value = p1 }});
    try mir.setPhiPairs(a, mir.valueDef(p3).inst_result, &.{.{ .block = b[2], .value = p2 }});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    for ([_]Mir.Value{ p1, p2, p3 }) |p| try std.testing.expectEqual(VTy.int, an.tyOf(p));
}

test "a dstop clears the derivative bits and keeps the value varying" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var file: Ast.SourceFile = .empty;
    const lowered: Lowered = .{ .file = &file };
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const stopped = try mir.emit(a, .entry, .dstop, &.{va});
    const prod = try mir.emit(a, .entry, .fmul, &.{ stopped, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(stopped) and an.xDep(stopped));
    // The product keeps its other operand's lane, and varies through both.
    try std.testing.expectEqual(@as(u64, 0b10), an.unknownDeps(prod));
    try std.testing.expectEqual(@as(u64, 0b11), an.xdeps[@backingInt(prod)]);
}

test "acdyn: an absdelay's input deps reach the value, a direct path does not" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var file: Ast.SourceFile = .empty;
    const lowered: Lowered = .{ .file = &file };
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const td = try mir.addFloatConst(a, 1e-9);
    const dly = try mir.emitCall(a, .entry, try mir.internString(a, "absdelay"), &.{ va, td });
    const sum = try mir.emit(a, .entry, .fadd, &.{ dly, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // x[0] reaches `sum` only through the delay, x[1] only directly.
    try std.testing.expectEqual(@as(u64, 0b11), an.unknownDeps(sum));
    try std.testing.expectEqual(@as(u64, 0b01), an.acDynDeps(sum));
    try std.testing.expectEqual(@as(u64, 0), an.acDynDeps(va));
}

/// Returns the emitted type of `v`. Requires `build`, not `buildStructure`.
pub fn tyOf(self: *const Analysis, v: Mir.Value) VTy {
    return self.vty[@backingInt(v)];
}

// -------------------------------------------------- the derivative lattice --

/// Fill `deps`: which unknowns, and so also whether any (`dFree`). See `deps`.
///
/// Everything starts at no bits and a bit spreads from the probes outwards,
/// so the fixpoint is monotone and cannot oscillate: the lattice only ever
/// gains bits, and it terminates in at most (longest chain) sweeps. Value
/// order is definition order except across a back edge, which is why this
/// iterates rather than sweeping once: a loop-carried phi needs the round
/// after its body.
fn buildDeps(self: *Analysis) Error!void {
    // An unknown index ≥ 64 folds (see `deps`). Detected before the fixpoint
    // so the loop below never has to think about it.
    var v0: u32 = 0;
    while (v0 < self.nv) : (v0 += 1) {
        const d = self.mir.valueDef(@fromBackingInt(@intCast(v0)));
        if (d == .block_param and d.block_param >= 64) self.deps_folded = true;
    }
    self.deps = try self.fixDeps(.deriv);
    // Only a `dstop` tells the two tables apart.
    self.xdeps = self.deps;
    for (0..self.mir.insts.len) |i| {
        if (self.mir.instOp(@fromBackingInt(@intCast(@as(u32, @intCast(i))))) != .dstop) continue;
        self.xdeps = try self.fixDeps(.value);
        break;
    }
    self.pdeps = self.xdeps;
    for (0..self.mir.insts.len) |i| {
        if (!readsInstance(self, @fromBackingInt(@intCast(@as(u32, @intCast(i)))))) continue;
        self.pdeps = try self.fixDeps(.point);
        break;
    }
    // After `deps`, which an operator's `acdyn` reads.
    for (0..self.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        if (self.mir.instOp(inst) != .call or !op_kind.acDynamic(Mir.callee.opKind(self.mir.instData(inst).call.callee))) continue;
        self.acdyn = try self.fixDeps(.ac_dyn);
        break;
    }
}

/// Which column `fixDeps` fills: `deps`, `xdeps`, `acdyn` or `pdeps`.
const DepCol = enum { deriv, value, ac_dyn, point };

/// Whether `inst` reads a per-instance value (`pdeps`' seeds).
fn readsInstance(self: *const Analysis, inst: Mir.Inst) bool {
    return switch (self.mir.instData(inst)) {
        .call => |c| c.callee == .@"$held_real" or c.callee == .@"$held_int" or c.callee == .@"$mfactor",
        .unary => |u| u.op == .path_prev or u.op == .path_acc,
        else => false, // else: only a call or a latch reads the instance as a value
    };
}

/// The lattice's fixpoint for column `which`.
fn fixDeps(self: *const Analysis, which: DepCol) Error![]u64 {
    const col = try self.arena.alloc(u64, self.nv);
    @memset(col, 0);
    var changed = true;
    while (changed) {
        changed = false;
        var v: u32 = 0;
        while (v < self.nv) : (v += 1) {
            const now = self.defDeps(@fromBackingInt(@intCast(v)), col, which);
            if (now == col[v]) continue;
            col[v] = now;
            changed = true;
        }
    }
    return col;
}

/// One step of the lattice: `val`'s bits given the current answer for its
/// operands in `col`. Every rule is "union of the operands whose derivative
/// the contract propagates". In `acdyn` a probe starts with no bits and a
/// frequency-dependent operator takes its input's whole `deps`, since every
/// derivative through it is scaled by its H(jω).
fn defDeps(self: *const Analysis, val: Mir.Value, col: []const u64, which: DepCol) u64 {
    switch (self.mir.valueDef(self.rv(val))) {
        // §4.4 access function: the probe is x[u], so its derivative is the
        // one unit vector.
        .block_param => |u| return if (which == .ac_dyn) 0 else @as(u64, 1) << @intCast(u & 63),
        .undef, .float_const, .int_const, .str_const, .param_ref => return 0,
        .inst_result => |inst| {
            switch (self.mir.instData(inst)) {
                .branch, .jump => return 0, // no result to speak of
                // A call inherits from its arguments and nothing else. That
                // holds for all of §4.5 (each operator propagates the
                // derivative of its argument) and for ch9, where a systf's
                // partials arrive through `SystfHost.call`. A call cannot read
                // a probe its arguments do not name: codegen spells a probe in
                // one place only (`renderValueRef`'s `block_param` arm).
                // Without this rule every `$temperature`-dependent parameter
                // would carry a derivative.
                .call => |c| {
                    if (which == .point and self.readsInstance(inst)) return 1;
                    if (which == .ac_dyn and op_kind.acDynamic(Mir.callee.opKind(c.callee)))
                        return if (c.args.len == 0) 0 else self.depsIn(self.deps, c.args[0]);
                    var acc: u64 = 0;
                    for (c.args) |arg| acc |= self.depsIn(col, arg);
                    return acc;
                },
                .unary => |u| {
                    if (which == .point and (u.op == .path_prev or u.op == .path_acc)) return 1 | self.depsIn(col, u.operand);
                    return if (which != .value and which != .point and u.op == .dstop) 0 else self.depsIn(col, u.operand);
                },
                .binary => |b| return self.depsIn(col, b.lhs) | self.depsIn(col, b.rhs),
                // §4.2.12: the condition does not matter. It selects between
                // arms rather than entering the value, so a conditional over
                // two constants is constant however x steers it, and `S.sel`
                // lets the taken arm's derivative ride through.
                .ternary => |t| return self.depsIn(col, t.then_val) | self.depsIn(col, t.else_val),
                // §3.2.2 an array version carries the union of what was stored
                // into it; a fresh one (zero, or the held `Instance` copy) is
                // constant. The index does not enter, for `select`'s reason:
                // it picks an element, and the picked element's derivative is
                // what rides through.
                .anew => return 0,
                .load => |l| return self.depsIn(col, l.arr),
                .store => |st| return self.depsIn(col, st.arr) | self.depsIn(col, st.value),
                .phi => |d| {
                    var acc: u64 = 0;
                    for (0..d.count) |k| acc |= self.depsIn(col, self.mir.phiPair(inst, @intCast(k)).value);
                    return acc;
                },
            }
        },
    }
}

/// Returns whether `v` is independent of every §4.4 probe, so its derivative
/// vanishes structurally (`deps[v] == 0`). Resolves the alias first.
/// Conservative: `false` is always sound. Worth knowing because
/// `@setFloatMode(.strict)` forbids folding a multiply by a literal zero, so a
/// dual holding `splat(0)` would pay full-width arithmetic at every use.
pub fn dFree(self: *const Analysis, v: Mir.Value) bool {
    return self.depsOf(v) == 0;
}

/// Returns whether `v`'s value varies with some §4.4 probe. `!dFree` except
/// past a `dstop`, whose value varies while its derivative is zero.
pub fn xDep(self: *const Analysis, v: Mir.Value) bool {
    return self.depsIn(self.xdeps, v) != 0;
}

/// Returns whether `v` can differ between two points of a batch that share
/// the `Model` row and the `SimState`: `xDep`, or it reads per-instance
/// state (a held variable, `$mfactor`, a path latch; contract.zig
/// `batch_inst`).
pub fn pointDep(self: *const Analysis, v: Mir.Value) bool {
    return self.depsIn(self.pdeps, v) != 0;
}

/// The raw word, folded or not: what the fixpoint and `dFree` read.
fn depsOf(self: *const Analysis, v: Mir.Value) u64 {
    return self.depsIn(self.deps, v);
}

fn depsIn(self: *const Analysis, col: []const u64, v: Mir.Value) u64 {
    return col[@backingInt(self.rv(v))];
}

/// Returns which unknowns `v`'s derivative can be nonzero in. All ones when
/// the table is folded (an unknown index ≥ 64), so consumers fall back to a
/// dense Jacobian without a second code path.
pub fn unknownDeps(self: *const Analysis, v: Mir.Value) u64 {
    if (self.deps_folded) return std.math.maxInt(u64);
    return self.depsOf(v);
}

/// Returns the unknowns whose derivative reaches `v` through a
/// frequency-dependent operator (`acdyn`), folded as `unknownDeps` is.
pub fn acDynDeps(self: *const Analysis, v: Mir.Value) u64 {
    if (self.acdyn.len == 0) return 0;
    if (self.deps_folded) return if (self.depsIn(self.acdyn, v) == 0) 0 else std.math.maxInt(u64);
    return self.depsIn(self.acdyn, v);
}

/// Returns whether `block` is inside some loop's natural body.
pub fn inLoop(self: *const Analysis, block: u32) bool {
    return self.loop_of[block] != none_u32;
}

/// A phi whose result survives aliasing: the `phi_pool` filter, CFG-wide.
fn livePhi(self: *const Analysis, inst: Mir.Inst) bool {
    if (self.i_op[@backingInt(inst)] != .phi) return false;
    const r = self.i_res[@backingInt(inst)];
    return self.rv(r) == r;
}

/// The `stmt_pool` filter: everything a unit body may emit as a statement.
/// Phis are block headers, terminators are `emitTerm`'s, and an aliased
/// result was rewritten away by ssa.zig.
fn liveStmt(self: *const Analysis, inst: Mir.Inst) bool {
    switch (Mir.opClass(self.i_op[@backingInt(inst)])) {
        .phi, .branch, .jump => return false,
        .unary, .binary, .ternary, .call, .anew, .load, .store => {},
    }
    const r = self.i_res[@backingInt(inst)];
    return r != .undef and self.rv(r) == r;
}

/// Returns the phi `inst`'s incoming value on the edge from block `from`, or
/// `.undef` if it has none.
pub fn phiIn(self: *const Analysis, inst: Mir.Inst, from: u32) Mir.Value {
    const d = self.mir.instData(inst).phi;
    var i: u32 = 0;
    while (i < d.count) : (i += 1) {
        const p = self.mir.phiPair(inst, i);
        if (@backingInt(p.block) == from) return p.value;
    }
    return .undef;
}

// ---------------------------------------------------------------------------
// The VTy lattice: a Value's type is a property of the MIR, so both the
// analysis that fills `vty` and the emitter that reads it use these.
// ---------------------------------------------------------------------------

/// Returns the emitted type of a §3.4 parameter declared with type `t`.
pub fn tyOfParam(t: Ast.Type) VTy {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .int,
        .string => .str,
    };
}

// ---------------------------------------------------------------------------
// Constant folding: a property of the MIR, so it lives with the facts. Both
// the emitter (parameter defaults, §4.5 operator control arguments) and the
// per-unit planner fold through this.
// ---------------------------------------------------------------------------

/// A folded constant, as a real.
pub const Folded = struct { f: f64 };

/// Returns `v` as a §4.2 constant expression, or null. Used for parameter
/// defaults (`parameter real b = a*2;`, §6.3.4) and §4.5 operator control
/// arguments; anything touching an unknown or a call is not constant.
/// `resolve_params` looks through a parameter to its declared default, which
/// only a Model default may do. O(1): a load from `folds`. Requires `build`.
pub fn foldConst(self: *const Analysis, v: Mir.Value, resolve_params: bool) ?Folded {
    const c = self.folds[@intFromBool(resolve_params)].get(v) orelse return null;
    return .{ .f = c.asReal() };
}

fn buildFolds(self: *Analysis) Error!void {
    for (&self.folds, [_]bool{ false, true }) |*col, resolve_params| {
        col.* = try self.buildFoldColumn(resolve_params);
    }
}

/// Literal-only folds after `buildStructure`: runtime branch truth may not
/// inspect a parameter's overridable default (§4.2.3/§6.3.4). The prover
/// needs this column but none of the derivative/type tables in `build`.
pub fn buildLiteralFolds(self: *Analysis) Error!void {
    self.folds[0] = try self.buildFoldColumn(false);
}

fn buildFoldColumn(self: *Analysis, resolve_params: bool) Error!FoldColumn {
    var col: FoldColumn = .{
        .kind = try self.arena.alloc(FoldColumn.Kind, self.nv),
        .bits = try self.arena.alloc(u64, self.nv),
    };
    @memset(col.kind, .none);
    @memset(col.bits, 0);
    // An answer only ever goes from null to a constant, so this terminates;
    // operands precede users except through aliases or forward defaults.
    var changed = true;
    while (changed) {
        changed = false;
        for (0..self.nv) |v| {
            if (col.kind[v] != .none) continue;
            const c = self.foldStep(@fromBackingInt(@intCast(@as(u32, @intCast(v)))), &col, resolve_params) orelse continue;
            try col.set(self.arena, v, c);
            changed = true;
        }
    }
    return col;
}

/// `v`'s fold given the current answers for its operands. The operators are
/// the one constant kernel's (`opcode.fold`); this only decides which values
/// are leaves.
fn foldStep(self: *const Analysis, v: Mir.Value, col: *const FoldColumn, resolve_params: bool) ?Const {
    const at = struct {
        fn f(c: *const FoldColumn, x: Mir.Value) ?Const {
            return c.get(x);
        }
    }.f;
    switch (self.mir.valueDef(self.rv(v))) {
        .float_const => |x| return .{ .real = x },
        .int_const => |x| return .{ .int = x },
        // Only a Model default may look through a parameter: everywhere
        // else the value is whatever the host overrode it with.
        .param_ref => |p| return if (resolve_params) at(col, self.lowered.params.items[p].default) else null,
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| return Mir.opcode.fold(u.op, &.{at(col, u.operand) orelse return null}),
            .binary => |bn| return Mir.opcode.fold(bn.op, &.{
                at(col, bn.lhs) orelse return null,
                at(col, bn.rhs) orelse return null,
            }),
            // §4.2.12 `?:`. Lazy, as the kernel's `fold` is: only the taken
            // arm has to be foldable, so `w > 0 ? 1/w : 0` folds for w = 0
            // instead of declining on a division it never performs.
            .ternary => |d| {
                const c = at(col, d.cond) orelse return null;
                return at(col, if (c.isTrue()) d.then_val else d.else_val);
            },
            // §9.15 a host-published `$simparam` under the same rule as
            // `.param_ref` above: only a Model default may look through it,
            // and what it sees is Table 9-27's declared value. That is what
            // `Model{}` means to a host that writes nothing; every other
            // reader gets `model.<field>` (codegen's `f64Const`), so the
            // §3.4 field initializer and the §6.3.4 `derive()` assignment
            // split cleanly on `resolve_params`.
            .call => |d| {
                if (!resolve_params) return null;
                if (d.callee != .@"$simparam" or d.args.len == 0) return null;
                const arg = self.mir.valueDef(self.rv(d.args[0]));
                if (arg != .str_const) return null;
                if (Lower.simparamHostField(arg.str_const) == null) return null;
                return .{ .real = self.lowered.simparamValue(arg.str_const) orelse return null };
            },
            // §3.2.2 an array element is not a constant expression.
            .phi, .branch, .jump, .anew, .load, .store => return null,
        },
        .undef, .str_const, .block_param => return null,
    }
}
