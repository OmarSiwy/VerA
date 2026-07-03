//! Unit list and plans -> the device.zig skeleton: imports, kernel text, §1.3.1
//! `U`, §3.4 `Model`, §4.5 `Instance`, the host-facing tables and the contract
//! validation block, plus the unit-file prologue and `h.zig`.
//! LRM: §1.3.4.2, §3.4, §3.6.1.2, §4.5, §4.5.7, §4.5.12, §4.5.15, §5.4.2, §5.10,
//! §6.3.4, §9.10, §9.13.1.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_state = @import("state.zig");
const gen_unit = @import("unit.zig");
const gen_family = @import("family.zig");
const gen_setup = @import("setup.zig");
const opdb = @import("op_zig.zig");
const Analysis = @import("ir").Analysis;
const cg_filters = @import("../cg_filters.zig");
const cg_limit = @import("../cg_limit.zig");
const Lower = @import("ir").Lower;
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// `tools/contract.zig`'s `abi_version`, which `backend` cannot import. Every
/// testbench runs `validateHost`, which compares the two.
const contract_abi = 5;
const VTy = codegen.VTy;
const hist_len = codegen.hist_len;
const OpKind = @import("ir").op.OpKind;

// =======================================================================
// File assembly
// =======================================================================

/// The optional helper blocks a device carries. Each flag gates the same
/// block in device.zig, the unit prologue and `h.zig`.
const Features = struct {
    stateful: bool,
    hist: bool,
    /// `hist_quad_txt`: an `absdelay` under `(* vera_interp = 2 *)`.
    hist_quad: bool,
    filt: bool,
    /// `ac_txt`: an operator whose small-signal response depends on ω.
    ac: bool,
    timer: bool,
    strs: bool,
    tbl: bool,
    rng: bool,
    files: bool,
    arrs: bool,
    /// `tp_txt`: a VerA `vera_timepoint` statement.
    tp: bool,
};

/// Writes the whole device.zig into `self.out` and builds `self.prelude` and
/// `self.helpers`. Requires `Gen.prepare` to have run.
pub fn emitFile(self: *Gen) Error!void {
    const f: Features = .{
        .stateful = hasStatefulOps(self),
        .hist = usesOp(self, .absdelay),
        .hist_quad = usesQuad(self),
        .filt = usesOp(self, .laplace) or usesOp(self, .zi),
        .ac = usesOp(self, .absdelay) or usesOp(self, .laplace) or usesOp(self, .zi),
        .timer = usesOp(self, .timer),
        // §9.5.3/§9.5.4.2. Set at the call in lowering, because once the MIR
        // is sliced the formatter's call may sit in any unit. A printing
        // artifact needs the string kernels too: §9.4.3's real conversions
        // (Table 9-23, "the full formatting capabilities available in the C
        // language") are `zCReal`, which lives in the same file.
        .strs = self.lowered.uses.contains(.str_tasks) or self.display == .emit,
        // §9.21, set at the call for the same reason `strs` is: the lookup may
        // land in any unit once the MIR is sliced.
        .tbl = self.lowered.uses.contains(.table_model),
        // §9.13, set at the call for the same reason: `lowerRandom` runs long
        // before the MIR is sliced into units.
        .rng = self.lowered.uses.contains(.rng),
        // §9.5 the descriptor table. Only a `display == .emit` artifact has a
        // host that runs the per-point side-effect phase these kernels need.
        .files = self.display == .emit and self.lowered.uses.contains(.file_tasks),
        // §3.2.2 set in lowering: a runtime-indexed array is one storage.
        .arrs = self.lowered.mem_arrays.items.len != 0,
        .tp = self.lowered.timepoints.items.len != 0,
    };
    try buildPrelude(self, f);
    try self.out.appendSlice(self.gpa, kt.header_txt);
    try self.out.appendSlice(self.gpa, kt.math_txt);
    try self.out.appendSlice(self.gpa, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try self.out.appendSlice(self.gpa, kt.ops_txt);
    try self.out.appendSlice(self.gpa, kt.family_txt);
    try self.out.appendSlice(self.gpa, kt.family_dev_txt);
    if (f.timer) try depublish(self.gpa, &self.out, kt.timer_txt);
    if (f.hist) try self.out.appendSlice(self.gpa, kt.hist_txt);
    if (f.hist_quad) try self.out.appendSlice(self.gpa, kt.hist_quad_txt);
    if (f.arrs) try self.out.appendSlice(self.gpa, kt.arr_txt);
    if (f.tp) try self.out.appendSlice(self.gpa, kt.tp_txt);
    // The embedded kernel files arrive already `pub`, which is right for
    // `h.zig` and wrong here: `contract.rejectStrayPubDecls` allows only
    // contract-recognized public names. So they are depublished; every other
    // helper block is written private and made public by `publish`.
    if (f.filt) try depublish(self.gpa, &self.out, kt.filt_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, kt.ac_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, kt.ac_fam_txt);
    // §9.4.3's padding helper serves §9.5.3 too (`$sformat` is the same
    // formatter), so a device that never prints still needs it to format.
    if (f.strs) try self.out.appendSlice(self.gpa, kt.display_txt);
    if (f.strs) try depublish(self.gpa, &self.out, kt.str_txt);
    if (f.files) try depublish(self.gpa, &self.out, kt.file_txt);
    // §9.5.1.2 the same table, public for a host's second context to share
    // (`contract.FileIo`, optional: a host that runs one context ignores it).
    if (f.files) try self.out.appendSlice(self.gpa, "pub const file_io: contract.FileIo = .{ .open = zFOpen, .close = zFClose, .put = zFPut, .getc = zFGetc, .ungetc = zFUngetc, .tell = zFTell, .seek = zFSeek, .eof = zFEof, .err = zFError, .new_analysis = zFNewAnalysis };\n\n");
    if (f.tbl) try depublish(self.gpa, &self.out, kt.table_txt);
    if (f.rng) try depublish(self.gpa, &self.out, kt.rng_txt);
    if (self.limits.calls.len != 0) try depublish(self.gpa, &self.out, kt.limit_txt);
    if (self.lowered.uses.contains(.plusargs)) try self.out.appendSlice(self.gpa, plusarg_txt);
    try self.out.appendSlice(self.gpa, "\n");
    // `emitSwitchRow` splits exactly these branches; `prepare` planned them
    // (`plan/topology.zig`) before any residual is emitted.
    const cpairs = self.topo.cpairs;

    try emitTopology(self);
    try emitModel(self);
    try emitDerive(self);
    try emitShapeCheck(self);
    try gen_setup.emitSetupDecl(self);
    try emitInstance(self);
    try self.w("const InstancePtr = contract.InstancePtr(@This());\n", .{});
    // VerA's `vera_timepoint` (§2.9): `eval` fills the per-timepoint caches.
    if (self.lowered.table_samples.items.len != 0 or self.lowered.timepoints.items.len != 0) try self.w("pub const mutable_eval = true;\n", .{});
    try gen_setup.emitSetup(self);
    try gen_unit.emitUnits(self);
    try gen_dispatch.emitDispatchers(self);
    try gen_dispatch.emitNoiseTable(self);
    try gen_dispatch.emitAcTable(self);
    try gen_call.emitSystfTable(self);
    // §4.5.2's accepted-step sweep also carries §9.13.1's internal-seed
    // advance, the only place a stream may move: a per-iteration draw makes
    // the residual non-deterministic and Newton never converges.
    if (f.stateful or self.lowered.rng_auto_seeds.items.len != 0 or pathLatches(self)) try gen_state.emitStateMachine(self);
    try cg_limit.emit(self);
    try gen_state.emitCollapse(self, cpairs);
    try gen_state.emitNextBreakpoint(self);
    try gen_state.emitDelays(self);
    try gen_dispatch.emitDerivReads(self, if (self.limits.calls.len != 0) cg_limit.liveSets(self).writes else 0);
    const k = try gen_family.constant(self);
    if (k.g or k.c) try self.w(
        \\/// ∂eval/∂x (`g`) and ∂q/∂x (`c`) do not depend on x: a host may build
        \\/// those stamps once per card and instance (`contract.Constant`).
        \\pub const constant: contract.Constant = .{{ .g = {}, .c = {} }};
        \\
        \\
    , .{ k.g, k.c });
    // Lane-parallel permission (see `float/lanes.zig`): eval/q of this device
    // instantiated with a vector S is exact per lane. The testbench's
    // batch differential check keys on it, and a batching host may.
    // ponytail: a `vera_timepoint` cache stores one point's values, so a
    // device with one is not batched; store lane 0 when a host batches it.
    if (!self.float.pinned and self.lowered.timepoints.items.len == 0) try self.w("pub const batch_ok = true;\n\n", .{});
    try self.w("comptime {{\n    contract.validate(Self);\n}}\n", .{});
}

/// Builds `Output.prelude` (the file-scope prologue of a `u/<key>.zig`) and
/// `Output.helpers` (`h.zig`). Unit files alias the helpers rather than
/// re-emitting them, so `zig` analyses each once. The aliases are gated on the
/// same `Features` `emitFile` uses, so none names a missing decl.
fn buildPrelude(self: *Gen, f: Features) Error!void {
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(self.arena, kt.prelude_head_txt);
    const alias = kt.appendAliases;
    try alias(&p, self.arena, kt.math_txt);
    try alias(&p, self.arena, kt.ops_txt);
    try alias(&p, self.arena, kt.family_txt);
    if (f.timer) try alias(&p, self.arena, kt.timer_txt);
    if (f.hist) try alias(&p, self.arena, kt.hist_txt);
    if (f.hist_quad) try alias(&p, self.arena, kt.hist_quad_txt);
    if (f.arrs) try alias(&p, self.arena, kt.arr_txt);
    if (f.tp) try alias(&p, self.arena, kt.tp_txt);
    if (f.filt) try alias(&p, self.arena, kt.filt_txt);
    if (f.ac) try alias(&p, self.arena, kt.ac_txt);
    if (self.display == .emit or f.strs) try alias(&p, self.arena, kt.display_txt);
    if (f.strs) try alias(&p, self.arena, kt.str_txt);
    if (f.files) try alias(&p, self.arena, kt.file_txt);
    if (f.tbl) try alias(&p, self.arena, kt.table_txt);
    if (f.rng) try alias(&p, self.arena, kt.rng_txt);
    // The shared core is a unit file beside the units that call it, and
    // device.zig's alias for it is private. Spelled `core`, not the structural
    // key, so the core's own file (same prologue) does not redeclare its name;
    // a file importing itself is legal and, unreferenced, never analysed.
    if (self.core.name.len != 0)
        try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.core.name});
    try p.appendSlice(self.arena, "\n");
    self.prelude = p.items;

    var hz: std.ArrayList(u8) = .empty;
    try hz.appendSlice(self.arena, kt.helpers_head_txt);
    try publish(self.arena, &hz, kt.math_txt);
    try publish(self.arena, &hz, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try publish(self.arena, &hz, kt.ops_txt);
    try hz.appendSlice(self.arena, "const zdr = contract.derivReads(@import(\"device.zig\"));\n");
    try publish(self.arena, &hz, kt.family_txt);
    if (f.timer) try publish(self.arena, &hz, kt.timer_txt);
    if (f.hist) try publish(self.arena, &hz, kt.hist_txt);
    if (f.hist_quad) try publish(self.arena, &hz, kt.hist_quad_txt);
    if (f.arrs) try publish(self.arena, &hz, kt.arr_txt);
    if (f.tp) try publish(self.arena, &hz, kt.tp_txt);
    if (f.filt) try publish(self.arena, &hz, kt.filt_txt);
    if (f.ac) try publish(self.arena, &hz, kt.ac_txt);
    if (self.display == .emit or f.strs) try publish(self.arena, &hz, kt.display_txt);
    if (f.strs) try publish(self.arena, &hz, kt.str_txt);
    if (f.files) try publish(self.arena, &hz, kt.file_txt);
    if (f.tbl) try publish(self.arena, &hz, kt.table_txt);
    if (f.rng) try publish(self.arena, &hz, kt.rng_txt);
    self.helpers = hz.items;
}

/// Copies `src` into `out` with each leading `pub ` dropped, so an embedded
/// Zig file can be spliced into device.zig. The inverse of `publish`.
fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
    }
}

/// Copies `src` into `out`, making each top-level `fn`/`const` public. The
/// same text is private in device.zig, where the contract forbids stray
/// public names, and public in `h.zig`, where the unit files reach it.
fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "const "))
            try out.appendSlice(arena, "pub ");
        try out.appendSlice(arena, line);
    }
}

/// Records the unit declaration `name` spanning `lo` to the current end of
/// `self.out`, with its keyword at `fn_at`. Asserts `lo` is the previous
/// range's end: the ranges tile (`Output`'s invariant).
pub fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
    if (self.file_hi.items.len != 0)
        assert(self.file_hi.items[self.file_hi.items.len - 1] == lo);
    try self.file_names.append(self.arena, name);
    try self.file_lo.append(self.arena, @intCast(lo));
    try self.file_fn.append(self.arena, @intCast(fn_at));
    try self.file_hi.append(self.arena, @intCast(self.out.items.len));
}

/// Returns whether the model needs the §4.5.2 accepted-step machinery: a
/// stateful operator, a §5.10 held variable or a `$limit` slot. Each keeps
/// state in `Instance` that only `updateState` may advance.
pub fn hasStatefulOps(self: *const Gen) bool {
    if (self.lowered.held_vars.items.len != 0 or self.lowered.limit_slots.items.len != 0) return true;
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op != .none) return true;
    }
    return false;
}

/// Returns whether any unit is a call to analog operator `k`.
pub fn usesOp(self: *const Gen, k: OpKind) bool {
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op == k) return true;
    }
    return false;
}

fn usesQuad(self: *const Gen) bool {
    for (self.names.units) |u| {
        if (u.role == .analog_op and self.mir.instData(u.inst).call.callee == .@"absdelay$quad") return true;
    }
    return false;
}

/// Emits `U`, the solver unknowns (§1.3.1 nodes, §6.5 ports first, so the
/// host's terminal order is the module header order), and the per-unknown
/// tables. `x[i]` in every emitted body indexes this enum.
/// Fails with `error.TooManyUnknowns` (E1003) above 256 unknowns.
pub fn emitTopology(self: *Gen) Error!void {
    // A 257th member would fail in the host's build at a line of generated
    // Zig, naming no .va. Refuse here, where the model is still in hand.
    //
    // ponytail: |U| <= 256 is a permanent ceiling. `enum(u16)` is the upgrade
    // path and an ABI break: `isDenseEnum` (tools/contract.zig) requires the
    // `u8` tag, so both move together and every host recompiles.
    if (self.names.u_names.len > 256) {
        if (self.diags) |bag| try bag.add(
            .codegen,
            .E1003,
            .{},
            "this module needs {d} solver unknowns; the emitted `U` is an enum(u8) and holds 256",
            .{self.names.u_names.len},
        );
        return error.TooManyUnknowns;
    }
    try self.w("/// Solver unknowns: §6.5 ports first, then §3.6.3 internal nets,\n", .{});
    try self.w("/// then §5.4.2 branch-flow unknowns.\n", .{});
    try self.w("pub const U = enum(u8) {{\n", .{});
    for (self.names.u_names, 0..) |n, i| {
        const kindc: []const u8 = if (i < self.lowered.num_ports)
            "port"
        else if (plan_topo.isFlowUnknown(self.input(), @intCast(i)))
            "branch flow"
        else if (i < self.lowered.nodes.len and self.lowered.nodes.items(.kind)[i] == .op_state)
            "§4.5.2 operator unknown"
        else
            "internal";
        try self.w("    {s}, // {s}\n", .{ n, kindc });
    }
    try self.w("}};\n\npub const num_ports: usize = {d};\nconst n_u = contract.nU(Self);\n\n", .{self.lowered.num_ports});
    try self.w("/// The contract ABI this device was generated for (`contract.abi_version`).\npub const contract_abi: u32 = {d};\n\n", .{contract_abi});

    if (self.float.jac != .off) try self.w(
        \\/// This device permits a single-precision DERIVATIVE half in the
        \\/// host's scalar S. The residual stays f64 — see `--jac-f32`.
        \\/// Permission, not order: a host may take it on one instantiation
        \\/// (its GPU kernel) and decline it on another (its CPU path).
        \\pub const jac_f32 = true;
        \\
        \\
    , .{});
    if (self.float.jac == .host) try self.w(
        \\/// ...and the host should take that permission on its CPU path too,
        \\/// not only where f32 is free. See `--jac-f32-host`.
        \\pub const jac_f32_host = true;
        \\
        \\
    , .{});

    var any_current = false;
    for (0..self.names.n_u) |i| {
        if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) any_current = true;
    }
    if (any_current) {
        try self.w("pub const u_kinds = [n_u]contract.UnknownKind{{\n", .{});
        for (0..self.names.n_u) |i| {
            try self.w("    .{s},\n", .{if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) "current" else "voltage"});
        }
        try self.w("}};\n\n", .{});
    }
    // §3.6.1.2 the tolerance the discipline settled on for each unknown. A
    // host needs the absolute half of its stopping test per unknown and
    // cannot derive it: "negligible" differs per nature, and §3.6.2.3 lets a
    // discipline override the nature's number.
    try self.w("/// §3.6.1.2 `abstol` per unknown: the largest value of this\n", .{});
    try self.w("/// quantity a host may treat as zero, after any §3.6.2.3 override.\n", .{});
    try self.w("pub const u_abstol = [n_u]f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        try self.w("    {d},\n", .{abstolOf(self, @intCast(i))});
    }
    try self.w("}};\n\n", .{});
    try emitNodesets(self);
}

/// Emits `u_nodeset`, the §3.6.3.2 net discipline initial values as one
/// optional table over `U`: a number per unknown only the declaration knows
/// and only the host's solver can use. Emitted only when the module declares
/// one, so its absence means "no opinion". `?f64` because "a null value ...
/// indicates that no nodeset value is being specified" and zero is an
/// ordinary nodeset; a §5.4.2 branch flow is always null.
fn emitNodesets(self: *Gen) Error!void {
    if (self.lowered.nodesets.items.len == 0) return;
    try self.w("/// §3.6.3.2 nodeset: the initial guess the source states for each\n", .{});
    try self.w("/// unknown's potential. A HINT to the solver — not an initial\n", .{});
    try self.w("/// condition and not a clamp; the solved answer is unchanged by it.\n", .{});
    try self.w("pub const u_nodeset = [n_u]?f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        // §3.6.3.2: "If different nets of a node have conflicting
        // initializers ... it is a race condition for which the initializer
        // wins." Last wins here, which the clause permits.
        var v: ?f64 = null;
        for (self.lowered.nodesets.items) |ns| {
            if (ns.node == i) v = ns.value;
        }
        if (v) |x| try self.w("    {s},\n", .{try fmtF64(self, x)}) else try self.w("    null,\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// Returns the §3.6.1.2 `abstol` of the nature this unknown's quantity
/// belongs to, after §3.6.2.3's per-discipline override (so it reads
/// `DisciplineInfo`, not the nature table). A §5.4.2 branch flow takes the
/// discipline at its high node (`Lower.NodeKind`'s payload). A net with no
/// discipline (a §3.5 implicit net without `default_discipline`) falls back to
/// annex D's `VOLTAGE_ABSTOL` 1e-6 / `CURRENT_ABSTOL` 1e-12.
/// A shared potential node uses §7.2.4's minimum across its signal segments.
pub fn abstolOf(self: *const Gen, i: u32) f64 {
    const flow = plan_topo.isFlowUnknown(self.input(), i);
    var idx: u16 = @intCast(i);
    if (i < self.lowered.nodes.len) switch (self.lowered.nodes.items(.kind)[i]) {
        .net => {},
        .branch_flow, .port_flow => |n| idx = n,
        .op_state => |t| return t,
    };
    if (idx == Lower.ground or idx >= self.lowered.nodes.len)
        return if (flow) 1e-12 else 1e-6;
    if (!flow) if (self.lowered.nodes.items(.potential_abstol)[idx]) |abstol| return abstol;
    const info = self.lowered.disciplines.get(self.lowered.nodes.items(.disc)[idx]) orelse
        return if (flow) 1e-12 else 1e-6;
    return if (flow) info.flow_abstol else info.potential_abstol;
}

/// Emits `Model`: one typed field per §3.4 parameter, initialized to its
/// folded spec default, plus alias, `tnom` and retention-flag fields.
fn emitModel(self: *Gen) Error!void {
    try self.w("/// §3.4 module parameters (spec defaults folded at compile time).\npub const Model = struct {{\n", .{});
    for (self.lowered.params.items, 0..) |p, i| {
        const ty: []const u8 = switch (Analysis.tyOfParam(p.ty)) {
            .real => "f64",
            .int => "i64",
            .str => "[]const u8",
        };
        try checkParamDefault(self, p);
        try self.w("    {s}: {s} = {s},\n", .{ self.names.p_names[i], ty, try paramDefault(self, p, Analysis.tyOfParam(p.ty)) });
        if (self.names.p_given[i]) {
            try self.w("    {s}__given: bool = false, // §9.19 $param_given\n", .{self.names.p_names[i]});
        }
    }
    // §3.4.7 aliasparam: "The aliasparam declaration creates an alternate
    // name ... which can be used to override the value of the parameter", so
    // the alias is part of the model card. It is a second field because Zig
    // has no field aliases; `derive` folds it back onto the original.
    // The `__given` flag is unconditional: it is the only way to tell "the
    // host overrode the alias" from "the host left it at the default".
    for (self.lowered.aliases.items, 0..) |al, i| {
        const p = self.lowered.params.items[al.param];
        const ty = Analysis.tyOfParam(p.ty);
        try self.w("    {s}: {s} = {s}, // §3.4.7 alias of `{s}`\n", .{
            self.names.a_names[i],
            switch (ty) {
                .real => "f64",
                .int => "i64",
                .str => "[]const u8",
            },
            try paramDefault(self, p, ty),
            p.name,
        });
        try self.w("    {s}__given: bool = false,\n", .{self.names.a_names[i]});
    }
    // §9.15 the host-published simulation parameters. Model, not Instance:
    // each `.options` entry is one number per run. The initializer is the
    // default, for a host that never writes it.
    var host_simparam = false;
    for (Lower.host_simparams) |h| if (self.lowered.uses.contains(h.use)) {
        host_simparam = true;
        try self.w("    {s}: f64 = {s}, // §9.15 $simparam(\"{s}\"){s} — host-written\n", .{
            h.field, try fmtF64(self, self.lowered.simparamValue(h.name).?), h.name, if (h.use == .host_tnom) ", degC" else "",
        });
    };
    // §5.6.5 the card-only retention flag of each collapsible switch branch,
    // which a guarded `jac_const` entry names (`contract.JacWhen`). Not a
    // parameter: `derive` overwrites it. The initializer is the flag at the
    // declared defaults when that folds, else NaN, so a host that skips
    // `derive` does not get a plausible 0.
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const d = if (self.an.foldConst(p.flag, true)) |f| try fmtF64(self, f.f) else "std.math.nan(f64)";
        try self.w("    {s}: f64 = {s}, // §5.6.5 retention flag — `derive` writes it\n", .{ try gen_dispatch.guardField(self, @intCast(k)), d });
    }
    if (self.lowered.params.items.len == 0 and !host_simparam) {
        try self.w("    // (the module declares no parameters)\n    _unused: u8 = 0,\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// Emits `derive`, which recomputes every parameter whose value is not its
/// own (§6.3.4: "an update of gate_width ... automatically updates
/// gate_cap"). The host writes the model card, calls `derive`, then builds
/// instances. It rewrites a parameter whose default names another parameter
/// unless the host wrote it, and every §3.4.5 localparam unconditionally
/// ("shall not be directly modified"). Declaration order is dependency order
/// (a forward reference is E0314), so one pass suffices. `Model{}` is already
/// the spec default, so a host that overrides nothing need not call it.
pub fn emitDerive(self: *Gen) Error!void {
    const at = self.out.items.len;
    try self.w(
        \\/// §6.3.4 parameter dependence + §3.4.5 localparam. Call ONCE after
        \\/// writing the model card and before the first solve: the fields below
        \\/// are defined by expressions over other parameters, so they are not
        \\/// valid until the parameters they read have their final values.
        \\pub fn derive(comptime S: type, model: *Model) void {{
        \\
    , .{});
    const at_s = self.out.items.len - "S: type, model: *Model) void {\n".len;
    const body = self.out.items.len;
    // §3.4.7 first: an override written through the alias must be the
    // original's value before a §6.3.4 dependent parameter reads it.
    for (self.lowered.aliases.items, 0..) |al, i| {
        try self.w("    if (model.{s}__given) model.{s} = model.{s};\n", .{
            self.names.a_names[i], self.names.p_names[al.param], self.names.a_names[i],
        });
    }
    for (self.lowered.params.items, 0..) |p, i| {
        const ty = Analysis.tyOfParam(p.ty);
        // A string parameter has no arithmetic to redo; a string localparam
        // is left overridable rather than growing a second renderer for it.
        if (ty == .str) continue;
        // `resolve_params = false`: this folds only if the default is
        // self-contained, which is exactly "not derived from a parameter".
        if (self.an.foldConst(p.default, false) != null and !p.is_local) continue;
        // Render in the parameter's numeric domain. A known initializer
        // cannot stand in for a dependency that changes after a host write.
        const e = (if (ty == .int) try gen_call.i64Const(self, p.default, 0) else try gen_call.f64Const(self, p.default, 0, false)) orelse {
            // Defaults with no compile-time value retain W1050's explicit
            // host-supplied-value contract (for example $simparam("gmin")).
            if (!p.is_local and p.folded == null and self.an.foldConst(p.default, true) == null) continue;
            if (self.diags) |bag| try bag.add(.codegen, .E1004, self.lowered.tokenSpan(p.tok), "host derivation of `{s}` uses an unsupported expression; its declared value cannot be frozen after parameter overrides", .{p.name});
            return error.UnsupportedParameterDefault;
        };
        // §6.3.4 gives the default; an explicit host write wins (else a card's
        // `VTH0` over `VTH0 = VTHO` would be erased). Only a localparam is
        // overwritten unconditionally. `initGiven` raised the `__given`
        // companion for every non-local derived parameter.
        if (!p.is_local)
            try self.w("    if (!model.{s}__given) ", .{self.names.p_names[i]})
        else
            try self.w("    ", .{});
        switch (ty) {
            .real => try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .int => if (p.integer32)
                try self.w("model.{s} = @as(i32, @truncate({s}));\n", .{ self.names.p_names[i], e })
            else
                try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .str => unreachable,
        }
    }
    if (!try deriveFlags(self)) gen_unit.patchParam(self, at_s, "S".len);
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("}}\n\n", .{});
}

/// Emits `checkShape`, which names the first shape parameter
/// (`ParamInfo.shape`, §3.2/§3.4) whose card value differs from the compiled
/// one, or returns null when the card fits. An array bound is laid out in the
/// generated text at compile time, so a card that moves it must be refused.
/// The host calls it after `derive`. No allocation or print, so it is safe in
/// a GPU build. Not emitted when no parameter shapes anything.
fn emitShapeCheck(self: *Gen) Error!void {
    const at = self.out.items.len;
    try self.w(
        \\/// §3.4 the shape parameters this device was compiled for: the name of
        \\/// the first one the card (after `derive`) sets to another value, or null.
        \\pub fn checkShape(model: *const Model) ?[]const u8 {{
        \\
    , .{});
    const body = self.out.items.len;
    for (self.lowered.params.items, 0..) |p, i| {
        if (!p.shape) continue;
        const ty = Analysis.tyOfParam(p.ty);
        if (ty == .str) {
            try self.w("    if (!std.mem.eql(u8, model.{s}, {s})) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) });
            continue;
        }
        // `derive` rewrites a localparam from its default; one that reads no
        // parameter is that constant every time and cannot disagree.
        if (p.is_local and self.an.foldConst(p.default, false) != null) continue;
        // §3.4.1 gives an explicit integer its low 32 bits even when the host
        // writes a wider carrier. Compare the value used by selection.
        if (ty == .int and p.integer32)
            try self.w("    if (@as(i32, @truncate(model.{s})) != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) })
        else
            try self.w("    if (model.{s} != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) });
    }
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("    return null;\n}}\n\n", .{});
}

/// Emits `derive`'s §5.6.5 tail: every card-only retention flag into the
/// `Model` field `emitModel` declared for it, read from the core at x = 0 on a
/// scratch Instance (exact, since a card-only flag reads neither). Must follow
/// the parameter writes it reads. Returns whether it read the core, i.e. named `S`.
fn deriveFlags(self: *Gen) Error!bool {
    var any = false;
    for (self.topo.cpairs) |p| any = any or p.card;
    if (!any) return false;
    try self.w(
        \\    // §5.6.5 the published retention flags (`contract.JacWhen`).
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    var pin: Instance = .{{}};
        \\
    , .{});
    if (self.su.vals.len != 0) try self.w("    setup(S, model, &pin);\n", .{}) else try self.w("    _ = &pin;\n", .{});
    try self.w("    const m = core(S, xr, model, &pin, .{{}}{s});\n", .{self.heldArg(true)});
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const f = self.core.lo_idx[@intFromEnum(self.an.rv(p.flag))];
        if (self.an.vty[@intFromEnum(self.an.rv(p.flag))] == .int)
            try self.w("    model.{s} = @floatFromInt(m.f{d});\n", .{ try gen_dispatch.guardField(self, @intCast(k)), f })
        else
            try self.w("    model.{s} = m.f{d}.val();\n", .{ try gen_dispatch.guardField(self, @intCast(k)), f });
    }
    return true;
}

/// Warns W1050 for a parameter whose default nothing in the pipeline
/// evaluates: neither fold in `paramDefault` answers and `derive` cannot
/// render it (a ch9 call such as §9.10 `$temperature` or §9.18 `$simparam`,
/// which is not a §3.4.1 constant_expression). The field's `0` is then the
/// host's to overwrite. A warning, not a refusal, so a model whose default
/// reads a simulator quantity still compiles; `--deny=W1050` makes it strict.
fn checkParamDefault(self: *Gen, p: Lower.ParamInfo) Error!void {
    const bag = self.diags orelse return;
    if (!bag.enabled(.W1050)) return;
    if (p.folded != null or self.an.foldConst(p.default, true) != null) return;
    if (try gen_call.f64Const(self, p.default, 0, false) != null) return;
    var d = bag.build(.codegen, .W1050, self.lowered.tokenSpan(p.tok));
    d.msg("`{s}`", .{p.name});
    d.point("this default has no compile-time value, so the field is 0", .{});
    d.help("write the model card field before the first solve, or give `{s}` a constant default", .{p.name});
    try d.emit();
}

/// Returns the §3.4 field initializer: the parameter's value under the
/// declared defaults, which is what `Model{}` promises. Two folds answer it:
/// `ParamInfo.folded` (`Lower.constEval` over the AST, which sees through a
/// §4.2.12 `?:` that MIR has already turned into a CFG diamond) and
/// `foldConst` over the MIR. Integral defaults prefer the exact AST result.
pub fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
    if (want == .int) if (p.folded) |k| {
        const value = switch (k) {
            .int => |v| v,
            .real => |v| std.math.lossyCast(i64, @round(v)),
            .str => 0,
        };
        return std.fmt.allocPrint(self.arena, "{d}", .{if (p.integer32 and k == .int) Lower.wrap32(value) else value});
    };
    const c = self.an.foldConst(p.default, true);
    if (c == null) if (p.folded) |k| return switch (want) {
        .real => try fmtF64(self, k.asReal()),
        // From the i64 side: `folded` kept the integer, so nothing is rounded.
        // A real default on an integer parameter takes the same saturating
        // cast as the fold path below, because `Lower.Const.asInt` casts
        // unguarded.
        .int => try std.fmt.allocPrint(self.arena, "{d}", .{switch (k) {
            .real => |r| std.math.lossyCast(i64, @round(r)),
            .int, .str => k.asInt(),
        }}),
        .str => switch (k) {
            .str => |s| try std.fmt.allocPrint(self.arena, "\"{f}\"", .{std.zig.fmtString(s)}),
            else => "\"\"",
        },
    };
    return switch (want) {
        .real => try fmtF64(self, if (c) |k| k.f else 0.0),
        // ponytail: `parameter integer big = 1e300;` saturates (`lossyCast`:
        // clamp to i64, NaN -> 0) instead of panicking the compiler. §4.2.1.1
        // fixes no overflow rule. The field, the fold (`Analysis.asI64`) and
        // the runtime `fi_cast` all saturate alike, so they agree. Upgrade
        // path: a lowering-time diagnostic on the default's span.
        .int => try std.fmt.allocPrint(self.arena, "{d}", .{if (c) |k| std.math.lossyCast(i64, @round(k.f)) else 0}),
        .str => blk: {
            const def = self.mir.valueDef(self.an.rv(p.default));
            break :blk if (def == .str_const)
                try std.fmt.allocPrint(self.arena, "\"{f}\"", .{std.zig.fmtString(def.str_const)})
            else
                "\"\"";
        },
    };
}

/// Returns the Zig text of a float constant, memoized on its bit pattern.
/// Large models emit hundreds of thousands of constants with few distinct
/// texts. Keyed on `@bitCast`, not the `f64`: `-0.0` and `0.0` compare equal
/// but render differently, and NaN is not equal to itself. The text is
/// arena-owned and shared between calls.
pub fn fmtF64(self: *Gen, x: f64) Error![]const u8 {
    if (std.math.isNan(x)) return "std.math.nan(f64)";
    if (std.math.isInf(x)) return if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)";
    const gop = try self.f64_cache.getOrPut(self.arena, @bitCast(x));
    if (gop.found_existing) return gop.value_ptr.*;
    // Render on the stack, then copy the survivor. `{d}` on an f64 is at
    // most ~24 bytes.
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
    // ponytail: use the stdlib byte-set search; formatting stays unchanged.
    const has_point = std.mem.indexOfAny(u8, s, ".eE") != null;
    gop.value_ptr.* = if (has_point)
        try self.arena.dupe(u8, s)
    else
        try std.fmt.allocPrint(self.arena, "{s}.0", .{s});
    return gop.value_ptr.*;
}

/// §9.12 / IEEE 1364 §17.10.1/§17.10.2: the plusargs "are searched in the
/// order provided", and a match is a plusarg whose prefix "matches all
/// characters in the provided string". `fmt` cuts `$value$plusargs`'s
/// user_string at its format. The match comes back without its `+`, and
/// `$sscanf` then reads it against the whole user_string (an empty remainder
/// scans as 0 or "", §17.10.2's own answer).
const plusarg_txt =
    \\fn zPlusarg(args: []const [:0]const u8, want: []const u8, fmt: bool) ?[]const u8 {
    \\    const key = if (fmt) want[0 .. std.mem.indexOfScalar(u8, want, '%') orelse want.len] else want;
    \\    for (args) |a| if (a.len != 0 and a[0] == '+' and std.mem.startsWith(u8, a[1..], key)) return a[1..];
    \\    return null;
    \\}
    \\
;

/// Emits `Instance`: environment (§9.10) plus one field group per stateful
/// §4.5 operator, keyed by the stable unit name so adding an unrelated
/// operator never renumbers existing state.
pub fn emitInstance(self: *Gen) Error!void {
    try self.w(
        \\/// Per-instance state. The host owns every field above the operator
        \\/// block: `temperature` in kelvin (§9.10) and `mfactor` (§6.3.6). Time,
        \\/// step and analysis reach every entry point as `contract.SimState`.
        \\pub const Instance = struct {{
        \\    temperature: f64 = 300.15,
        \\    mfactor: f64 = 1.0,
        \\    /// §9.17.2 `$bound_step`: upper bound the model asks for on the
        \\    /// NEXT timestep, in seconds. `inf` = unconstrained. Written by
        \\    /// `updateState`; the host reads it after every accepted step and
        \\    /// shall ignore it outside a time-domain analysis (§9.17.2).
        \\    bound_step: f64 = std.math.inf(f64),
        \\    /// §9.17.1 `$discontinuity`: degree of the announced
        \\    /// discontinuity (0 = the equation itself, 1 = its slope, …), or
        \\    /// -1 for "none announced this step". Written by `updateState`.
        \\    discontinuity_order: i32 = -1,
        \\    /// §2.8.3/§12.32 the VPI application. Read only by a `$name`
        \\    /// this compiler could not resolve; `contract.validateHost`
        \\    /// is what keeps it non-null when `systf_calls` is not empty.
        \\    systf: ?*const contract.SystfHost = null,
        \\
    , .{});
    try self.hist.appendSlice(self.arena, &.{ "bound_step", "discontinuity_order" });
    // §9.12 / IEEE 1364 §17.10: only a model that searches the plusargs has
    // somewhere for the host to write them.
    if (self.lowered.uses.contains(.plusargs)) try self.w(
        "    /// §9.12 the invocation's command-line arguments, in supplied order,\n" ++
            "    /// written by the host. Entries not starting with `+` are skipped.\n" ++
            "    plusargs: []const [:0]const u8 = &.{{}},\n",
        .{},
    );
    for (self.lowered.table_samples.items, 0..) |count, site| {
        try self.w("    table_{d}: [{d}]f64 = @splat(0.0),\n", .{ site, count });
    }
    if (self.lowered.table_samples.items.len != 0) try self.w("    // §9.21.1 permanent first-call state; not timestep rollback state.\n    table_ready: [{d}]bool = @splat(false),\n", .{self.lowered.table_samples.items.len});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "    limiter_previous: [{d}]f64 = @splat(0.0),\n",
        .{self.lowered.limit_slots.items.len},
    );
    // §9.13.1's "internal seed", one slot per seedless call site. The default
    // is a fixed value, not a clock read, so a run is reproducible and
    // §9.13.2's "shall always return the same value given the same seed" can
    // be checked. Distinct per site: the internal seed "gets updated every
    // time the call ... is made", so two call sites are two streams.
    if (self.lowered.rng_auto_seeds.items.len != 0) {
        try self.w(
            "    /// §9.13.1 the internal seed of each seedless `$random`/`$arandom`\n" ++
                "    /// call site. Advanced by `updateState` on the ACCEPTED step and only\n" ++
                "    /// READ by `eval`: a draw that moved between Newton iterations would\n" ++
                "    /// make the residual non-deterministic and the solve would not converge.\n" ++
                "    rng_auto: [{d}]i64 = .{{",
            .{self.lowered.rng_auto_seeds.items.len},
        );
        for (self.lowered.rng_auto_seeds.items, 0..) |seed, k| try self.w("{s}{d}", .{
            if (k == 0) "" else ", ", seed,
        });
        try self.w("}},\n", .{});
        try self.hist.append(self.arena, "rng_auto");
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const n = self.names.unit_names[i];
        // Operators whose Instance shape is fixed are a table read (op_zig.zig).
        for (opdb.get(u.op).slots) |s| {
            if (s.note.len == 0) {
                try self.w("    {s}__{s}: f64 = {s},\n", .{ n, s.suffix, s.default });
            } else {
                try self.w("    {s}__{s}: f64 = {s}, // {s}\n", .{ n, s.suffix, s.default, s.note });
            }
            try keepHist(self, "{s}__{s}", .{ n, s.suffix });
        }
        // Operators whose field count depends on the call (`shape = .from_args`).
        switch (u.op) {
            .absdelay => {
                try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u64 = 0,\n",
                    .{ n, hist_len, n, hist_len, n },
                );
                // The ring itself is not copied: `stateCtl` keeps the one
                // sample the next push overwrites (`emitStateCtl`).
                try keepHist(self, "{s}__head", .{n});
                // §4.5.7 the frozen td of the two-argument form. Emitted only
                // for a signal-valued td; a constant or parameter one is
                // already its own first value.
                if (try gen_call.absdelayFreezes(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__td: f64 = 0.0, // §4.5.7 td, frozen at the first evaluation\n", .{n});
                    try keepHist(self, "{s}__td", .{n});
                }
                if (try gen_call.absdelayMaxdSampled(self, self.names.opArgs(self.mir, i))) {
                    try self.w("    {s}__maxd: f64 = 0.0, // §4.5.14 maxdelay, sampled at the start of the analysis\n", .{n});
                    try keepHist(self, "{s}__maxd", .{n});
                }
            },
            // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
            // past inputs and past outputs per section, newest first. The
            // shape comes from the flattened call, so it is a codegen-time
            // constant even though every coefficient is a runtime Model read.
            .laplace, .zi => {
                if (self.names.opInstOf(@intCast(i)) == null) continue;
                const p = cg_filters.planOf(self, i);
                if (p.err != null) continue;
                try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                    n, p.ns * p.deg, if (u.op == .zi) "12" else "11",
                });
                try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                try keepHist(self, "{s}__u", .{n});
                try keepHist(self, "{s}__y", .{n});
                // §4.5.12 the filter's clock as a count of samples taken, not
                // the next sample time: `next += zn*T` drifts off the k·T grid
                // by an ulp or two (1e-9 + 1e-9 + 1e-9 > 3e-9 in f64), and a
                // timepoint under the drifted clock loses a sample for good.
                if (u.op == .zi) {
                    try self.w("    {s}__nk: f64 = 0.0, // §4.5.12 samples taken\n    {s}__out: f64 = 0.0,\n", .{ n, n });
                    try keepHist(self, "{s}__nk", .{n});
                    try keepHist(self, "{s}__out", .{n});
                }
            },
            // Every `.static` and `.none` row: already handled above, or
            // (§9.17) writing the two unconditional fields and no per-unit
            // one at all.
            .none, .idt_hold, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => {},
        }
    }
    // §5.6.1.2 path-integrated reactive latches (ngspice NIintegrate
    // semantics): pb__k is the ddt operand at the last accepted solve, pq__k
    // the sum of committed A·ΔB increments (the charge base, fixed across one
    // Newton attempt). wb__/wq__ stage the current iterate (updateState);
    // stateCtl(.commit) latches them. Zero defaults make the first committed
    // increment A·B, as ngspice MODEINITTRAN seeds qgs = capgs·vgs.
    for (0..self.core.prev_lo.len) |k| {
        try self.w("    pb__{d}: f64 = 0.0, // path_prev latch\n    wb__{d}: f64 = 0.0, // staged\n", .{ k, k });
    }
    for (0..self.core.acc_lo.len) |k| {
        try self.w("    pq__{d}: f64 = 0.0, // path_acc latch\n    wq__{d}: f64 = 0.0, // staged\n", .{ k, k });
    }
    // §5.10 event-assigned variables. Last, so a model that gains one moves
    // no operator field. The default is the declared initializer, which only
    // the first evaluation (before any `updateState`) can observe.
    for (self.lowered.held_vars.items, 0..) |h, i| {
        // ponytail: a parameter-dependent initializer takes the parameter's
        // spec default, like every §4.5 operator control argument, because a
        // struct field default is comptime and a model card is not. Upgrade
        // path: write it in `initState`, which already takes `*Instance`.
        try self.hist.append(self.arena, self.names.held_names[i]);
        if (h.array != none_u32) {
            try emitHeldArrayField(self, h, self.names.held_names[i], "// §5.10 held across evaluations");
            continue;
        }
        const init = self.an.foldConst(self.an.rv(h.init), true);
        const v: f64 = if (init) |c| c.f else 0.0;
        if (h.ty == .integer) {
            try self.w("    {s}: i64 = {d}, // §5.10 held across evaluations\n", .{
                // Saturating like every other fold-side real -> int cast: an
                // initializer of `1e300` must not panic the compiler.
                self.names.held_names[i], std.math.lossyCast(i64, @round(v)),
            });
        } else {
            try self.w("    {s}: f64 = {s}, // §5.10 held across evaluations\n", .{
                self.names.held_names[i], try fmtF64(self, v),
            });
        }
    }
    try emitTpFields(self);
    // The setup roots (`Setup`), LAST for the same insert-tolerance reason as
    // the held block above. `su_ok` exists only where it is asserted.
    if (self.su.vals.len != 0) try self.w(
        \\    su: Setup = .{{}},
        \\    su_ok: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {{}},
        \\
    , .{}) else if (self.lowered.timepoints.items.len != 0) try self.w("    su: Setup = .{{}},\n", .{});
    try self.w("}};\n\n", .{});
    try emitTpHelpers(self);
}

/// VerA's `vera_timepoint` (§2.9): each cached statement's `Instance` fields,
/// `tp<b>_t`/`tp<b>_k` (the time and `zTpKey` it was filled at; NaN when
/// dropped) and one `tp<b>_s<k>` per slot. Not history: `stateCtl` drops
/// them rather than restoring them (`zTpDrop`).
fn emitTpFields(self: *Gen) Error!void {
    for (self.lowered.timepoints.items, 0..) |t, b| {
        try self.w("    /// vera_timepoint {d}: the timepoint its cache holds, NaN when dropped.\n", .{b});
        try self.w("    tp{d}_t: f64 = std.math.nan(f64),\n    tp{d}_k: u8 = 0,\n", .{ b, b });
        for (t.slots, 0..) |sl, k| {
            // A slot nothing reads after the statement is not queued (`plan_jobs`).
            if (gen_dispatch.coreIdx(self, self.an.rv(sl.final)) == null) continue;
            if (sl.array != none_u32) {
                const m = self.lowered.mem_arrays.items[sl.array];
                try self.w("    tp{d}_s{d}: [{d}]{s} = @splat(0), // {s}\n", .{ b, k, m.len, if (m.ty == .integer) "i64" else "f64", sl.name });
            } else {
                try self.w("    tp{d}_s{d}: {s} = 0, // {s}\n", .{ b, k, if (sl.ty == .integer) "i64" else "f64", sl.name });
            }
        }
    }
}

/// VerA's `vera_timepoint` (§2.9): `zTpDrop`, which every entry point that
/// moves what a cached statement reads calls (`initState`, `setup`,
/// `updateState`, `stateCtl`), and `zTpStore`, which `eval` and `evalQ`
/// call on the core result: a statement that ran on a stale cache fills it.
fn emitTpHelpers(self: *Gen) Error!void {
    const tps = self.lowered.timepoints.items;
    if (tps.len == 0) return;
    try self.w("/// vera_timepoint: drop every per-timepoint cache.\nfn zTpDrop(inst: *Instance) void {{\n", .{});
    for (0..tps.len) |b| try self.w("    inst.tp{d}_t = std.math.nan(f64);\n", .{b});
    try self.w("}}\n\n", .{});
    try self.w("/// vera_timepoint: store what a statement that ran on a stale cache assigned.\n", .{});
    try self.w("inline fn zTpStore(inst: *Instance, sim: contract.SimState, m: anytype) void {{\n", .{});
    for (tps, 0..) |t, b| {
        // An unconditional statement's mark folds to 1 and is no core field.
        if (gen_dispatch.coreIdx(self, self.an.rv(t.mark))) |mk| try self.w("    if (m.f{d} != 0 and ", .{mk}) else try self.w("    if (", .{});
        try self.w("!zTpHit(inst.tp{d}_t, inst.tp{d}_k, sim)) {{\n", .{ b, b });
        for (t.slots, 0..) |sl, k| {
            const fk = gen_dispatch.coreIdx(self, self.an.rv(sl.final)) orelse continue;
            const val = sl.array == none_u32 and sl.ty != .integer;
            try self.w("        inst.tp{d}_s{d} = m.f{d}{s};\n", .{ b, k, fk, if (val) ".val()" else "" });
        }
        try self.w("        inst.tp{d}_t = sim.t;\n        inst.tp{d}_k = zTpKey(sim);\n    }}\n", .{ b, b });
    }
    try self.w("}}\n\n", .{});
}

/// Records `Instance` field `fmt` as history `stateCtl` commits and reverts.
fn keepHist(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    try self.hist.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
}

/// Emits a §3.2.2/§5.10 held array's `Instance` field: plain values,
/// defaulting element by element to the declared initializer (§3.2's zero
/// where the pattern is silent), the spec default as for a held scalar.
fn emitHeldArrayField(self: *Gen, h: Lower.HeldVar, name: []const u8, comment: []const u8) Error!void {
    const m = self.lowered.mem_arrays.items[h.array];
    const ty: []const u8 = if (m.ty == .integer) "i64" else "f64";
    var all_zero = true;
    for (h.inits) |iv| {
        const c = self.an.foldConst(self.an.rv(iv), true) orelse continue;
        if (c.f != 0.0) all_zero = false;
    }
    if (all_zero) return self.w("    {s}: [{d}]{s} = @splat(0), {s}\n", .{ name, m.len, ty, comment });
    try self.w("    {s}: [{d}]{s} = .{{", .{ name, m.len, ty });
    for (0..m.len) |k| {
        const c = if (k < h.inits.len) self.an.foldConst(self.an.rv(h.inits[k]), true) else null;
        const v: f64 = if (c) |x| x.f else 0.0;
        if (k != 0) try self.w(", ", .{});
        if (m.ty == .integer) try self.w("{d}", .{std.math.lossyCast(i64, @round(v))}) else try self.w("{s}", .{try fmtF64(self, v)});
    }
    try self.w(" }}, {s}\n", .{comment});
}

/// Returns whether the module's §5.10 held state is fed by `cross`/`above`
/// edges: a hysteresis FSM (a switch) that gets `stateCtl`
/// (contract.StateCtlOp). The host rejects a converged step whose accepted
/// solution flipped the latch and shrinks toward the crossing, so the
/// discontinuity lands sharp instead of smearing across one step.
fn fsmStateCtl(self: *const Gen) bool {
    for (self.lowered.held_vars.items) |h| {
        if (h.why == .event) break;
    } else return false;
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => return true,
            .none, .idt_hold, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    return false;
}

/// Returns whether the module has any path latch. Every gate on the latch
/// machinery tests this, not `acc_lo`: the reactive lowering plants prev+acc
/// pairs, but a source-level `$prev` site arrives alone and still needs its
/// updateState staging and commit advance.
pub fn pathLatches(self: *const Gen) bool {
    return self.core.acc_lo.len != 0 or self.core.prev_lo.len != 0;
}

/// Emits `State`'s `stateCtl` twins: one per `Gen.hist` field, typed and
/// defaulted as that `Instance` field, plus `t_prev__acc` when `t_prev` and
/// each §4.5.7 ring's overwritten sample. Requires `emitInstance` to have run
/// and `z_inst0` (a default `Instance`) to be declared.
pub fn emitStateTwins(self: *Gen, t_prev: bool) Error!void {
    if (t_prev) try self.w("    t_prev__acc: f64 = 0.0,\n", .{});
    for (self.hist.items) |h| try self.w("    {s}: @TypeOf(z_inst0.{s}) = z_inst0.{s},\n", .{ h, h, h });
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay)
            try self.w("    {0s}__t__acc: f64 = 0.0,\n    {0s}__v__acc: f64 = 0.0,\n", .{self.names.unit_names[i]});
    }
}

/// Emits the `stateCtl` hook; every `updateState` has one. `query` compares
/// the held state a `cross`/`above` FSM writes (`fsmStateCtl`) and nothing
/// else, since other history moving is not a step-reject condition. `commit`
/// latches the §5.6.1.2 path latches (`pb = wb`, `pq += wq`, `wq = 0`) and
/// copies every field `updateState` advances into its `State` twin
/// (`emitStateTwins`); `revert` copies the twins back, so a rejected step
/// leaves the device as the last accepted point did (§4.5). A §4.5.7 ring
/// keeps only the sample the next push overwrites, which is exact while one
/// `updateState` runs between `stateCtl` calls. Tag order mirrors
/// contract.StateCtlOp, which the host converts by ordinal.
pub fn emitStateCtl(self: *Gen, t_prev: bool) Error!void {
    const fsm = fsmStateCtl(self);
    try self.w(
        \\pub fn stateCtl(_: *const Model, inst: *Instance, state: *State, op: contract.StateCtlOp) bool {{
        \\    if (op == .query) {{
        \\        return
    , .{});
    // VerA's `vera_timepoint` (§2.9): a commit or a revert moves the held
    // state a cached statement reads.
    const tp_drop = if (self.lowered.timepoints.items.len != 0) "        zTpDrop(inst);\n" else "";
    var first = true;
    for (self.names.held_names, self.lowered.held_vars.items) |n, h| {
        if (!fsm) break;
        if (h.why != .event) continue;
        // §3.2.2 a held array compares element by element.
        if (h.array != none_u32)
            try self.w("{s}!std.meta.eql(inst.{s}, state.{s})", .{ if (first) " " else "\n            or ", n, n })
        else
            try self.w("{s}(inst.{s} != state.{s})", .{ if (first) " " else "\n            or ", n, n });
        first = false;
    }
    if (first) try self.w(" false", .{});
    try self.w(
        \\;
        \\    }}
        \\    if (op == .commit) {{
        \\{s}
    , .{tp_drop});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        state.limiter_previous = inst.limiter_previous;\n",
        .{},
    );
    for (0..self.core.prev_lo.len) |k| try self.w("        inst.pb__{d} = inst.wb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("        inst.pq__{d} += inst.wq__{d};\n        inst.wq__{d} = 0.0;\n", .{ k, k, k });
    for (self.hist.items) |h| try self.w("        state.{s} = inst.{s};\n", .{ h, h });
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        state.{0s}__t__acc = inst.{0s}__t[@intCast(inst.{0s}__head % {1d})];\n        state.{0s}__v__acc = inst.{0s}__v[@intCast(inst.{0s}__head % {1d})];\n",
            .{ self.names.unit_names[i], hist_len },
        );
    }
    if (t_prev) try self.w("        state.t_prev__acc = state.t_prev;\n", .{});
    try self.w("    }} else {{\n{s}", .{tp_drop});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        inst.limiter_previous = state.limiter_previous;\n",
        .{},
    );
    for (self.hist.items) |h| try self.w("        inst.{s} = state.{s};\n", .{ h, h });
    // After `__head` is back: the slot the rejected push overwrote.
    for (self.names.units, 0..) |u, i| {
        if (u.role == .analog_op and u.op == .absdelay) try self.w(
            "        inst.{0s}__t[@intCast(inst.{0s}__head % {1d})] = state.{0s}__t__acc;\n        inst.{0s}__v[@intCast(inst.{0s}__head % {1d})] = state.{0s}__v__acc;\n",
            .{ self.names.unit_names[i], hist_len },
        );
    }
    if (t_prev) try self.w("        state.t_prev = state.t_prev__acc;\n", .{});
    try self.w(
        \\    }}
        \\    return false;
        \\}}
        \\
        \\
    , .{});
}
