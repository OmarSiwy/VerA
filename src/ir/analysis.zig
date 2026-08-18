//! Facts about a lowered module: the derived tables an emitter reads but does
//! not decide. Built once per compilation, then read-only.
//!
//! Transformation: Mir + Lower → CFG, dominator tree, natural loops, flattened
//! per-block instruction pools, hoisted instruction columns, and the value type
//! and alias tables.
//!
//! WHAT BELONGS HERE, and it is a sharper line than "does not write output":
//! everything in this file is true of the MIR regardless of what is emitted from
//! it. Nothing here knows that the target is Zig. That is what makes a second
//! backend — a netlist emitter reading the same MIR — a sibling file rather than
//! a rewrite, and it is why `ir/` does not import `backend/`.
//!
//! What deliberately did NOT come here, having looked:
//!   - `unit_names`, and `naming.Unit.target` with it. `enumerateUnits`
//!     sanitizes into ZIG identifiers (naming.zig `sanitizeInto`), so the unit
//!     list is already target-flavoured text, not a fact. `op_unit` indexes into
//!     it and follows it. The unit ENUMERATION ORDER *is* normative — proof's
//!     `Verdict.unit_modes` is indexed by it — so separating that order from the
//!     sanitized strings is the follow-up if a second backend ever needs it.
//!   - `lo_idx`/`lo_vals` and `planCommon`. Deduplicating unit targets into one
//!     declaration that returns a struct of them is a Zig code-shape decision;
//!     a netlist has no core struct.
//!   - the per-unit tables (`needed`, `eager_use`, `slot`, `loop_recompute`, …).
//!     Those are one emitter's scheduling policy, they are refilled per unit, and
//!     they carry deliberate cross-unit residue. They stay with the emitter.
//!
//! Two builders here used to allocate that per-unit scratch as a side job,
//! because they happened to know `nv` and `nb`: `buildValueTypes` — a typing pass
//! — allocated eight unrelated tables. Those allocations moved to the emitter,
//! which is where they are read.
//!
//! DOD: same ground rules as the rest of the engine. SoA, `enum(u32)` handles,
//! arena-owned, two-pass count-then-fill for every pool so nothing regrows.

const std = @import("std");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const Ast = @import("../frontend/ast.zig");
const assert = std.debug.assert;

/// File-as-struct: `@import("analysis.zig")` is both the namespace and the type.
pub const Analysis = @This();

pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

/// How a Value is emitted: as the generic scalar `S` (real) or as a plain `i64`
/// (LRM §3.2 integer). §4.2.1.1/§4.2.1.2 conversions are inserted at the use
/// site, so a typing miss degrades to a redundant cast, never to code that does
/// not compile.
pub const VTy = enum(u8) { real, int, str };

arena: std.mem.Allocator,
mir: *const Mir,
lower: *const Lower,

nb: u32 = 0,
rpo_num: []u32 = &.{},
rpo: []u32 = &.{},
idom: []u32 = &.{},
preds: [][]u32 = &.{},
succs: [][]u32 = &.{},
dom_kids: [][]u32 = &.{},
/// Euler-tour numbering of the dominator tree, so `dominates` is O(1)
/// instead of an idom walk (`none_u32` = block not in the tree).
dom_in: []u32 = &.{},
dom_out: []u32 = &.{},
is_merge: []bool = &.{},
is_loop: []bool = &.{},
/// The OUTERMOST loop header whose natural loop contains this block, or
/// `none_u32`. Outermost, not innermost, so a whole nest is one unit of
/// decision in `planCommon` — see `loop_blocked`.
loop_of: []u32 = &.{},
/// EVERY instruction of block `b`, in emission order:
/// `inst_pool[inst_off[b]..inst_off[b + 1]]`. `prepare` used to walk the
/// MIR's intrusive `next` chain six separate times (terminators, phi/stmt
/// count, phi/stmt fill, `def_block`, `op_unit`, `$param_given`), and each
/// `it.next()` is a dependent load — six latency-bound traversals of the
/// whole model. AIR never has a chain at all: a block body is a `[]u32`
/// window reinterpreted in place. Built by two walks, read by five.
inst_pool: []Mir.Inst = &.{},
inst_off: []u32 = &.{},
/// Non-aliased phis of block `b`, in emission order:
/// `phi_pool[phi_off[b]..phi_off[b + 1]]`. `emitPhiCopies` runs once per CFG
/// edge, so re-walking the block's instruction chain there is quadratic in
/// the block's in-degree. Flat pool + offsets, not `[][]Inst`: one
/// allocation, 4 bytes per phi, nothing derivable stored.
phi_pool: []Mir.Inst = &.{},
phi_off: []u32 = &.{},
/// Same shape, for the instructions a unit body can emit: everything except
/// phis, terminators, and values aliased away. `emitBlockInsts` runs once
/// per block PER UNIT, and the MIR's intrusive `next` chain makes that a
/// pointer chase over the whole model each time.
stmt_pool: []Mir.Inst = &.{},
stmt_off: []u32 = &.{},
/// Merge-block dominator children of `b`: `mk_pool[mk_off[b]..mk_off[b+1]]`.
/// `emitCode` runs per block per unit and used to rebuild this list into a
/// fresh arena allocation every time; the CFG does not change between units.
mk_pool: []u32 = &.{},
mk_off: []u32 = &.{},
/// MIR instruction columns, hoisted once. `mir.instOp`/`instResult` each
/// re-derive the MultiArrayList base pointers per call.
i_op: []const Mir.Opcode = &.{},
i_res: []const Mir.Value = &.{},
term: []Mir.Inst = &.{},
/// Block a Value is defined in (`none_u32` for constants/params/probes).
def_block: []u32 = &.{},

nv: u32 = 0,
vty: []VTy = &.{},
/// `mir.resolveAlias` evaluated once for every Value. `rv` is on the render
/// path of every unit (`renderVal`, `renderOp`, `livePhi`, `liveStmt`,
/// `mark`, `emitUnits`), and `resolveAlias` is declared `*const` but WRITES:
/// it path-compresses through the slice. Reading a snapshot instead makes
/// `rv` one array load and makes the whole render path genuinely read-only,
/// which is what per-unit parallelism will need. Costs `nv * 4` bytes.
///
/// INVARIANT: nothing calls `Mir.setAlias` after `prepare`. Its only caller
/// is `ssa.tryRemoveTrivialPhi`, which runs inside lowering — codegen and
/// proof are read-only passes over a finished Mir.
alias: []Mir.Value = &.{},

/// Everything above, in dependency order. `nv` first: `buildCfg`'s phi/stmt
/// filters already call `rv`, and `nv` derives only from `mir.defs.len`.
pub fn build(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
) Error!Analysis {
    var self = try buildStructure(arena, mir, lower);
    try self.buildValueTypes();
    return self;
}

/// The structural half alone: alias snapshot, CFG, dominator tree, natural
/// loops, per-block pools. Everything `vty` and the hoisted value columns are
/// NOT.
///
/// A second constructor rather than a flag, because it has a second caller with
/// a different need: `proof.zig` runs at root.zig's stage 5, BEFORE codegen
/// builds its own `Analysis` at stage 6, so it cannot share one — and a prover
/// has no use for "how would this Value be spelled in the emitted struct".
/// MEASURED with `zig build bench`, `contrib n=4096` lint phase, min of 25:
/// 111.7 ms before the share, 117.1 ms if proof calls the full `build` (+4.8%,
/// all of it `buildValueTypes` running twice per compile), 110.8 ms through
/// this entry point.
pub fn buildStructure(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
) Error!Analysis {
    var self: Analysis = .{ .arena = arena, .mir = mir, .lower = lower };
    self.nv = @intCast(mir.defs.len + Mir.Value.first_dynamic);
    try self.buildAlias();
    try self.buildCfg();
    return self;
}

/// Snapshot the whole alias forest, root-first, so `rv` never touches the
/// Mir again. Values below `first_dynamic` are their own root by definition.
fn buildAlias(self: *Analysis) Error!void {
    self.alias = try self.arena.alloc(Mir.Value, self.nv);
    for (self.alias, 0..) |*p, v| p.* = self.mir.resolveAlias(@enumFromInt(@as(u32, @intCast(v))));
}

pub fn rv(self: *const Analysis, v: Mir.Value) Mir.Value {
    return self.alias[@intFromEnum(v)];
}

/// Block `bi`'s instructions as a contiguous window — see `inst_pool`.
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
    @memset(self.is_merge, false);
    @memset(self.is_loop, false);
    @memset(self.loop_of, none_u32);

    // Flatten the intrusive `next` chain ONCE (count, then fill — the same
    // two-pass shape as `dom_kids`, so the pool never grows). Every later
    // walk in `prepare` reads `blockInstsFlat` instead. Order is the chain
    // order, which is emission order and therefore load-bearing.
    self.inst_off = try a.alloc(u32, nb + 1);
    var n_insts: u32 = 0;
    for (0..nb) |bi| {
        self.inst_off[bi] = n_insts;
        var it = self.mir.blockInsts(@enumFromInt(@as(u32, @intCast(bi))));
        while (it.next()) |_| n_insts += 1;
    }
    self.inst_off[nb] = n_insts;
    self.inst_pool = try a.alloc(Mir.Inst, n_insts);
    var ki: u32 = 0;
    for (0..nb) |bi| {
        var it = self.mir.blockInsts(@enumFromInt(@as(u32, @intCast(bi))));
        while (it.next()) |inst| {
            self.inst_pool[ki] = inst;
            ki += 1;
        }
    }

    // Terminator + successors. ssa.zig warns that a phi may sit ANYWHERE in
    // the chain (created on demand), so the terminator is found by opcode,
    // not by position.
    var pred_count = try a.alloc(u32, nb);
    @memset(pred_count, 0);
    for (0..nb) |bi| {
        self.term[bi] = .none;
        var s: [2]u32 = undefined;
        var ns: usize = 0;
        for (self.blockInstsFlat(@intCast(bi))) |inst| switch (self.mir.instOp(inst)) {
            .branch => {
                const d = self.mir.instData(inst).branch;
                self.term[bi] = inst;
                s[0] = @intFromEnum(d.then_block);
                s[1] = @intFromEnum(d.else_block);
                ns = 2;
            },
            .jump => {
                self.term[bi] = inst;
                s[0] = @intFromEnum(self.mir.instData(inst).jump.target);
                ns = 1;
            },
            else => {},
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
    // SIMD TRIAGE — REJECTED on N, and the margin is three orders of magnitude.
    // MEASURED over the 745 fixtures that compile: median `mir.blocks.len` is
    // 1, p75 1, p90 7, p99 25, max 103. `preds` is a slice-of-slices, so the
    // `.len` fields are not even contiguous; making them so would buy a loop
    // whose median trip count is one.
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

    // Dominator children, in RPO order (deterministic emission order).
    var kid_count = try a.alloc(u32, nb);
    @memset(kid_count, 0);
    for (self.rpo[1..]) |bi| kid_count[self.idom[bi]] += 1;
    self.dom_kids = try a.alloc([]u32, nb);
    for (0..nb) |bi| self.dom_kids[bi] = try a.alloc(u32, kid_count[bi]);
    @memset(kid_count, 0);
    for (self.rpo[1..]) |bi| {
        const p = self.idom[bi];
        self.dom_kids[p][kid_count[p]] = bi;
        kid_count[p] += 1;
    }

    // Merge-block dominator children, flattened in the same order the
    // per-unit rebuild produced.
    self.mk_off = try a.alloc(u32, nb + 1);
    var n_mk: u32 = 0;
    for (0..nb) |bi| {
        self.mk_off[bi] = n_mk;
        for (self.dom_kids[bi]) |k| {
            if (self.is_merge[k]) n_mk += 1;
        }
    }
    self.mk_off[nb] = n_mk;
    self.mk_pool = try a.alloc(u32, n_mk);
    var mk: u32 = 0;
    for (0..nb) |bi| {
        for (self.dom_kids[bi]) |k| {
            if (self.is_merge[k]) {
                self.mk_pool[mk] = k;
                mk += 1;
            }
        }
    }

    // Euler tour of the dominator tree (explicit stack: 600 K-line models
    // nest deeply enough to blow a recursive walk).
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
        const kids = self.dom_kids[f.node];
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
    // shape as `dom_kids`, so neither pool needs to grow).
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
    // NOT "everything the header dominates": that also covers the region
    // past the loop's exit, so a model whose analog block opens with a `for`
    // would lose hoisting for its entire body — which is the 182 MB output
    // the shared core exists to prevent.
    //
    // `rpo` visits an outer header before an inner one, and the first write
    // wins, so `loop_of` ends up naming the OUTERMOST nest. That is what
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

/// `a` dominates `x` iff `x` sits inside `a`'s Euler-tour interval. Blocks
/// outside the dominator tree (unreachable) dominate only themselves.
pub fn dominates(self: *const Analysis, a: u32, x: u32) bool {
    const ia = self.dom_in[a];
    const ix = self.dom_in[x];
    if (ia == none_u32 or ix == none_u32) return a == x;
    return ia <= ix and self.dom_out[x] <= self.dom_out[a];
}

// -------------------------------------------------------------- values ----

fn buildValueTypes(self: *Analysis) Error!void {
    const a = self.arena;
    self.vty = try a.alloc(VTy, self.nv); // `nv` was set in `prepare`
    self.def_block = try a.alloc(u32, self.nv);
    @memset(self.def_block, none_u32);
    // No `vty` prefill: the base pass below assigns EVERY index in `0..nv`
    // unconditionally (every arm of its switch yields a value, and `vty.len ==
    // nv`), so a `.real` prefill was a second full pass writing bytes nothing
    // ever read. See this wave's SIMD triage note above the base pass.

    for (0..self.nb) |bi| {
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            const r = self.mir.instResult(inst);
            if (r == .undef) continue;
            self.def_block[@intFromEnum(r)] = @intCast(bi);
        }
    }

    // Base pass: constants and opcodes decide themselves.
    //
    // SIMD TRIAGE — REJECTED, and here is the measurement so it is not re-asked.
    // It looks like a lane op (`DefKind` u8 in, `VTy` u8 out, no cross-element
    // dependency), but it is not one, for two independent reasons:
    //   - ELEMENT MIX. MEASURED over the 745 fixtures that compile: of 27,924
    //     values, 69.3% are `inst_result` and 2.2% are `param_ref` — the two
    //     arms that gather (`instOp`/`callTy`, `lower.params.items[p].ty`).
    //     Only 28.5% of lanes are the pure kind→VTy map, so 5 in 7 elements
    //     need a scalar fix-up whatever the load looks like.
    //   - N. MEASURED: median `mir.defs.len` is 26 (nv 38), p99 198, max 917.
    //     `suggestVectorLength(u8)` is 32 here, so the median fixture is one
    //     partial vector. The skill's floor is a few hundred elements.
    // Cost, MEASURED with callgrind over the same corpus (lint + codegen,
    // ReleaseFast): this whole function is ~0.04% of pipeline instructions;
    // analysis.zig + proof.zig + mir.zig together are 1.08%.
    var v: u32 = 0;
    while (v < self.nv) : (v += 1) {
        const val: Mir.Value = @enumFromInt(v);
        self.vty[v] = switch (self.mir.valueDef(val)) {
            .undef => .real,
            .float_const => .real,
            .int_const => .int,
            .str_const => .str,
            .param_ref => |p| tyOfParam(self.lower.params.items[p].ty),
            .block_param => .real,
            .inst_result => |inst| blk: {
                const op = self.mir.instOp(inst);
                if (op == .call) break :blk callTy(self.mir.instData(inst).call.name);
                if (op == .phi or op == .select) break :blk .real; // refined below
                break :blk if (Mir.opIsInteger(op)) .int else .real;
            },
        };
    }
    // Refine `select` and `phi` from their operands. Two sweeps in value
    // order settle every acyclic chain; a loop-carried phi keeps `.real`,
    // and a wrong guess only costs a redundant §4.2.1 conversion.
    var round: u32 = 0;
    while (round < 2) : (round += 1) {
        v = Mir.Value.first_dynamic;
        while (v < self.nv) : (v += 1) {
            const val: Mir.Value = @enumFromInt(v);
            const def = self.mir.valueDef(val);
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            switch (self.mir.instOp(inst)) {
                .select => {
                    const d = self.mir.instData(inst).ternary;
                    self.vty[v] = self.vty[@intFromEnum(self.rv(d.then_val))];
                },
                .phi => {
                    const d = self.mir.instData(inst).phi;
                    if (d.count == 0) continue;
                    const first = self.rv(self.mir.phiPair(inst, 0).value);
                    if (first == .undef) continue;
                    self.vty[v] = self.vty[@intFromEnum(first)];
                },
                else => {},
            }
        }
    }
}

pub fn tyOf(self: *const Analysis, v: Mir.Value) VTy {
    return self.vty[@intFromEnum(v)];
}

/// Is this block inside some loop's natural body?
pub fn inLoop(self: *const Analysis, block: u32) bool {
    return self.loop_of[block] != none_u32;
}

/// A phi whose result survives aliasing — the `phi_pool` filter, CFG-wide.
pub fn livePhi(self: *const Analysis, inst: Mir.Inst) bool {
    if (self.i_op[@intFromEnum(inst)] != .phi) return false;
    const r = self.i_res[@intFromEnum(inst)];
    return self.rv(r) == r;
}

/// The `stmt_pool` filter: everything a unit body may emit as a statement.
/// Phis are block headers, terminators are `emitTerm`'s, and an aliased
/// result was rewritten away by ssa.zig.
pub fn liveStmt(self: *const Analysis, inst: Mir.Inst) bool {
    switch (self.i_op[@intFromEnum(inst)]) {
        .phi, .branch, .jump => return false,
        else => {},
    }
    const r = self.i_res[@intFromEnum(inst)];
    return r != .undef and self.rv(r) == r;
}

pub fn phiIn(self: *const Analysis, inst: Mir.Inst, from: u32) Mir.Value {
    const d = self.mir.instData(inst).phi;
    var i: u32 = 0;
    while (i < d.count) : (i += 1) {
        const p = self.mir.phiPair(inst, i);
        if (@intFromEnum(p.block) == from) return p.value;
    }
    return .undef;
}

// ---------------------------------------------------------------------------
// The VTy lattice — a Value's type is a property of the MIR, so both the
// analysis that fills `vty` and the emitter that reads it use these.
// ---------------------------------------------------------------------------

pub fn tyOfParam(t: Ast.Type) VTy {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .int,
        .string => .str,
    };
}

/// ch9 return types — mirrors `Lower.sysFuncTy` (§9.11/§9.12/§9.19/§9.22).
/// Everything else, including every §4.5 operator and §4.6 event, is real:
/// lowering compares an event guard against `0.0`, so it must stay real.
/// MUST agree with `Lower.sysFuncTy`: the two type the same call from opposite
/// sides of the MIR, and a disagreement puts an `S` expression in an `i64` slot,
/// which does not compile.
///
/// §9.11 Table 9-8: `$realtobits` yields the bit PATTERN (an integer),
/// `$bitstoreal` yields the real that pattern stands for. Only the first belongs
/// here — see tests/fixtures/exhaustive/122_bit_conversions.va.
pub fn callTy(name: []const u8) VTy {
    const ints = [_][]const u8{
        "$param_given",          "$port_connected",
        "$test$plusargs",        "$value$plusargs",
        "$rtoi",                 "$clog2",
        "$realtobits",
        // The §9.22/§9.23 driver access family is absent, matching
        // `Lower.sysFuncTy`: §9.22 paragraph 3 confines those calls to connect
        // modules, so lowering refuses every one (E0818) and no `call` with such
        // a name reaches this analysis to be typed.
        // §9.5.4.2 `Lower.lowerScan`'s synthetic names: the item count, and the
        // item flavour chosen for an `integer` destination.
        "$sscanf",               "$sscanf$int",
        // §9.20 "The return value for both system functions shall be one (1) ...
        // and zero (0) otherwise" — a status, not a measurement.
        "$analog_node_alias",    "$analog_port_alias",
        // §9.5.1–§9.5.8 the descriptor family, plus `lowerFileRead`'s synthetic
        // item name. Every one integer-valued; see `Lower.sysFuncTy`.
        "$fopen",                "$fgets",
        "$fscanf",               "$fscanf$int",
        "$ftell",                "$fseek",
        "$rewind",               "$ferror",
        "$feof",
    };
    for (ints) |i| if (std.mem.eql(u8, name, i)) return .int;
    if (std.mem.eql(u8, name, "$simparam$str")) return .str;
    // §9.5.3 the formatted text, §9.5.4.2 the item whose destination is a string.
    if (std.mem.eql(u8, name, "$sformat") or std.mem.eql(u8, name, "$sscanf$str")) return .str;
    // §9.5.4.1's string, §9.5.4.2's file-sourced string item, §9.5.7's description.
    if (std.mem.eql(u8, name, "$fgets$str") or std.mem.eql(u8, name, "$fscanf$str") or
        std.mem.eql(u8, name, "$ferror$str")) return .str;
    // §5.10 `Lower.holdSlot`'s synthetic seed. Not a ch9 task and not in
    // `Lower.sysFuncTy`: the callee is chosen by the variable's declared type,
    // so the name IS the type and the two sides agree by construction.
    if (std.mem.eql(u8, name, "$held_int")) return .int;
    return .real;
}

// ---------------------------------------------------------------------------
// Constant folding — a property of the MIR, so it lives with the facts. Both
// the emitter (parameter defaults, §4.5 operator control arguments) and the
// per-unit planner fold through this.
// ---------------------------------------------------------------------------

pub const Folded = struct { f: f64 };

/// A folded INTEGER back in its own type, so §3.2's width can be applied to it.
/// Exact by construction: an integer only ever enters the f64 carrier from an
/// `int_const` or from `@floatFromInt` of a wrapped result, so it is whole.
fn asI64(x: Folded) i64 {
    return @intFromFloat(@round(x.f));
}

/// §4.2 constant expression folding over MIR, used for parameter defaults
/// (`parameter real b = a*2;` — §6.3.4) and for §4.5 operator control
/// arguments. Anything touching an unknown or a call is not constant.
pub fn foldConst(self: *const Analysis, v0: Mir.Value, depth: u32, resolve_params: bool) ?Folded {
    if (depth > 32) return null;
    const v = self.rv(v0);
    switch (self.mir.valueDef(v)) {
        .float_const => |x| return .{ .f = x },
        .int_const => |x| return .{ .f = @floatFromInt(x) },
        // Only a Model DEFAULT may look through a parameter: everywhere
        // else the value is whatever the host overrode it with.
        .param_ref => |p| return if (resolve_params)
            self.foldConst(self.lower.params.items[p].default, depth + 1, true)
        else
            null,
        .inst_result => |inst| {
            const row = self.mir.instRow(inst);
            switch (Mir.opClass(row.op)) {
                .unary => {
                    const a = self.foldConst(@enumFromInt(row.a), depth + 1, resolve_params) orelse return null;
                    return switch (row.op) {
                        .fneg => .{ .f = -a.f },
                        .fabs => .{ .f = @abs(a.f) },
                        // -(-2^31) and |-2^31| are the same §3.2 wrap: both
                        // answer -2^31, which is `codegen`'s `.ineg`/`zIabs`.
                        .ineg => .{ .f = @floatFromInt(Lower.wrap32(-%asI64(a))) },
                        .iabs => .{ .f = @floatFromInt(Lower.wrap32(if (asI64(a) < 0) -%asI64(a) else asI64(a))) },
                        .sqrt => .{ .f = @sqrt(a.f) },
                        .exp => .{ .f = @exp(a.f) },
                        .ln => .{ .f = @log(a.f) },
                        .log10 => .{ .f = @log10(a.f) },
                        .floor => .{ .f = @floor(a.f) },
                        .ceil => .{ .f = @ceil(a.f) },
                        .fi_cast => .{ .f = @round(a.f) },
                        .if_cast, .opt_barrier => .{ .f = a.f },
                        // §4.2.8/§4.2.9 — the two integer-valued unary forms
                        // `Lower.foldExpr`'s `.unary` arm already folds. Truth is
                        // "not zero" (§4.2.8), and `~` is the 32-bit complement
                        // §3.2's width defines.
                        .lognot => .{ .f = @floatFromInt(@intFromBool(a.f == 0)) },
                        .bitnot => .{ .f = @floatFromInt(Lower.wrap32(~asI64(a))) },
                        else => null,
                    };
                },
                .binary => {
                    const a = self.foldConst(@enumFromInt(row.a), depth + 1, resolve_params) orelse return null;
                    const b2 = self.foldConst(@enumFromInt(row.b), depth + 1, resolve_params) orelse return null;
                    return switch (row.op) {
                        // §3.2's 32-bit 2's complement result — `Lower.wrap32`
                        // is the definition, and this fold has to agree with
                        // `codegen.intBin32` or the same expression answers
                        // differently in a parameter default than at runtime.
                        // The i64 round trip is not decoration: the product of
                        // two i32s reaches 2^62, which an f64 carrier cannot
                        // hold exactly, so the wrap has to happen in the integer
                        // type and only the wrapped result comes back to f64.
                        .iadd => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) +% asI64(b2))) },
                        .isub => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) -% asI64(b2))) },
                        .imul => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) *% asI64(b2))) },
                        .fadd => .{ .f = a.f + b2.f },
                        .fsub => .{ .f = a.f - b2.f },
                        .fmul => .{ .f = a.f * b2.f },
                        .fdiv => .{ .f = a.f / b2.f },
                        .idiv => if (asI64(b2) == 0)
                            null
                        else
                            .{ .f = @floatFromInt(Lower.wrap32(@divTrunc(asI64(a), asI64(b2)))) },
                        .pow => .{ .f = std.math.pow(f64, a.f, b2.f) },
                        .fmin, .imin => .{ .f = @min(a.f, b2.f) },
                        .fmax, .imax => .{ .f = @max(a.f, b2.f) },
                        // §4.2.4 remainder. No wrap: a remainder is never wider
                        // than its operands. A zero divisor has no value to fold
                        // to — proof.zig's E0601 is the diagnostic, this just
                        // declines.
                        .fmod => if (b2.f == 0) null else .{ .f = @rem(a.f, b2.f) },
                        .imod => if (asI64(b2) == 0) null else .{ .f = @floatFromInt(@rem(asI64(a), asI64(b2))) },
                        // §4.2.5/§4.2.7 relational and equality, §4.2.8 logical:
                        // integer 0/1. Both operand flavours compare in the f64
                        // carrier — a §3.2.1 integer is exact in it — so the `i`
                        // and `f` opcodes share an arm.
                        .flt, .ilt => .{ .f = @floatFromInt(@intFromBool(a.f < b2.f)) },
                        .fgt, .igt => .{ .f = @floatFromInt(@intFromBool(a.f > b2.f)) },
                        .fle, .ile => .{ .f = @floatFromInt(@intFromBool(a.f <= b2.f)) },
                        .fge, .ige => .{ .f = @floatFromInt(@intFromBool(a.f >= b2.f)) },
                        .feq, .ieq => .{ .f = @floatFromInt(@intFromBool(a.f == b2.f)) },
                        .fne, .ine => .{ .f = @floatFromInt(@intFromBool(a.f != b2.f)) },
                        .logand => .{ .f = @floatFromInt(@intFromBool(a.f != 0 and b2.f != 0)) },
                        .logor => .{ .f = @floatFromInt(@intFromBool(a.f != 0 or b2.f != 0)) },
                        // §4.2.9 bitwise, at §3.2's width.
                        .bitand => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) & asI64(b2))) },
                        .bitor => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) | asI64(b2))) },
                        .bitxor => .{ .f = @floatFromInt(Lower.wrap32(asI64(a) ^ asI64(b2))) },
                        .bitxnor => .{ .f = @floatFromInt(Lower.wrap32(~(asI64(a) ^ asI64(b2)))) },
                        // §4.2.11, and the rule is `Lower.foldBinary`'s verbatim:
                        // `<<` is §3.2's 32-bit truncation of an i64 shift, `>>`
                        // zero-fills over 32 bits (NOT an i64 arithmetic shift),
                        // and a shift count outside the carrier declines rather
                        // than answering.
                        .shl, .shr => blk: {
                            const sh = asI64(b2);
                            if (sh < 0 or sh > 63) break :blk null;
                            if (row.op == .shl) break :blk Folded{
                                .f = @floatFromInt(Lower.wrap32(asI64(a) << @as(u6, @intCast(sh)))),
                            };
                            if (sh > 31) break :blk Folded{ .f = 0 };
                            const lo: u32 = @bitCast(@as(i32, @truncate(asI64(a))));
                            break :blk Folded{ .f = @floatFromInt(lo >> @as(u5, @intCast(sh))) };
                        },
                        else => null,
                    };
                },
                // §4.2.12 `?:`. Lazy, as `Lower.foldExpr`'s ternary arm is: only
                // the taken arm has to be foldable, so `w > 0 ? 1/w : 0` folds
                // for w = 0 instead of declining on a division it never performs.
                .ternary => {
                    const d = self.mir.instData(inst).ternary;
                    const c = self.foldConst(d.cond, depth + 1, resolve_params) orelse return null;
                    const taken = if (c.f != 0) d.then_val else d.else_val;
                    return self.foldConst(taken, depth + 1, resolve_params);
                },
                else => return null,
            }
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Self-check
// ---------------------------------------------------------------------------

// `callTy` and `Lower.sysFuncTy` type the same ch9 call from opposite sides of
// the MIR, and both say MUST AGREE in prose. Prose is not checkable, and the
// two rows this test was written for — §9.20's `$analog_node_alias` and
// `$analog_port_alias` — sat disagreeing long enough to cost a false E0322 on
// `status << 1` and an `i64` slot fed by an `S`. So: one list, both sides.
//
// The list is the UNION of every name either table types as something other
// than real, plus five reals as controls, because "both answer real" is the
// answer a typo also produces. `$held_int` is deliberately absent: §5.10
// `Lower.holdSlot` mints it, it is not a ch9 task, and `sysFuncTy` never sees
// it — `callTy`'s comment says so at the site.
test "callTy and Lower.sysFuncTy agree on every ch9 return type" {
    const names = [_][]const u8{
        // §9.19, §9.12, §9.11 Table 9-8
        "$param_given",     "$port_connected", "$test$plusargs", "$value$plusargs",
        "$rtoi",            "$clog2",          "$realtobits",
        // §9.20 the two alias status functions
        "$analog_node_alias",                  "$analog_port_alias",
        // §9.5 the descriptor family and the synthetic scan/read item names
        "$fopen",           "$fgets",          "$fscanf",        "$fscanf$int",
        "$ftell",           "$fseek",          "$rewind",        "$ferror",
        "$feof",            "$sscanf",         "$sscanf$int",
        // The string-valued rows
        "$simparam$str",    "$sformat",        "$sscanf$str",    "$fgets$str",
        "$fscanf$str",      "$ferror$str",
        // Controls: five that must stay real. `$bitstoreal` is the one with a
        // history — it is §9.11's inverse of `$realtobits` and yields the real
        // the pattern stands for, which both tables get right only because each
        // says so out loud.
        "$bitstoreal",      "$temperature",    "$abstime",       "$simparam",
        "$random",
    };
    for (names) |n| {
        const want: VTy = switch (Lower.sysFuncTy(n)) {
            .real => .real,
            .integer => .int,
            .string => .str,
        };
        std.testing.expectEqual(want, callTy(n)) catch |e| {
            std.debug.print("disagreement on {s}\n", .{n});
            return e;
        };
    }
}
