//! A unit and its backward slice of the MIR -> one stably named Zig function
//! with its own @setFloatMode (proof.zig's verdict), including the shared core
//! every residual reads. Also decides where each slot is declared.
//! LRM: §1.3.1.1, §3.2.2, §3.6.2.2, §4.5, §4.5.11, §4.5.12, §4.6.3, §4.6.4,
//! §5.6.1.3, §5.10, §9.4.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const plan_core = @import("plan/core.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const gen_cfg = @import("cfg.zig");
const gen_setup = @import("setup.zig");
const gen_state = @import("state.zig");
const gen_render = @import("render.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const cg_filters = @import("../cg_filters.zig");
const cg_limit = @import("../cg_limit.zig");
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

/// Emits every unit declaration (the shared core, the filter coefficient
/// readers and each job's unit), recording each range in `Output`.
pub fn emitUnits(self: *Gen) Error!void {
    try self.w("// ---- the model, in one declaration ----\n\n", .{});
    // The §9.4 display unit calls the core as `core`, so one spelling works
    // in the single-file form (this alias) and the split form (the alias in
    // `Output.prelude`). It sits ahead of the first recorded unit range, so
    // the ranges still tile.
    if (self.core.name.len != 0) try self.w("const core = {s};\n\n", .{self.core.name});
    try emitCommon(self);
    try cg_limit.emitCore(self);
    try gen_state.emitCore(self);
    try gen_state.emitIterCore(self);
    try gen_dispatch.emitNoiseCore(self);
    // §4.5.11/§4.5.12 the coefficient reader is named from the operator's
    // unit (`<unit>__sec`), not a Unit of its own, so the ordering in
    // naming.zig/proof.zig is untouched. It reads `Model` alone, so it is
    // not part of the residual slice.
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

/// Emits the shared core: one declaration computing every live-out and
/// returning them as a struct (plan/core.zig says why). The return type is an
/// anonymous struct in the signature, because a named type would have to be
/// public for unit files to reach it, which `contract.validate` rejects.
pub fn emitCommon(self: *Gen) Error!void {
    if (self.core.lo_vals.len == 0) return;
    const n = self.jobs.list.len;
    try emitCoreDecl(self, self.core.name, try std.fmt.allocPrint(self.arena, core_doc, .{ n, n }));
}

const core_doc =
    \\/// The whole model, evaluated ONCE per residual: the {d} source units
    \\/// share one CFG, so they share one declaration and `eval`/`q` read
    \\/// their targets out of the returned struct.
    \\
    \\/// Inlined at every host-scalar site (`@call(.always_inline, ...)` in
    \\/// `eval`/`q`/`evalQ`), which destructure the returned struct at
    \\/// once: behind a call boundary the unknowns argument and the
    \\/// {d}-field result both go to memory, the host's Dual derivative
    \\/// vectors spill instead of staying in registers, and no live-out the
    \\/// caller drops can be dead-coded. Measured on ARPice
    \\/// devices/mos6_inverter: 45.3 ms inline vs 64.9 ms out-of-line
    \\/// (+43%), tran/fourbitadder +40%, scaling/parallel_inverters_500
    \\/// +51%. NOT `inline fn`, so the value-only `core(S, zVals(...))`
    \\/// sites — collapse, seed — share ONE
    \\/// out-of-line instantiation per family instead of each inlining the
    \\/// model.
    \\
;

/// Emits declaration `name`, the core's slice returning only `vals` (`idx`
/// maps each value to its field), under doc comment `doc`. Same MIR and
/// float mode as the core, so every field is bit-identical to the core's.
/// For a value-only caller: its reals are no `lane_masks` data.
pub fn emitSlice(self: *Gen, name: []const u8, vals: []Mir.Value, idx: []u32, doc: []const u8) Error!void {
    const saved = .{ self.core.lo_vals, self.plan.lo_idx, self.plan.lo_vals };
    defer {
        self.core.lo_vals = saved[0];
        self.plan.lo_idx = saved[1];
        self.plan.lo_vals = saved[2];
    }
    self.core.lo_vals = vals;
    self.plan.lo_idx = idx;
    self.plan.lo_vals = vals;
    const n_masks = self.fam_masks.items.len;
    defer self.fam_masks.shrinkRetainingCapacity(n_masks);
    try emitCoreDecl(self, name, doc);
}

/// Emits `<core>__<suffix>`, the slice returning the core fields `keep`
/// marks, in core order, and returns the core as that slice's caller reads
/// it: `name` the slice, and `lo_idx`, `lo_vals`, `prev_lo`, `acc_lo` and
/// `held_idx` renumbered onto its fields (`none_u32` where it has none).
/// Swapped into `Gen.core` while the caller's body is written, every
/// `m.f<k>` that body renders names the slice's field.
pub fn sliceCore(self: *Gen, suffix: []const u8, keep: []const bool, doc: []const u8) Error!plan_core.Core {
    const full = self.core;
    const idx = try self.arena.alloc(u32, self.an.nv);
    @memset(idx, none_u32);
    const remap = try self.arena.alloc(u32, full.lo_vals.len);
    @memset(remap, none_u32);
    var vals: std.ArrayList(Mir.Value) = .empty;
    for (full.lo_vals, keep, 0..) |v, kept, k| {
        if (!kept) continue;
        remap[k] = @intCast(vals.items.len);
        idx[@intFromEnum(v)] = remap[k];
        try vals.append(self.arena, v);
    }
    var sc = full;
    sc.name = try std.fmt.allocPrint(self.arena, "{s}__{s}", .{ full.name, suffix });
    sc.lo_idx = idx;
    sc.lo_vals = vals.items;
    sc.prev_lo = try remapAll(self, full.prev_lo, remap);
    sc.acc_lo = try remapAll(self, full.acc_lo, remap);
    sc.held_idx = try remapAll(self, full.held_idx, remap);
    // `sc.held_only` stays the core's: an unread `held` is renamed `_`, not
    // dropped, so every caller still passes `heldArg`.
    try emitSlice(self, sc.name, vals.items, idx, doc);
    return sc;
}

fn remapAll(self: *Gen, fields: []const u32, remap: []const u32) Error![]u32 {
    const out = try self.arena.alloc(u32, fields.len);
    for (out, fields) |*o, k| o.* = if (k == none_u32) none_u32 else remap[k];
    return out;
}

/// Emits declaration `name` computing `self.core.lo_vals` and returning them
/// as a struct: the shared core, or a caller's slice of it with `core.lo_vals`
/// and `plan.lo_idx`/`lo_vals` swapped (`emitSlice`), under doc comment `doc`.
pub fn emitCoreDecl(self: *Gen, name: []const u8, doc: []const u8) Error!void {
    self.emitting_common = true;
    defer self.emitting_common = false;

    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.uses_sim = false;
    // §3.6.2.2 a refusal visible from any unit's declaration poisons the
    // shared body. Not a widening: `eval` stamps every contribution, so any
    // unit's `@compileError` already failed the whole device.
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
    try self.w("{s}", .{doc});
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{name});
    const at_x = self.out.items.len;
    try self.w("x: {s}, ", .{xType(self)});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState", .{});
    // §5.10 whether the caller keeps the held arrays' end-of-block values
    // (`Gen.heldArg`).
    self.uses_held = false;
    const at_held = self.out.items.len + ", comptime ".len;
    if (self.core.held_only.len != 0) try self.w(", comptime held: bool", .{});
    try self.w(") struct {{\n", .{});
    for (self.core.lo_vals, 0..) |v, k| {
        // §3.2.2 a held array's end-of-block version: its plain values.
        if (self.an.arrOf(v)) |id| {
            const m = self.lowered.mem_arrays.items[id];
            try self.w("    f{d}: [{d}]{s},\n", .{ k, m.len, if (m.ty == .integer) "i64" else "f64" });
        } else if (self.an.vty[@intFromEnum(v)] == .real) {
            try family.note(self, family.mask(self, v));
            try self.w("    f{d}: {s},\n", .{ k, try family.ofText(self, family.mask(self, v)) });
        } else try self.w("    f{d}: {s},\n", .{ k, zigTy(self.an.vty[@intFromEnum(v)]) });
    }
    try self.w("}} {{\n", .{});
    // §4.3: the strictest mode of every consumer (`proof.FloatMode.strictest`
    // explains why the join absorbs `.strict`).
    try self.w("    @setFloatMode(.{t});\n", .{self.core.mode});
    self.float.strict = self.core.mode == .strict;

    const body_start = self.out.items.len;
    // `Setup` defaults its reals to NaN, which a missed `setup` call turns
    // into a NaN residual; the integers have no NaN, so Debug asserts it.
    if (self.su.vals.len != 0) {
        self.uses_inst = true;
        try self.w("    if (std.debug.runtime_safety) std.debug.assert(inst.su_ok);\n", .{});
    }
    self.fatal = pre;
    try emitUnitBody(self, .undef);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        self.uses_sim = false;
        self.uses_held = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    if (!self.uses_sim) patchParam(self, at_sim, "sim".len);
    if (self.core.held_only.len != 0 and !self.uses_held) patchParam(self, at_held, "held".len);
    // A slice of integers and plain arrays alone never names `S`.
    if (!try namesIdent(self, self.out.items[at_x..], "S")) patchParam(self, at_x - "S: type, ".len, "S".len);
    try self.w("}}\n\n", .{});
    try gen_file.recordUnitFile(self, name, lo, at_fn);
}

/// Returns the unit enumerated from operator call `inst`, or `none_u32`.
// ponytail: a linear scan over the unit list (tens of entries) per rendered
// operator; an nv-sized reverse map if unit counts grow.
pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32 {
    for (self.names.units, 0..) |u, i| {
        if (u.inst == inst) return @intCast(i);
    }
    return none_u32;
}

/// Returns which core field holds analog-operator unit `i`'s §4.5 input, or
/// `none_u32` for an operator called with no argument (its input is the
/// literal zero and never reaches the core).
pub fn opInputIdx(self: *const Gen, i: u32) u32 {
    const args = self.names.opArgs(self.mir, i);
    if (args.len == 0) return none_u32;
    return self.core.lo_idx[@intFromEnum(self.an.rv(args[0]))];
}

/// Emits one source-unit function (LRM §5.6, §4.7, §5.3). The signature is
/// uniform, so `zig` re-analyses exactly the units whose bodies changed.
/// Parameters the body never reads are back-patched to `_`, padded to the
/// name's width, in fixed slots reserved before the body is rendered.
///
/// Returns the offset of the `fn` keyword, where `orchestrator.writeTree`
/// splices `pub ` for the split form. `text` itself stays private because
/// `contract.rejectStrayPubDecls` allows only contract-recognized public names.
pub fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: []const u8, comment: []const u8) Error!usize {
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.uses_sim = false;
    self.fatal = self.pre_fatal;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(target, self.emitting_common);

    try self.w("/// {s}\n", .{comment});
    const at_fn = self.out.items.len;
    try self.w("fn {s}(comptime S: type, ", .{name});
    const at_x = self.out.items.len;
    try self.w("x: {s}, ", .{xType(self)});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) {s} {{\n", .{try family.ofText(self, family.mask(self, target))});
    try self.w("    @setFloatMode(.{s});\n", .{mode});
    self.float.strict = std.mem.eql(u8, mode, "strict");

    const body_start = self.out.items.len;
    try emitUnitBody(self, target);
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        self.uses_sim = false;
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses_x) patchParam(self, at_x, "x".len);
    if (!self.uses_model) patchParam(self, at_model, "model".len);
    if (!self.uses_inst) patchParam(self, at_inst, "inst".len);
    if (!self.uses_sim) patchParam(self, at_sim, "sim".len);
    try self.w("}}\n\n", .{});
    return at_fn;
}

/// Overwrites a reserved parameter-name slot with `_`, space-padded to the
/// name's width so the bytes after it do not move.
pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
    self.out.items[at..][0..width].* = ("_" ++ " " ** (width - 1)).*;
}

/// Calls `patchParam` on the slot at `at` unless the body text from `from`
/// names `ident` as a whole identifier. Only valid for a body with no string
/// literal in it.
pub fn patchUnless(self: *Gen, at: usize, from: usize, comptime ident: []const u8) void {
    var it = std.mem.indexOfPos(u8, self.out.items, from, ident);
    while (it) |i| : (it = std.mem.indexOfPos(u8, self.out.items, i + 1, ident)) {
        const t = self.out.items;
        // Not a field (`m.sim`), not part of a longer name.
        const before = i == 0 or !(isIdent(t[i - 1]) or t[i - 1] == '.');
        const after = i + ident.len >= t.len or !isIdent(t[i + ident.len]);
        if (before and after) return;
    }
    patchParam(self, at, ident.len);
}

/// Returns whether Zig source `text` names `ident` as an identifier token,
/// outside any string literal or comment.
fn namesIdent(self: *Gen, text: []const u8, ident: []const u8) Error!bool {
    const src = try self.arena.dupeZ(u8, text);
    var t: std.zig.Tokenizer = .init(src);
    while (true) {
        const tok = t.next();
        if (tok.tag == .eof) return false;
        if (tok.tag == .identifier and std.mem.eql(u8, src[tok.loc.start..tok.loc.end], ident)) return true;
    }
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ---- body emission ------------------------------------------------------

/// A body's unknowns: a tuple, each unknown typed by the lanes it carries.
fn xType(_: *const Gen) []const u8 {
    return "anytype";
}

/// Returns the Zig type a value of type `t` is emitted as.
pub fn zigTy(t: VTy) []const u8 {
    return switch (t) {
        .real => "S",
        .int => "i64",
        .str => "[]const u8",
    };
}

/// Returns the name of the hoist array a slot of type `t` lives in (`hoist_idx`).
fn hoistArray(t: VTy) []const u8 {
    return switch (t) {
        .real => "h",
        .int => "hi",
        .str => "hs",
    };
}

// `slotArr`/`slotNum` are the one place that knows whether a slot is its own
// `tN` or a hoist-array element, so declaration and use cannot drift apart.
fn slotArr(self: *Gen, i: usize) ?[]const u8 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
    return null;
}
fn slotNum(self: *Gen, i: usize) u32 {
    const s = self.plan.slot[i];
    if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return self.hoist_idx.items[s];
    return s;
}
/// Writes the name value `i`'s slot is read and written under: its own `tN`
/// or an element of its type's hoist array. Every slotted use goes through it.
pub fn writeSlotRef(self: *Gen, i: usize) Error!void {
    if (slotArr(self, i)) |arr| {
        return self.b("{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return self.b("t{d}", .{slotNum(self, i)});
}

/// Returns the mask of value `i`'s slot when it is an element of the real
/// hoist array (what a write into it widens to), or null for a `const`.
pub fn slotMask(self: *Gen, i: usize) ?u64 {
    if (self.an.vty[i] != .real) return null;
    if (slotArr(self, i) == null) return null;
    return self.hoist_mask.items[slotNum(self, i)];
}

/// Every real hoist element's mask: the union over the values that share it.
fn hoistMasks(self: *Gen, n: u32) Error!void {
    self.hoist_mask.clearRetainingCapacity();
    try self.hoist_mask.appendNTimes(self.arena, 0, n);
    for (self.plan.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.an.vty[v] != .real or self.plan.slot[v] == none_u32) continue;
        const k = self.hoist_idx.items[self.plan.slot[v]];
        if (k == none_u32) continue;
        self.hoist_mask.items[k] |= family.mask(self, lv);
    }
    for (self.hoist_mask.items) |m| try family.note(self, m);
}

/// Returns `writeSlotRef`'s text as an arena-owned string, for a caller that
/// needs the name as a value (`f64Const`).
pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
    if (slotArr(self, i)) |arr| {
        return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ arr, slotNum(self, i) });
    }
    return std.fmt.allocPrint(self.arena, "t{d}", .{slotNum(self, i)});
}

/// Returns the zero a slot of type `t` starts at when it must be defined on
/// every path. Matches `renderVal`'s rendering of an `.undef` operand.
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
/// `sc_end`. The emitted scopes nest, so "every use is lexically inside the
/// block that defines this slot" is exactly `def_off < max_use <
/// sc_end[scope]`, with no dominator query needed.
pub const Place = struct {
    defs: u32 = 0,
    uses: u32 = 0,
    def_off: u32 = 0,
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

/// Records that a lexical scope opens at the current output offset. No-op
/// unless `probing`.
pub fn scopeOpen(self: *Gen) Error!void {
    if (!self.probing) return;
    try self.sc_end.append(self.arena, 0);
    try self.sc_open.append(self.arena, @intCast(self.sc_end.items.len - 1));
}

/// Records that the innermost open scope ends at `at`, which is not always
/// `out.len`: the `emitCode` peephole rewinds over a label it drops.
/// No-op unless `probing`.
pub fn scopeClose(self: *Gen, at: usize) void {
    if (!self.probing) return;
    self.sc_end.items[self.sc_open.pop().?] = @intCast(at);
}

/// Records the definition of `slot` at the current offset while `probing`.
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
    p.defs += 1;
    if (p.defs > 1 or !movable) p.pinned = true;
}

/// Records a read of `slot` at the current offset while `probing`.
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

/// Emits the body once as a dry run to learn, per slot, where its assignment
/// lands relative to its reads, then rewinds `out`. A dry run rather than a
/// dominator query because the emitted nesting is not the CFG (dead branches,
/// dropped labels and inlined arms). Safe to run twice: emission only appends
/// to `out` and sets monotone flags, and `fatal` is set-once.
pub fn probeBody(self: *Gen, target: Mir.Value) Error!void {
    self.place.clearRetainingCapacity();
    try self.place.appendNTimes(self.arena, .{}, self.plan.n_slots);
    self.sc_end.clearRetainingCapacity();
    self.sc_open.clearRetainingCapacity();

    const at = self.out.items.len;
    self.su.exits = 0;
    self.su.store_bytes = 0;
    self.probing = true;
    try scopeOpen(self); // the function body itself
    try gen_setup.emitRoot(self, target);
    scopeClose(self, self.out.items.len);
    self.probing = false;
    self.su.lines = std.mem.count(u8, self.out.items[at..], "\n");
    self.out.shrinkRetainingCapacity(at);

    for (self.place.items) |*p| {
        // `uses == 0` keeps its `var`: a slot that is written and never read
        // is legal Zig, but the same code as an unused `const` is not.
        p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
            p.max_use < self.sc_end.items[p.scope];
    }
}

/// Declares §3.2.2 `var a<id>: [len]T` for each memory-backed array this body
/// writes or reads locally, in array order. Its first `anew` fills it.
fn declareArrays(self: *Gen) Error!void {
    const n = self.lowered.mem_arrays.items.len;
    if (n == 0) return;
    const seen = try self.arena.alloc(bool, n);
    @memset(seen, false);
    // §5.10 a copy-on-write array needs its local storage only if a store
    // writes it; until one does, `p<id>` is the whole of it.
    const stored = try self.arena.alloc(bool, n);
    @memset(stored, false);
    for (self.plan.live.items) |lv| {
        const id = self.an.arrOf(lv) orelse continue;
        if (self.plan.cached(lv)) continue;
        seen[id] = true;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .store) stored[id] = true;
    }
    for (seen, stored, 0..) |s, st, id| {
        if (!s) continue;
        const len = self.lowered.mem_arrays.items[id].len;
        const ty = try gen_render.arrElemTy(self, @intCast(id));
        if (gen_render.cow(self, @intCast(id))) {
            try self.ind(1);
            try self.b("var p{d}: *const [{d}]{s} = undefined;\n", .{ id, len, ty });
            if (!st) continue;
        }
        try self.ind(1);
        try self.b("var a{d}: [{d}]{s} = undefined;\n", .{ id, len, ty });
    }
}

/// Emits the body computing `target` (or every live-out, while
/// `emitting_common`): slot declarations, then the structured control flow.
/// Requires `self.plan` to be analyzed for this unit.
pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
    // First, before anything can emit a slot name: slot numbering is
    // unit-local, so the previous unit's hoist indices would rename this
    // unit's slots. Both paths below can emit before the real assignment.
    self.hoist_idx.clearRetainingCapacity();
    try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);

    // One call at the top of the body, so the shared core is evaluated
    // exactly once per unit.
    if (self.plan.uses_cache) {
        self.uses_x = true;
        self.uses_model = true;
        self.uses_inst = true;
        self.uses_sim = true;
        try self.ind(1);
        try self.b("const c = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(true)});
    }
    try declareArrays(self);
    if (self.plan.straight) {
        try gen_cfg.emitBlockInsts(self, 0, 1, true);
        try gen_cfg.emitReturn(self, 1, target);
        return;
    }
    // Out-of-SSA: a function-scope `var` per surviving value that needs one.
    // A labelled-block reconstruction can put a definition inside a scope its
    // uses are lexically outside of; `probeBody` finds those, and
    // `emitBlockInsts` declares the rest as `const` at the definition.
    // Left hoisted: values assigned more than once (a real phi), assigned by
    // `emitPhiCopies`, read outside the assigning block, or never assigned.
    //
    // `undefined` is safe for every slot except one the function returns: the
    // return is reached from exit blocks the definition need not dominate
    // (`if (c) I <+ transition(x)`), and `updateState` would push that value
    // into operator history. Zero is the right value, not just a safe one:
    // the arm did not execute, so it contributed nothing, the same reason
    // lowering seeds a §5.6 accumulator with `.f_zero`.
    // Pinned by tests/fixtures/exhaustive/069_conditional_operator_state.va.
    try probeBody(self, target);
    if (gen_setup.mergePays(self)) {
        self.su.merge = true;
        try probeBody(self, target);
    }
    const ret = self.an.rv(target);

    // One array per type instead of one `var` per slot. Two passes: assign
    // every survivor its index, so the lengths are known, then emit the
    // declarations.
    var n_hoist = [_]u32{0} ** 3;
    // A returned slot cannot be seeded `undefined` (see above), and an array
    // is declared once for all its elements, so those get an explicit store
    // after the declaration.
    var seeded: std.ArrayList(Mir.Value) = .empty;
    defer seeded.deinit(self.arena);
    for (self.plan.live.items) |lv| {
        const v = @intFromEnum(lv);
        if (self.plan.slot[v] == none_u32) continue;
        const p = self.place.items[self.plan.slot[v]];
        if (p.at_def) continue;
        // Never assigned and never read: `mark` kept the value alive but the
        // emitted tree reaches neither end. Declaring it would be an unused local.
        if (p.defs == 0 and p.uses == 0) continue;
        const ty = @intFromEnum(self.an.vty[v]);
        self.hoist_idx.items[self.plan.slot[v]] = n_hoist[ty];
        n_hoist[ty] += 1;
        const returned = if (self.emitting_common) self.plan.lo_idx[v] != none_u32 else lv == ret;
        if (returned) try seeded.append(self.arena, lv);
    }
    try hoistMasks(self, n_hoist[@intFromEnum(VTy.real)]);
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = n_hoist[@intFromEnum(ty)];
        if (n == 0) continue;
        try self.ind(1);
        if (ty == .real) {
            try self.b("var h: zSlots(S, &.{{", .{});
            for (self.hoist_mask.items, 0..) |m, k| try self.b("{s}0x{x}", .{ if (k == 0) " " else ", ", m });
            try self.b(" }}) = undefined;\n", .{});
            continue;
        }
        try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
    }
    for (seeded.items) |lv| {
        const v = @intFromEnum(lv);
        try self.ind(1);
        try writeSlotRef(self, v);
        try self.b(" = ", .{});
        const m = slotMask(self, v);
        if (m) |k| try family.openTo(self, k);
        try self.b("{s}", .{zeroOf(self.an.vty[v])});
        if (m != null) try self.b(")", .{});
        try self.b(";\n", .{});
    }
    try gen_setup.emitRoot(self, target);
}
