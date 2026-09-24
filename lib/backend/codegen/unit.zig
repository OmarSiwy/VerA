//! Units: one function per source unit, and the body each one computes.
//!
//! In: a unit and its backward slice of the MIR. Out: one stably named Zig function with its
//! own @setFloatMode (proof.zig's verdict for that unit).
//!
//! LRM clauses this file's code cites: §1.3.1.1, §3.6.2.2, §4.5, §4.5.11, §4.5.12, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.6, §5.6.1.3, §9.4.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_unit.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_cfg = @import("cfg.zig");
const Mir = @import("ir").Mir;
const cg_filters = @import("../cg_filters.zig");
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("ir").proof;
const diag = @import("diag");
const naming = @import("../naming.zig");
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

// =======================================================================
// Units
// =======================================================================

pub fn emitUnits(self: *Gen) Error!void {
    try self.w("// ---- the model, in one declaration ----\n\n", .{});
    // The §9.4 display unit calls the core through `core`, not through its
    // structural key, so the ONE call spelling works in both the single-file
    // form (this alias) and the split form (the alias in `Output.prelude`,
    // which is an `@import`). It sits in the prologue, ahead of the first
    // recorded unit range, so the ranges still tile.
    if (self.core.name.len != 0) try self.w("const core = {s};\n\n", .{self.core.name});
    try emitCommon(self);
    // §4.5.11/§4.5.12 the coefficient reader is DERIVED from the operator's
    // unit name (like the old `<unit>__q`), not a Unit of its own, so the
    // normative ordering in naming.zig/proof.zig is untouched. It reads
    // `Model` alone, so it was never part of the residual slice and is
    // unaffected by the merge.
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const k = u.op;
        if (k != .laplace and k != .zi) continue;
        if (self.names.opInstOf(@intCast(i)) == null) continue;
        const p = cg_filters.planOf(self, i);
        if (p.err != null) continue;
        const lo = self.out.items.len;
        const nm = try std.fmt.allocPrint(self.arena, "{s}__sec", .{self.names.unit_names[i]});
        const at = try cg_filters.emitFilterSections(self, self.names.unit_names[i], p, k == .zi);
        try gen_file.recordUnitFile(self, nm, lo, at);
    }
    for (self.jobs.list) |job| {
        if (job.kind != .display) continue;
        self.pre_fatal = job.pre_fatal;
        // §9.5 the one unit where a descriptor operation may actually happen.
        self.emitting_display = true;
        defer self.emitting_display = false;
        const lo = self.out.items.len;
        const at = try emitUnit(self, job.name, job.target, @tagName(job.mode), job.comment);
        try gen_file.recordUnitFile(self, job.name, lo, at);
    }
    self.pre_fatal = null;
}

/// The one declaration the shared core is emitted into. See the block
/// comment at "the shared core" for why the whole model is one declaration
/// returning a struct rather than one declaration per unit.
///
/// The return type is written INLINE (an anonymous struct in the signature)
/// rather than as a named `Common(S)`: a named type would be a second
/// top-level declaration, and in the single-file form it would have to be
/// public for the unit files to reach it — which `contract.validate`
/// rejects. Zig infers the anonymous type at both ends, so the units never
/// have to name it.
pub fn emitCommon(self: *Gen) Error!void {
    if (self.core.lo_vals.len == 0) return;
    self.emitting_common = true;
    defer self.emitting_common = false;

    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    // §3.6.2.2 a refusal visible from ANY unit's declaration poisons the one
    // body they now share. That is not a widening: `eval` stamps every
    // contribution, so a `@compileError` in any single unit already failed
    // the whole device.
    self.fatal = null;
    for (self.jobs.list) |job| {
        if (job.kind == .display) continue;
        if (job.pre_fatal) |m| {
            self.fatal = m;
            break;
        }
    }
    const pre = self.fatal;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(.undef, self.emitting_common); // `emitting_common` ⇒ the live-outs are the targets

    const lo = self.out.items.len;
    try self.w(
        \\/// The whole model, evaluated ONCE per residual: the {d} source units
        \\/// share one CFG, so they share one declaration and `eval`/`q` read
        \\/// their targets out of the returned struct.
        \\
        \\/// Inlined at every host-scalar site (`@call(.always_inline, ...)` in
        \\/// `eval`/`q`/`evalQ`), which destructure the returned struct at
        \\/// once: behind a call boundary the `[n_u]S` argument and the
        \\/// {d}-field result both go to memory, the host's Dual derivative
        \\/// vectors spill instead of staying in registers, and no live-out the
        \\/// caller drops can be dead-coded. Measured on ARPice
        \\/// devices/mos6_inverter: 45.3 ms inline vs 64.9 ms out-of-line
        \\/// (+43%), tran/fourbitadder +40%, scaling/parallel_inverters_500
        \\/// +51%. NOT `inline fn`, so the value-only `core(R, ...)` sites —
        \\/// updateState, noisePsd, collapse, limit, seed — share ONE
        \\/// out-of-line instantiation instead of each inlining the model.
        \\
    , .{ self.jobs.list.len, self.jobs.list.len });
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{self.core.name});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr) struct {{\n", .{});
    for (self.core.lo_vals, 0..) |v, k| {
        try self.w("    f{d}: {s},\n", .{ k, zigTy(self.an.vty[@intFromEnum(v)]) });
    }
    for (self.hp_vals, 0..) |v, j| {
        try self.w("    f{d}: {s}, // hoisted prefix\n", .{
            self.core.lo_vals.len + j, zigTy(self.an.vty[@intFromEnum(v)]),
        });
    }
    try self.w("}} {{\n", .{});
    // §4.3: the STRICTEST mode of every consumer — `proof.FloatMode.strictest`
    // explains why the join has to absorb `.strict`.
    try self.w("    @setFloatMode(.{t});\n", .{self.core.mode});
    self.cur_strict = self.core.mode == .strict;

    // Off the slice, not the text: every call the core computes is in
    // `plan.live`, and `gen_call.readsSimState` is the one list of which of
    // them render a read of a host-published sim-state field.
    for (self.plan.live.items) |lv| {
        const def = self.mir.valueDef(lv);
        if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) continue;
        if (self.plan.pcHoisted(lv)) continue; // a field read, not a call
        if (gen_call.readsSimState(self, def.inst_result)) self.core_reads_simstate = true;
    }

    const body_start = self.out.items.len;
    self.fatal = pre;
    try emitUnitBody(self, .undef);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    try self.w("}}\n\n", .{});
    try gen_file.recordUnitFile(self, self.core.name, lo, at_fn);
}

/// The unit enumerated from operator `call` `inst`, or `none_u32`.
// ponytail: a scan over the unit list (tens of entries), once per rendered
// operator; an nv-sized reverse map is what this replaced.
pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32 {
    for (self.names.units, 0..) |u, i| {
        if (u.inst == inst) return @intCast(i);
    }
    return none_u32;
}

/// Which field of the core holds analog-operator unit `i`'s §4.5 input, or
/// `none_u32` for an operator called with no argument (its input is the
/// literal zero and never reaches the core).
pub fn opInputIdx(self: *const Gen, i: u32) u32 {
    const args = self.names.opArgs(self.mir, i);
    if (args.len == 0) return none_u32;
    return self.core.lo_idx[@intFromEnum(self.an.rv(args[0]))];
}

/// Emit one source-unit function. LRM §5.6/§4.7/§5.3.
/// The signature is UNIFORM and never churns; only the body depends on the
/// unit's own logic, so `zig` re-Semas exactly the units that changed.
/// Which parameters the body ended up reading is only known after the body
/// is rendered, but the signature comes first. Rather than render into a
/// scratch buffer and copy (a second pass over every byte of a 191 MB
/// output), emit the signature with three fixed-width slots and overwrite
/// them in place. Zig does the same thing — `Parse.reserveNode` /`setNode`,
/// AstGen's `instructions.append(undefined)` … `instructions.set(...)`.
///
/// Zig allows whitespace before a parameter's `:`, so `_` can be padded out
/// to the width of the name it replaces. Padding the DISCARD rather than the
/// name keeps the used case byte-identical to a direct emit.
///
/// Returns the offset of the `fn` keyword, which is where
/// `orchestrator.writeTree` splices `pub ` when the declaration is written
/// to its own `u/<key>.zig`. It is NOT emitted `pub` here: `text` is also
/// the single-file `--emit-zig` form, and `contract.rejectStrayPubDecls`
/// (tools/contract.zig) allows only contract-recognized names
/// to be public on a device type. A per-unit name can never be one of
/// those, so the visibility belongs to the split, not to the emission.
pub fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: []const u8, comment: []const u8) Error!usize {
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.fatal = self.pre_fatal;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(target, self.emitting_common);

    try self.w("/// {s}\n", .{comment});
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{name});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr) S {{\n", .{});
    try self.w("    @setFloatMode(.{s});\n", .{mode});
    self.cur_strict = std.mem.eql(u8, mode, "strict");

    const body_start = self.out.items.len;
    try emitUnitBody(self, target);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    try self.w("}}\n\n", .{});
    return at_fn;
}

/// Overwrite a reserved parameter-name slot with `_`, space-padded to the
/// name's width so the bytes after it do not move.
pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
    self.out.items[at..][0..width].* = ("_" ++ " " ** (width - 1)).*;
}

// ---- slicing: what this unit actually has to compute -------------------

/// What taking `from → to` reduces to for this unit, or null when the edge
/// does something the unit can observe. Iterative, not recursive: the chain
/// of empty blocks is bounded by nothing syntactic.

// ---- body emission ------------------------------------------------------

pub fn zigTy(t: VTy) []const u8 {
    return switch (t) {
        .real => "S",
        .int => "i64",
        .str => "[]const u8",
    };
}

/// The identity a slot starts at when it must be defined on every path.
/// Matches `renderVal`'s rendering of an `.undef` operand, so the two agree
/// on what "no value here" looks like.
/// Name of the hoist array a slot of this type lives in — see `hoist_idx`.
pub fn hoistArray(t: VTy) []const u8 {
    return switch (t) {
        .real => "h",
        .int => "hi",
        .str => "hs",
    };
}

/// The name a value's slot is read and written under: its own `tN`, or an
/// element of its type's hoist array. The ONE place that knows the
/// difference, so declaration and use can never drift apart.
///
/// `writeSlotRef` is the hot form — every slotted use goes through it, and
/// it writes straight into the output buffer. `slotRefStr` is for the one
/// caller that needs the name as a value (`f64Const`).
pub fn slotArr(self: *Gen, i: usize) ?[]const u8 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
    return null;
}
pub fn slotNum(self: *Gen, i: usize) u32 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return self.hoist_idx.items[s];
    return s;
}
pub fn writeSlotRef(self: *Gen, i: usize) Error!void {
    if (slotArr(self, i)) |arr| {
        return self.b("{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return self.b("t{d}", .{slotNum(self, i)});
}
pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
    if (slotArr(self, i)) |arr| {
        return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return std.fmt.allocPrint(self.arena, "t{d}", .{slotNum(self, i)});
}

pub fn zeroOf(t: VTy) []const u8 {
    return switch (t) {
        .real => "S.con(0.0)",
        .int => "0",
        .str => "\"\"",
    };
}

/// Where one slot's declaration ends up, and the evidence for it.
///
/// `def_off`/`max_use` are output offsets and `scope` an index into
/// `sc_end`: since the emitted scopes nest, "every use is lexically inside
/// the block that defines this slot" is exactly
/// `def_off < max_use < sc_end[scope]`, and no dominator query is needed —
/// the emitter's own brace placement IS the answer.
pub const Place = struct {
    defs: u32 = 0,
    uses: u32 = 0,
    def_off: u32 = 0,
    /// Offset of the LAST def — a loop-carried slot's final write sits
    /// textually after its last read, and the prefix planner
    /// (`planHoistPrefix`) must see it.
    max_def: u32 = 0,
    max_use: u32 = 0,
    scope: u32 = 0,
    /// Something disqualifies this slot from `const`-at-definition: a
    /// second assignment (a real phi), a phi copy on a CFG edge, or a use
    /// emitted before the assignment (a loop-carried read).
    pinned: bool = false,
    /// Set once, after the probe: declare at the definition instead of at
    /// function scope.
    at_def: bool = false,
};

pub fn scopeOpen(self: *Gen) Error!void {
    if (!self.probing) return;
    try self.sc_end.append(self.arena, 0);
    try self.sc_open.append(self.arena, @intCast(self.sc_end.items.len - 1));
}

/// `at` is where the scope's text ends, which is NOT always `out.len`: the
/// `emitCode` peephole rewinds over a label it decided not to keep.
pub fn scopeClose(self: *Gen, at: usize) void {
    if (!self.probing) return;
    self.sc_end.items[self.sc_open.pop().?] = @intCast(at);
}

/// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
/// several edges, and even a single-edge copy lands in an arm its merge
/// block's readers are lexically outside of.
pub fn probeDef(self: *Gen, slot: u32, movable: bool) void {
    if (!self.probing) return;
    const p = &self.place.items[slot];
    if (p.defs == 0) {
        p.def_off = @intCast(self.out.items.len);
        p.scope = self.sc_open.getLast();
    }
    p.max_def = @intCast(self.out.items.len);
    p.defs += 1;
    if (p.defs > 1 or !movable) p.pinned = true;
}

pub fn probeUse(self: *Gen, slot: u32) void {
    if (!self.probing) return;
    const p = &self.place.items[slot];
    p.uses += 1;
    // Read before written in the text: a loop-carried value, or a slot the
    // emitter never assigns at all (which is the `undefined`/zero seed the
    // hoist exists to provide).
    if (p.defs == 0) p.pinned = true;
    p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
}

/// Emit the body once into scratch to learn, per slot, where its assignment
/// lands relative to its reads; rewind; then emit for real.
///
/// A dry run rather than a dominator/liveness query because the emitted
/// nesting is not the CFG: `planDeadBranches` deletes `if`s, the `emitCode`
/// peephole deletes labels, and `emitEdge` inlines a whole subtree into an
/// arm. Re-deriving the resulting brace structure would be a second, subtly
/// different copy of the emitter. Emission only appends to `out` and only
/// sets monotone `uses_*` flags, so running it twice is free of side
/// effects (`fatal` is set-once and reproduces the same message).
pub fn probeBody(self: *Gen, target: Mir.Value) Error!void {
    self.place.clearRetainingCapacity();
    try self.place.appendNTimes(self.arena, .{}, self.plan.n_slots);
    self.sc_end.clearRetainingCapacity();
    self.sc_open.clearRetainingCapacity();

    const at = self.out.items.len;
    self.probing = true;
    self.hp_bnd = 0;
    self.hp_cut = 0;
    self.hp_off = 0;
    self.hp_dirty = false;
    self.stmt_count = 0;
    try scopeOpen(self); // the function body itself
    try gen_cfg.emitTree(self, 0, 1, target);
    scopeClose(self, self.out.items.len);
    self.probing = false;
    self.hp_bnd = 0; // the real walk counts the same boundaries from zero
    self.out.shrinkRetainingCapacity(at);

    for (self.place.items) |*p| {
        // `uses == 0` keeps its `var`: a slot that is written and never read
        // is legal Zig, but the same code as an unused `const` is not.
        p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
            p.max_use < self.sc_end.items[p.scope];
    }
    // A value crossing the prefix guard has to be in a hoist ARRAY: the
    // guard is a scope its `const` would not survive, and the else arm has
    // to be able to assign it.
    for (self.hp_vals) |v| {
        const s = self.plan.slot[@intFromEnum(v)];
        if (s != none_u32) self.place.items[s].at_def = false;
    }
}

pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
    // FIRST, before anything can emit a slot name: slot numbering is
    // unit-local, so last unit's hoist indices would otherwise still be
    // live here and rename this unit's slots into another unit's array.
    // Both paths below can emit before the real assignment happens — the
    // straight-line path returns early, and `probeBody` dry-runs the whole
    // body — so clearing anywhere later is too late.
    self.hoist_idx.clearRetainingCapacity();
    try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);

    // One call, at the top of the body, so the shared core is evaluated
    // exactly once per unit — the same number of times it is evaluated
    // today, when every unit inlines a copy of it.
    if (self.plan.uses_cache) {
        self.uses_x = true;
        self.uses_model = true;
        self.uses_inst = true;
        try self.ind(1);
        try self.b("const c = @call(.always_inline, core, .{{ S, x, model, inst }});\n", .{});
    }
    if (self.plan.straight) {
        try gen_cfg.emitBlockInsts(self, 0, 1, true);
        try gen_cfg.emitReturn(self, 1, target);
        return;
    }
    // Out-of-SSA: a function-scope `var` per surviving value that NEEDS
    // one. Function scope (not the defining lexical block) because a
    // labelled-block reconstruction can put a definition inside a scope its
    // dominated uses are lexically outside of — but that is the exception,
    // not the rule, so `probeBody` measures it instead of assuming it and
    // `emitBlockInsts` declares the rest as `const` at the definition. On
    // `hisimhv_va` that is 16 k of 20 k hoists removed, ~26% of the file.
    //
    // What is left hoisted, and why each one has to be:
    //   - assigned more than once — a genuine phi, so it must be a `var`;
    //   - assigned by `emitPhiCopies` — the copy sits in the arm, the
    //     readers sit after the merge;
    //   - read outside the block that assigns it — the labelled-block case
    //     the comment above describes;
    //   - never assigned at all, which is the `undefined`/zero seed below.
    //
    // `undefined` is safe for every slot EXCEPT one the function RETURNS.
    // SSA guarantees a use is dominated by its definition, so an ordinary
    // slot is always written before it is read — but the return is reached
    // from every exit block, including ones the definition does not
    // dominate. That happens whenever the unit's target is defined inside a
    // conditional, which is exactly what `if (c) I <+ transition(x)` builds:
    // the operator's INPUT unit then returned `undefined` on the not-taken
    // path, and `updateState` pushed that into the operator's history —
    // undefined behavior in a shipped device, and silent state corruption in
    // the far more common case where it merely looked like a number.
    //
    // Zero is the value, not just a safe one: the arm did not execute, so it
    // contributed nothing this step — the same reason lowering seeds a §5.6
    // contribution accumulator with `.f_zero`.
    // Pinned by tests/fixtures/exhaustive/069_conditional_operator_state.va.
    try probeBody(self, target);
    const ret = self.an.rv(target);

    // One array per type instead of one `var` per slot. Two passes: assign
    // every survivor its index first, so the array lengths are known before
    // anything is written, then emit the declarations. `hoist_idx` was
    // cleared at entry and `probeBody` has just run against those cleared
    // names, so this is the first assignment either pass has seen.
    var n_hoist = [_]u32{0} ** 3;
    // A returned slot cannot be seeded `undefined` (see above), and an array
    // is declared once for all of its elements — so those are seeded by an
    // explicit store after the declaration instead.
    var seeded: std.ArrayList(Mir.Value) = .empty;
    defer seeded.deinit(self.arena);
    for (self.plan.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.plan.slot[v] == none_u32) continue;
        const p = self.place.items[self.plan.slot[v]];
        if (p.at_def) continue;
        // Never assigned and never read: `mark` kept the value alive but
        // the emitted tree reaches neither end of it. Declaring it would be
        // an unused local.
        if (p.defs == 0 and p.uses == 0) continue;
        const ty = @intFromEnum(self.an.vty[v]);
        self.hoist_idx.items[self.plan.slot[v]] = n_hoist[ty];
        n_hoist[ty] += 1;
        const returned = if (self.emitting_common) self.core.lo_idx[v] != none_u32 else lv == ret;
        if (returned) try seeded.append(self.arena, lv);
    }
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = n_hoist[@intFromEnum(ty)];
        if (n == 0) continue;
        try self.ind(1);
        try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
    }
    for (seeded.items) |lv| {
        const v = @intFromEnum(lv);
        try self.ind(1);
        try writeSlotRef(self, v);
        try self.b(" = {s};\n", .{zeroOf(self.an.vty[v])});
    }
    try gen_cfg.emitTree(self, 0, 1, target);
    // The guard opened at boundary 0 is closed at boundary `hp_cut`;
    // if the real walk never reached it the emitted brace is unbalanced,
    // which is a generator bug and not something to ship.
    assert(!self.hp_on or !self.emitting_common or self.hp_bnd > self.hp_cut);
}
