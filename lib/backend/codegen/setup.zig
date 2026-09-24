//! Setup: the solve-invariant slice of the model, computed once.
//!
//! In: `plan/setup.zig`'s answer (which values are the same at every Newton
//! iterate and time point) and the core's plan. Out: which of those the
//! per-eval core reads (the setup ROOTS), `pub const Setup`, and `pub fn
//! setup` computing them into `Instance.su` once per model card, instance
//! and temperature.
//!
//! NOT a pure plan: the roots are the core's slice with every candidate a
//! leaf, which is `UnitPlan.analyze`, and `setup` is emitted through the same
//! relooper as the core. The classifier is `plan/setup.zig`.
//!
//! LRM clauses this file's code cites: §4.4, §5.10.2, §9.4, §9.15.
//!
//! ROOTS. A candidate is an invariant, non-constant `inst_result` of real or
//! integer type defined outside every loop (a loop value is per iteration).
//! The roots are exactly the candidates the core's slice — and the §9.4
//! display unit's — reaches when candidates are leaves: what eval reads,
//! nothing more. Reals first, then integers, each by ascending value.
//!
//! Functions take `self: *Gen` and are called directly, `gen_setup.f(self,
//! ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const plan_setup = @import("plan/setup.zig");
const plan_args = @import("plan/args.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

/// The roots and the emission state of `setup` — one `Gen` field (`Gen.su`).
pub const Setup = struct {
    /// Value → index in `Setup.r` (reals) or `Setup.i` (integers), or
    /// `none_u32`. Every body but `setup` reads a root as a leaf
    /// (`UnitPlan.isRoot`).
    idx: []u32 = &.{},
    /// The roots, reals first; `real` of them are reals.
    vals: []Mir.Value = &.{},
    real: u32 = 0,
    /// `Options.setup`: `false` emits the un-split device, every value
    /// computed in eval — the bit-for-bit oracle the split is checked against.
    on: bool = true,
    /// Set while `setup` is being emitted: `emitReturn` stores the roots and
    /// `emitTerm` takes a per-eval branch `then`.
    mode: bool = false,
    /// `setup` referenced its `zs_stop` flag (a per-eval branch or loop).
    stop: bool = false,
};

/// Auxiliary core sweeps must not initialize first-call state at a trial bias.
pub fn probeInstance(self: *Gen) Error![]const u8 {
    if (self.lowered.table_samples.items.len == 0) return "inst";
    try self.w("    var table_probe = inst.*;\n", .{});
    return "&table_probe";
}

/// Classify (`plan/setup.zig`), then decide the roots: run the core's (and
/// the display unit's) slice with every candidate a leaf, and keep the
/// candidates it reaches. Must run after the core is planned and before
/// anything is emitted — `emitInstance` sizes `Setup` from the roots.
pub fn planSetup(self: *Gen) Error!void {
    const a = self.arena;
    const nv = self.an.nv;
    self.su.idx = try a.alloc(u32, nv);
    @memset(self.su.idx, none_u32);
    self.su.vals = &.{};
    self.su.real = 0;
    self.sinv = try plan_setup.plan(self.input());
    if (!self.su.on) return;
    // Tables sample on the first ACTUAL evaluation, never at a trial point.
    if (self.lowered.table_samples.items.len != 0) return;
    if (self.core.lo_vals.len == 0 and self.jobs.display_name.len == 0) return;
    for (0..nv) |i| {
        if (plan_setup.candidate(self.input(), self.sinv.val, @enumFromInt(@as(u32, @intCast(i))))) self.su.idx[i] = 0;
    }
    self.plan.su_idx = self.su.idx;
    self.plan.su_on = true;
    const root = try a.alloc(bool, nv);
    @memset(root, false);
    if (self.core.lo_vals.len != 0) {
        self.plan.display_unit = false;
        try self.plan.analyze(.undef, true);
        for (self.plan.live.items) |lv| {
            if (self.su.idx[@intFromEnum(lv)] != none_u32) root[@intFromEnum(lv)] = true;
        }
    }
    for (self.jobs.list) |job| {
        if (job.kind != .display) continue;
        self.plan.display_unit = true;
        try self.plan.analyze(job.target, false);
        self.plan.display_unit = false;
        for (self.plan.live.items) |lv| {
            if (self.su.idx[@intFromEnum(lv)] != none_u32 and !self.plan.cached(lv)) root[@intFromEnum(lv)] = true;
        }
    }
    @memset(self.su.idx, none_u32);
    var vals: std.ArrayList(Mir.Value) = .empty;
    var n_real: u32 = 0;
    for ([_]VTy{ .real, .int }) |want| {
        var k: u32 = 0;
        for (0..nv) |i| {
            if (!root[i] or self.an.vty[i] != want) continue;
            self.su.idx[i] = k;
            k += 1;
            try vals.append(a, @enumFromInt(@as(u32, @intCast(i))));
        }
        if (want == .real) n_real = k;
    }
    self.su.vals = vals.items;
    self.su.real = n_real;
    self.plan.su_idx = self.su.idx;
    self.plan.su_on = vals.items.len != 0;
}

/// A root's field, as an f64 (`as_f64`) or in its own type.
pub fn rootRef(self: *Gen, v: Mir.Value, as_f64: bool) Error![]const u8 {
    const i = @intFromEnum(v);
    const k = self.su.idx[i];
    self.uses_inst = true;
    if (self.an.vty[i] == .int) {
        if (as_f64) return std.fmt.allocPrint(self.arena, "@as(f64, @floatFromInt(inst.su.i[{d}]))", .{k});
        return std.fmt.allocPrint(self.arena, "inst.su.i[{d}]", .{k});
    }
    return std.fmt.allocPrint(self.arena, "inst.su.r[{d}]", .{k});
}

/// `pub const Setup`, ahead of `Instance`.
pub fn emitSetupDecl(self: *Gen) Error!void {
    if (self.su.vals.len == 0) return;
    const n_int = self.su.vals.len - self.su.real;
    try self.w(
        \\/// Solve-invariant values: functions of `Model`, this instance and its
        \\/// temperature only, which `eval` would otherwise recompute at every
        \\/// Newton iterate. `setup` fills them; until it runs the reals are
        \\/// NaN, so a forgotten call is a NaN residual and not a plausible
        \\/// wrong one. `@sizeOf(Setup)` is the per-instance cost.
        \\pub const Setup = struct {{
        \\
    , .{});
    if (self.su.real != 0) try self.w("    r: [{d}]f64 = @splat(std.math.nan(f64)),\n", .{self.su.real});
    if (n_int != 0) try self.w("    i: [{d}]i64 = @splat(0),\n", .{n_int});
    try self.w("}};\n\n", .{});
}

/// §9.15 `$simparam`s `setup` reads, so a host knows which writes need a new
/// `setup` call. Collected while `emitSetup` plans its slice.
fn emitSimparams(self: *Gen) Error!void {
    var names: std.ArrayList([]const u8) = .empty;
    for (self.plan.live.items) |lv| {
        const def = self.mir.valueDef(lv);
        if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) continue;
        const d = self.mir.instData(def.inst_result).call;
        if (d.callee != .@"$simparam") continue;
        const nm = plan_args.strArg(self.input(), d.args, 0) orelse continue;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, nm)) break;
        } else try names.append(self.arena, nm);
    }
    try self.w(
        \\/// §9.15 the `$simparam` names `setup` reads: after writing one of them
        \\/// (a homotopy rung's gmin, say) the host calls `setup` again.
        \\pub const setup_simparams = [_][]const u8{{
    , .{});
    for (names.items, 0..) |n, k| try self.w("{s}\"{f}\"", .{ if (k == 0) " " else ", ", std.zig.fmtString(n) });
    try self.w("{s}}};\n\n", .{if (names.items.len == 0) "" else " "});
}

/// `pub fn setup`: the invariant slice, emitted through the same plan and
/// relooper as the core with the roots as its targets. Per-eval branches are
/// taken `then` without testing them (nothing on either arm is setup work,
/// and the §5.10.2 initial-step arm is exactly what setup must compute), and
/// the walk stops at the first loop that is not invariant — nothing after it
/// is placeable.
pub fn emitSetup(self: *Gen) Error!void {
    if (self.su.vals.len == 0) return;
    const save_idx = self.plan.lo_idx;
    const save_vals = self.plan.lo_vals;
    self.plan.lo_idx = self.su.idx;
    self.plan.lo_vals = self.su.vals;
    self.plan.su_on = false; // computing the roots, not reading them
    self.plan.setup_mode = true;
    self.plan.sinv = self.sinv.val;
    self.plan.display_unit = false;
    self.su.mode = true;
    self.emitting_common = true;
    defer {
        self.plan.lo_idx = save_idx;
        self.plan.lo_vals = save_vals;
        self.plan.su_on = true;
        self.plan.setup_mode = false;
        self.su.mode = false;
        self.emitting_common = false;
    }
    try self.plan.analyze(.undef, true);
    try emitSimparams(self);

    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = true;
    self.fatal = null;
    try self.w(
        \\/// Fill `inst.su`: once after `derive`, and again after every write to
        \\/// `Model`, to this instance or its temperature, or to a `$simparam`
        \\/// in `setup_simparams` — before `eval` or any other entry point runs.
        \\/// `V` is the host's VALUE scalar, with exactly the value semantics of
        \\/// the `S` it evaluates with (its Dual's value half), so every latched
        \\/// value is the bits `eval` would have computed. A §5.10.2
        \\/// `@(initial_step)` body the card alone determines is computed here
        \\/// as if the step were initial: the host evaluates an initial step
        \\/// before any other.
        \\
    , .{});
    try self.w("pub fn setup(comptime V: type, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, inst: *Instance) void {{\n", .{});
    try self.w("    @setFloatMode(.strict);\n    const S = V;\n", .{});
    self.float.strict = true;
    self.su.stop = false;
    const at_body = self.out.items.len;
    try gen_unit.emitUnitBody(self, .undef);
    try self.w("}}\n\n", .{});
    // A body of integer roots alone never names `S`, and an unused local is
    // a Zig error: then the scalar is discarded instead.
    var at_stop = at_body;
    if (!namesS(self.out.items[at_body..])) {
        const decl = "    const S = V;\n";
        const discard = "    _ = V;\n";
        std.debug.assert(std.mem.eql(u8, self.out.items[at_body - decl.len .. at_body], decl));
        try self.out.replaceRange(self.gpa, at_body - decl.len, decl.len, discard);
        at_stop = at_body - decl.len + discard.len;
    }
    // Declared only when a per-eval branch or loop used it: it is always
    // true, and a runtime value so the arm it guards still compiles.
    if (self.su.stop) try self.out.insertSlice(self.gpa, at_stop, "    var zs_stop = true;\n    _ = &zs_stop;\n");
    // Every root either folds or reads the card, so `model` is the rule; a
    // setup over `$temperature` alone is the exception.
    if (!self.uses_model) gen_unit.patchParam(self, at_model, "model".len);
    std.debug.assert(!self.uses_x);
    std.debug.assert(self.fatal == null);
}

/// Does emitted text use the identifier `S`?
fn namesS(text: []const u8) bool {
    for (text, 0..) |c, i| {
        if (c != 'S') continue;
        const before = i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        const after = i + 1 < text.len and (std.ascii.isAlphanumeric(text[i + 1]) or text[i + 1] == '_');
        if (!before and !after) return true;
    }
    return false;
}

/// `emitReturn` inside `setup`: store every root, from wherever the body
/// holds it, and leave — unconditionally at an exit block, on the runtime
/// `zs_stop` flag at a per-eval loop (`emitTree`).
pub fn emitStores(self: *Gen, depth: u32, stop: []const u8) Error!void {
    for (self.su.vals, 0..) |v, j| {
        const i = @intFromEnum(v);
        try self.ind(depth);
        if (self.an.vty[i] == .int) {
            try self.b("inst.su.i[{d}] = ", .{j - self.su.real});
            try gen_render.renderVal(self, v, .int);
            try self.b(";\n", .{});
        } else {
            try self.b("inst.su.r[{d}] = (", .{j});
            try gen_render.renderVal(self, v, .real);
            try self.b(").val();\n", .{});
        }
    }
    try self.ind(depth);
    try self.b("if (std.debug.runtime_safety) inst.su_ok = true;\n", .{});
    try self.ind(depth);
    try self.b("{s}return;\n", .{stop});
}
