//! Hoisting: the hoisted core PREFIX (and `libmClass`, the libm-cost column).
//!
//! In: the shared core. Out: the prefix of its body that depends only on the
//! model card and temperature, latched once per instance. NOT a pure plan: the
//! region is found by a dry run of the emitter (`probeBody`), so it lives with
//! the emitter. The temperature hoist it complements is `plan/hoist.zig`.
//!
//! LRM clauses this file's code cites: §4.4, §4.6.4, §5.6.1.2, §9.19.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_hoist.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const plan_hoist = @import("plan/hoist.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const opcode_zig = @import("opcode_zig.zig");
const Mir = @import("ir").Mir;
const Analysis = @import("ir").Analysis;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const callArgIsValue = codegen.callArgIsValue;

pub fn libmClass(op: Mir.Opcode) bool {
    return opcode_zig.get(op).libm;
}

// ------------------------------------------ the hoisted core PREFIX ----
//
// `plan/hoist.zig` hoists a value by RE-SPELLING it in a flat
// `precompute` body, which is why `pcClass` refuses a phi: a value assigned
// inside an `if` is not one expression, and precompute has no control flow
// to put it back in. That refusal is expensive far beyond the phi itself —
// one unhoistable value strands everything downstream of it — and the
// guards it trips over are the SPICE idiom itself: `$param_given(nsub)`,
// `js > 0 && ad > 0 && as > 0`, `cbs > 0`, `rd > 0`, `lambda0 != 0`. On
// mos6 that left 15 solve-independent Duals inside the bias body.
//
// This is the other half, and it re-spells nothing. The core's emitted body
// opens with a PREFIX of top-level statements that reads no §4.4 probe and
// no per-step Instance state; `precompute` already calls the core once at
// x = 0 (cg_limit.emitPrep), so that prefix has already run there. Return
// its live-outs as extra core fields, latch them in `Instance.hp*`, and let
// every later evaluation jump the region:
//
//     if (inst.hp_ok == 0) { …the prefix, verbatim… }
//     else { h[3] = S.con(inst.hp[0]); … }
//
// Nothing about the arithmetic moves — the same statements run, in the same
// order, on the same inputs; they simply run once. That is why bit-identity
// is structural here and not a hope, and it is the same claim `pc__`
// already makes (`precompute` computes in `R`, the core reads `S.con` of
// the field). Storing an f64 per crossing value is exact for the same
// reason: a region with no `x[]` read builds every S through `S.con`, so
// every derivative lane in it is a zero this reload reproduces.
//
// Cost is one `Instance` f64 per crossing value plus one predictable
// branch. Measured on mos6 (`devices/mos6_inverter` biases): 1224.6 →
// 1164.2 Ir/eval, 0 mismatches over 546 880 values.

/// May the cached region hold `v`? Everything the region may read must be
/// fixed between `precompute` and the evaluations that skip it — so this is
/// `pcClass`'s whitelist (default DENY: an op or a `$name` neither knows is
/// impure) with two differences that only make sense for a text region.
///
/// A value that is already a STATEMENT stops the walk: it was emitted
/// earlier and asked this same question then. That is what admits the phi
/// `pcClass` has to refuse — a phi slot is written by `emitPhiCopies` on
/// the incoming edges, and those copies are checked as they are emitted.
/// It also means an impure CONDITION cannot smuggle a bias dependence in
/// through a pure-looking merge: the branch is an emitted value too, so the
/// region has already closed before its phi is reached.
///
/// Read-before-written (a loop-carried slot, or one the emitter never
/// assigns) is pure as well: that read takes the `undefined`/zero seed, and
/// the seed is emitted above the region.
pub fn hpPure(self: *Gen, v0: Mir.Value, depth: u32) bool {
    if (depth > 256) return false;
    const v = self.an.rv(v0);
    return switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => true,
        .block_param => false, // §4.4 probe: the solve itself
        // The MATERIALIZED shortcut belongs to operands only — asking it of
        // an instruction's own result would answer "yes, it has a slot" and
        // wave the instruction through unread.
        .inst_result => |inst| gen_render.materialized(self, v) or hpPureInst(self, inst, depth),
    };
}

/// The same question about an emitted STATEMENT: its opcode has to be one
/// the cache may hold, and every operand it renders inline has to be pure.
pub fn hpPureInst(self: *Gen, inst: Mir.Inst, depth: u32) bool {
    if (depth > 256) return false;
    const row = self.mir.instRow(inst);
    switch (row.op) {
        .call => {
            const d = self.mir.instData(inst).call;
            return plan_hoist.paramOnlyCall(self.input(), d);
        },
        // `path_prev`/`path_acc` read the §5.6.1.2 latches, which move on
        // every accepted step — the one class of Instance state that looks
        // parameter-only and is not.
        .phi, .branch, .jump, .path_prev, .path_acc => return false,
        .select => {
            const d = self.mir.instData(inst).ternary;
            return hpPure(self, d.cond, depth + 1) and
                hpPure(self, d.then_val, depth + 1) and
                hpPure(self, d.else_val, depth + 1);
        },
        else => return switch (Mir.opClass(row.op)) { // else: every other opcode is a pure op, decided by its operands
            .unary => hpPure(self, @enumFromInt(row.a), depth + 1),
            .binary => hpPure(self, @enumFromInt(row.a), depth + 1) and
                hpPure(self, @enumFromInt(row.b), depth + 1),
            .ternary, .phi, .branch, .jump, .call => false,
        },
    }
}

/// One emitted item's verdict. Once dirty, dirty for the rest of the body:
/// the region is a text PREFIX, so the first thing it cannot hold ends it.
pub fn hpMark(self: *Gen, v: Mir.Value) void {
    if (!self.hp_on or self.hp_dirty) return;
    if (!hpPure(self, v, 0)) self.hp_dirty = true;
}

pub fn hpMarkInst(self: *Gen, inst: Mir.Inst) void {
    if (!self.hp_on or self.hp_dirty) return;
    if (!hpPureInst(self, inst, 0)) self.hp_dirty = true;
}

/// A top-level statement boundary — `emitBlockInsts`/`emitTree` at depth 1, which are
/// the only points where the emitter's depth is 1 and therefore no label,
/// loop or arm is open. Probing: remember the last clean one. Emitting: open
/// the guard at the top of the body, close it at the remembered boundary.
pub fn hpBoundary(self: *Gen) Error!void {
    if (!self.hp_on or !self.emitting_common) return;
    if (self.probing) {
        if (!self.hp_dirty) {
            self.hp_cut = self.hp_bnd;
            self.hp_off = @intCast(self.out.items.len);
            self.hp_insts = self.stmt_count;
        }
    } else if (self.hp_bnd == 0) {
        self.uses_inst = true;
        try self.ind(1);
        try self.b("if (inst.hp_ok == 0) {{\n", .{});
        self.ind_base += 1;
    } else if (self.hp_bnd == self.hp_cut) {
        self.ind_base -= 1;
        try self.ind(1);
        try self.b("}} else {{\n", .{});
        for (self.hp_vals, 0..) |v, j| {
            const i = @intFromEnum(v);
            try self.ind(2);
            try gen_unit.writeSlotRef(self, i);
            if (self.an.vty[i] == .int)
                try self.b(" = inst.hpi[{d}];\n", .{j - self.hp_real})
            else
                try self.b(" = S.con(inst.hp[{d}]);\n", .{j});
        }
        try self.ind(1);
        try self.b("}}\n", .{});
    }
    self.hp_bnd += 1;
}

/// Find the region, once, before `emitInstance` needs its width. Runs the
/// same dry run `emitUnitBody` runs (`probeBody` only appends and rewinds),
/// under the same plan and float mode, so the boundary count it lands on is
/// the one the real walk will reach.
pub fn planHoistPrefix(self: *Gen) Error!void {
    self.hp_on = false;
    self.hp_vals = &.{};
    self.hp_real = 0;
    // No shared core to cut.
    if (self.core.lo_vals.len == 0) return;
    for (self.jobs.list) |job| {
        if (job.kind != .display and job.pre_fatal != null) return;
    }
    const save_common = self.emitting_common;
    const save_strict = self.cur_strict;
    defer {
        self.emitting_common = save_common;
        self.cur_strict = save_strict;
    }
    self.emitting_common = true;
    self.cur_strict = self.core.mode == .strict;
    self.plan.display_unit = false;
    try self.plan.analyze(.undef, true);
    // Straight-line: no phi to strand, so `pc__` already took everything
    // this could take, and a prefix guard would only add a branch.
    if (self.plan.straight) return;

    self.hp_on = true;
    self.hoist_idx.clearRetainingCapacity();
    try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);
    try gen_unit.probeBody(self, .undef);
    if (self.hp_cut == 0) {
        self.hp_on = false;
        return;
    }
    // Live-out of the region: assigned inside it, read after it. `place`
    // holds one dry run's offsets, and `hp_off` is an offset of that same
    // run — the only coordinate system either is compared in. Emission
    // order (`plan.live`) so the field indices are stable, reals first.
    //
    // `max_def` is the load-bearing half. The seeding call runs the WHOLE
    // core, so what it latches is the slot's value at the RETURN; the else
    // arm needs its value at the CUT. Those agree only when the region
    // holds the slot's last write. A `while` preheader seeding a
    // loop-carried phi is the counter-example that made this a rule rather
    // than a comment: the initial `i = 0` is solve-independent and the loop
    // that overwrites it is not, so caching it replayed the walk's LAST
    // index into its first iteration (annex_e_spice/primitive_{i,v}pwl).
    //
    // Every refusal below leaves `hp_on` false and BOTH of `hp_vals`/
    // `hp_real` at their entry zeros — `emitInstance` sizes `hpi` as
    // `hp_vals.len - hp_real`, so a half-written pair is an integer
    // overflow rather than a missing optimization.
    var vals: std.ArrayList(Mir.Value) = .empty;
    var n_real: u32 = 0;
    for ([_]VTy{ .real, .int }) |want| {
        for (self.plan.live.items) |lv| {
            const i = @intFromEnum(lv);
            if (self.an.vty[i] != want or self.plan.pcHoisted(lv)) continue;
            const s = self.plan.slot[i];
            if (s == none_u32) continue;
            const p = self.place.items[s];
            if (p.defs == 0 or p.def_off >= self.hp_off or p.max_use <= self.hp_off) continue;
            // Written on BOTH sides of the cut: no field can hold two
            // values, and cutting earlier is a search this does not run.
            if (p.max_def > self.hp_off) {
                self.hp_on = false;
                return;
            }
            try vals.append(self.arena, lv);
        }
        if (want == .real) n_real = @intCast(vals.items.len);
    }
    // A `[]const u8` has no `Instance` field to live in. Vanishingly rare
    // in a core prefix, and a whole region is not worth a third array.
    for (self.plan.live.items) |lv| {
        const i = @intFromEnum(lv);
        if (self.an.vty[i] != .str or self.plan.slot[i] == none_u32) continue;
        const p = self.place.items[self.plan.slot[i]];
        if (p.defs != 0 and p.def_off < self.hp_off and p.max_use > self.hp_off) {
            self.hp_on = false;
            return;
        }
    }
    // Worth a field? One reload is a load and a store, which is what the
    // cheapest skipped statement costs — so a region has to hold more than
    // two statements per value it hands on before the branch, the fields
    // and the `precompute` stores pay for themselves. Same accounting as
    // `pcConsider`'s, one level up. Zero values is the degenerate case:
    // nothing the region computed outlives it, so skipping it saves
    // nothing and the guard would be pure cost.
    if (vals.items.len == 0 or vals.items.len * 2 >= self.hp_insts) {
        self.hp_on = false;
        return;
    }
    self.hp_vals = vals.items;
    self.hp_real = n_real;
}

/// Auxiliary core sweeps must not initialize first-call state at a trial bias.
pub fn probeInstance(self: *Gen) Error![]const u8 {
    if (self.lowered.table_samples.items.len == 0) return "inst";
    try self.w("    var table_probe = inst.*;\n", .{});
    return "&table_probe";
}
