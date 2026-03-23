//! File assembly: the device.zig skeleton (§1.3.1 `U`, §3.4 `Model`, §4.5 `Instance`).
//!
//! In: the unit list and plans. Out: imports, prelude kernels, `U`, `Model`, `Instance`, the
//! host-facing tables, and the contract validation block.
//!
//! LRM clauses this file's code cites: §1.3.4.2, §3.4, §3.6.1.2, §4.5, §4.5.7, §4.5.12, §4.5.15, §5.4.2, §5.10, §6.3.4, §9.10, §9.13.1.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_file.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const gen_kernel_text = @import("kernel_text.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_render = @import("render.zig");
const gen_state = @import("state.zig");
const gen_unit = @import("unit.zig");
const opdb = @import("ir").op;
const Analysis = @import("ir").Analysis;
const cg_filters = @import("../cg_filters.zig");
const cg_limit = @import("../cg_limit.zig");
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const hist_len = codegen.hist_len;
const OpKind = codegen.OpKind;
const opHasState = codegen.opHasState;
const header_txt = gen_kernel_text.header_txt;
const math_txt = gen_kernel_text.math_txt;
const domain_quiet_txt = gen_kernel_text.domain_quiet_txt;
const domain_report_txt = gen_kernel_text.domain_report_txt;
const ops_txt = gen_kernel_text.ops_txt;
const timer_txt = gen_kernel_text.timer_txt;
const str_txt = gen_kernel_text.str_txt;
const rng_txt = gen_kernel_text.rng_txt;
const table_txt = gen_kernel_text.table_txt;
const file_txt = gen_kernel_text.file_txt;
const limit_txt = gen_kernel_text.limit_txt;
const filt_txt = gen_kernel_text.filt_txt;
const hist_txt = gen_kernel_text.hist_txt;
const helpers_head_txt = gen_kernel_text.helpers_head_txt;
const prelude_head_txt = gen_kernel_text.prelude_head_txt;
const prelude_math_txt = gen_kernel_text.prelude_math_txt;
const prelude_timer_txt = gen_kernel_text.prelude_timer_txt;
const prelude_hist_txt = gen_kernel_text.prelude_hist_txt;
const prelude_filt_txt = gen_kernel_text.prelude_filt_txt;
const prelude_display_txt = gen_kernel_text.prelude_display_txt;
const prelude_table_txt = gen_kernel_text.prelude_table_txt;
const prelude_rng_txt = gen_kernel_text.prelude_rng_txt;
const prelude_file_txt = gen_kernel_text.prelude_file_txt;
const prelude_str_txt = gen_kernel_text.prelude_str_txt;
const display_txt = gen_kernel_text.display_txt;
const pscalar_txt = gen_kernel_text.pscalar_txt;
const rscalar_txt = gen_kernel_text.rscalar_txt;

// =======================================================================
// File assembly
// =======================================================================

pub fn emitFile(self: *Gen) Error!void {
    const stateful = hasStatefulOps(self);
    const hist = usesOp(self, .absdelay);
    const filt = usesOp(self, .laplace) or usesOp(self, .zi);
    const timer = usesOp(self, .timer);
    // §9.5.3/§9.5.4.2. Set at the call in lowering, because by the time the
    // MIR is sliced into units the formatter's call may sit in any of them.
    //
    // `display == .emit` joins it because §9.4.3's real conversions live in
    // the same file: Table 9-23 grants them "the full formatting
    // capabilities available in the C language", and `zCReal` is that C —
    // so a printing artifact needs the string kernels whether or not the
    // model ever names `$sformat`. This is the same condition `display_txt`
    // has always carried, now spelled once.
    const strs = self.lowered.uses.contains(.str_tasks) or self.display == .emit;
    // §9.21, set at the call for the same reason `strs` is: the lookup may
    // land in any unit once the MIR is sliced.
    const tbl = self.lowered.uses.contains(.table_model);
    // §9.13, set at the call for the same reason: `lowerRandom` runs long
    // before the MIR is sliced into units.
    const rng = self.lowered.uses.contains(.rng);
    // §9.5 the descriptor table. `display == .emit` is the second condition
    // and not a convenience: it is the artifact whose host runs the per-point
    // side-effect phase these kernels have to be sequenced in.
    const files = self.display == .emit and self.lowered.uses.contains(.file_tasks);
    try buildPrelude(self, stateful, hist, filt, timer, strs, tbl, rng, files);
    try self.out.appendSlice(self.gpa, header_txt);
    try self.out.appendSlice(self.gpa, math_txt);
    try self.out.appendSlice(self.gpa, if (self.display == .emit) domain_report_txt else domain_quiet_txt);
    try self.out.appendSlice(self.gpa, ops_txt);
    if (timer) try self.out.appendSlice(self.gpa, timer_txt);
    if (hist) try self.out.appendSlice(self.gpa, hist_txt);
    // §4.5.11/§4.5.12 the filter kernels are embedded from a real Zig file,
    // so they arrive already `pub` — which is right for `h.zig` and wrong
    // here: `contract.rejectStrayPubDecls` allows only contract-recognized
    // names to be public, so a model using `laplace_nd` or `zi_nd` failed
    // `--check`/`--emit-so` on `stray pub decl \`zBilin\``. Every other
    // helper block is written private and made public by `publish`; this one
    // has to go the other way.
    if (filt) try depublish(self.gpa, &self.out, filt_txt);
    // §9.4.3's padding helper serves §9.5.3 too — `$sformat` is the same
    // formatter — so a device that never prints still needs it if it formats
    // into a string.
    if (strs) try self.out.appendSlice(self.gpa, display_txt);
    if (strs) try depublish(self.gpa, &self.out, str_txt);
    if (files) try depublish(self.gpa, &self.out, file_txt);
    if (tbl) try depublish(self.gpa, &self.out, table_txt);
    if (rng) try depublish(self.gpa, &self.out, rng_txt);
    if (self.limits.calls.len != 0) try depublish(self.gpa, &self.out, limit_txt);
    if (self.lowered.uses.contains(.plusargs)) try self.out.appendSlice(self.gpa, plusarg_txt);
    try self.out.appendSlice(self.gpa, "\n");
    // §4.5.15 `limit`/`seed` evaluate the core on a plain solution too, so
    // they need `R` for the same reason `updateState` does. It stays out of
    // `buildPrelude`/`h.zig`: no UNIT body can reach these, because `$limit`
    // renders as the identity inside one. `collapse` reads the core the
    // same way, so it opens `R` too — and so does §4.6.4 `noisePsd`, which
    // is `updateState`'s shape exactly: one value-only core sweep at a
    // state vector the caller hands in.
    // `emitSwitchRow` splits exactly these branches; `prepare` planned them
    // (`plan/topology.zig`) before any residual is emitted.
    const cpairs = self.topo.cpairs;
    if (stateful or cg_limit.needsR(self) or cpairs.len != 0 or pathLatches(self) or
        self.hp.vals.len != 0 or self.noise.rows.len != 0 or try gen_dispatch.acUsesCore(self))
    {
        try self.out.appendSlice(self.gpa, rscalar_txt);
        // Pinned to the contract's primitive list, same as tb.zig's
        // Dual/Vec — a primitive added there cannot silently miss R.
        try self.out.appendSlice(self.gpa, "comptime {\n    contract.checkScalar(R);\n}\n\n");
    }

    try emitTopology(self);
    try emitModel(self);
    try emitDerive(self);
    try emitInstance(self);
    try self.w("const InstancePtr = contract.InstancePtr(@This());\n", .{});
    if (self.lowered.table_samples.items.len != 0) try self.w("pub const mutable_eval = true;\n", .{});
    try emitPrecompute(self);
    try gen_unit.emitUnits(self);
    try gen_dispatch.emitDispatchers(self);
    try gen_dispatch.emitNoiseTable(self);
    try gen_dispatch.emitAcTable(self);
    try gen_call.emitSystfTable(self);
    // §4.5.2's accepted-step sweep also carries §9.13.1's internal-seed
    // advance, which is the ONLY place a stream may move: a per-iteration draw
    // makes the residual non-deterministic and Newton never converges.
    if (stateful or self.lowered.rng_auto_sites != 0 or pathLatches(self)) try gen_state.emitStateMachine(self);
    try cg_limit.emit(self);
    try gen_state.emitCollapse(self, cpairs);
    try gen_state.emitNextBreakpoint(self);
    try gen_state.emitDelays(self);
    try gen_dispatch.emitDerivReads(self, if (self.limits.calls.len != 0) cg_limit.liveSets(self).writes else 0);
    // Lane-parallel permission (see `float/lanes.zig`): eval/q of this device
    // instantiated with a vector S is exact per lane. The testbench's
    // batch differential check keys on it, and a batching host may.
    if (!self.float.pinned) try self.w("pub const lane_clean = true;\n\n", .{});
    if (self.core_reads_simstate) try self.w("pub const core_reads_simstate = true;\n\n", .{});
    try self.w("comptime {{\n    contract.validate(Self);\n}}\n", .{});
}

/// `Output.prelude` (the file-scope prologue of a `u/<key>.zig`) and
/// `Output.helpers` (`h.zig`).
///
/// The unit file ALIASES the helpers rather than re-emitting them per unit.
/// Re-emitting is what a naive split does, and it multiplies by the unit
/// count exactly the AstGen + Sema work this split exists to remove; an
/// alias is one declaration `zig` analyses once. The aliases mirror what a
/// unit body can name (§4.3 math, §4.5 operators, §4.5.7 history,
/// §4.5.11/12 filters, the topology types) and are gated on the same
/// conditions `emitFile` uses, so no alias ever names a missing decl.
///
/// `n_u` is RECOMPUTED (`contract.nU(dev)`) rather than aliased: it is
/// private in device.zig and `contract.rejectStrayPubDecls` will not let it
/// become public. It is the same comptime value either way.
pub fn buildPrelude(self: *Gen, stateful: bool, hist: bool, filt: bool, timer: bool, strs: bool, tbl: bool, rng: bool, files: bool) Error!void {
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(self.arena, prelude_head_txt);
    try p.appendSlice(self.arena, prelude_math_txt);
    if (timer) try p.appendSlice(self.arena, prelude_timer_txt);
    if (hist) try p.appendSlice(self.arena, prelude_hist_txt);
    if (filt) try p.appendSlice(self.arena, prelude_filt_txt);
    if (self.display == .emit or strs) try p.appendSlice(self.arena, prelude_display_txt);
    if (strs) try p.appendSlice(self.arena, prelude_str_txt);
    if (files) try p.appendSlice(self.arena, prelude_file_txt);
    if (tbl) try p.appendSlice(self.arena, prelude_table_txt);
    if (rng) try p.appendSlice(self.arena, prelude_rng_txt);
    if (stateful) try p.appendSlice(self.arena, "const R = h.R;\n");
    // The shared core is a unit file like any other, and it sits beside the
    // unit that calls it — device.zig's own alias for it is private to
    // device.zig, so it is not in scope here.
    // The shared core is a unit file like any other and sits beside the
    // units that call it; device.zig's own alias for it is private to
    // device.zig, so it is not in scope here. The alias is spelled `core`
    // rather than the structural key so that the core's OWN file — which
    // gets this same prologue — does not redeclare its own name. A file
    // importing itself is legal and, unreferenced, never analysed.
    if (self.core.name.len != 0)
        try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.core.name});
    try p.appendSlice(self.arena, "\n");
    self.prelude = p.items;

    var hz: std.ArrayList(u8) = .empty;
    try hz.appendSlice(self.arena, helpers_head_txt);
    try publish(self.arena, &hz, math_txt);
    try publish(self.arena, &hz, if (self.display == .emit) domain_report_txt else domain_quiet_txt);
    try publish(self.arena, &hz, ops_txt);
    if (timer) try publish(self.arena, &hz, timer_txt);
    if (hist) try publish(self.arena, &hz, hist_txt);
    if (filt) try publish(self.arena, &hz, filt_txt);
    if (self.display == .emit or strs) try publish(self.arena, &hz, display_txt);
    if (strs) try publish(self.arena, &hz, str_txt);
    if (files) try publish(self.arena, &hz, file_txt);
    if (tbl) try publish(self.arena, &hz, table_txt);
    if (rng) try publish(self.arena, &hz, rng_txt);
    if (stateful) try publish(self.arena, &hz, rscalar_txt);
    self.helpers = hz.items;
}

/// Copy `src` into `out`, making each top-level declaration public. The
/// same text is emitted PRIVATE into device.zig, where the contract forbids
/// stray public names, and PUBLIC into `h.zig`, where the unit files can
/// reach it — one source of truth, one three-line transform, instead of two
/// near-identical copies of 10 KB of helper text to keep in sync.
/// The inverse of `publish`: drop a leading `pub ` so an embedded Zig file
/// can be spliced into device.zig, where the contract forbids stray public
/// names. See `emitFile`.
pub fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
    }
}

pub fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
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

/// Close the byte range of the unit declaration that started at `lo`. The
/// ranges must TILE (`Output`'s invariant), which is what lets the writer
/// reconstruct `device.zig` as prologue ++ imports ++ tail.
pub fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
    if (self.file_hi.items.len != 0)
        assert(self.file_hi.items[self.file_hi.items.len - 1] == lo);
    try self.file_names.append(self.arena, name);
    try self.file_lo.append(self.arena, @intCast(lo));
    try self.file_fn.append(self.arena, @intCast(fn_at));
    try self.file_hi.append(self.arena, @intCast(self.out.items.len));
}

/// Does this model need the §4.5.2 accepted-step machinery at all? A §5.10
/// held variable does, for the same reason an operator does: its value is
/// carried in `Instance` and only `updateState` may advance it.
/// `contract.validate` (tools/contract.zig) then requires
/// `State` + `initState` + `updateState` as a set, which `emitStateMachine`
/// emits together.
pub fn hasStatefulOps(self: *const Gen) bool {
    if (self.lowered.held_vars.items.len != 0 or self.lowered.limit_slots.items.len != 0 or self.lowered.uses.contains(.newton_iter) or self.lowered.uses.contains(.reject_iteration)) return true;
    for (self.names.units) |u| {
        if (u.role == .analog_op and opHasState(u.op)) return true;
    }
    return false;
}

pub fn usesOp(self: *const Gen, k: OpKind) bool {
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op == k) return true;
    }
    return false;
}

/// §1.3.1 nodes / §6.5 ports. `x[i]` in every emitted body indexes exactly
/// this enum, and ports come first so the host's terminal order is the
/// module header order.
pub fn emitTopology(self: *Gen) Error!void {
    // The 257th member is `enum tag value '256' too large for type 'u8'` —
    // an error in the HOST's build, at a line of generated Zig, with nothing
    // naming the .va that produced it. Refuse here instead, where the model
    // is still in hand. `--emit-zig` exited 0 on this for seven waves.
    //
    // ponytail: |U| <= 256 is a PERMANENT ceiling, not a pending widening.
    // `enum(u16)` is the upgrade path and it is an ABI break: `isDenseEnum`
    // (tools/contract.zig) requires the `u8` tag, so the tag type and that
    // predicate move together, and every host that already links a device
    // recompiles. Registered in TODO.md §3 under the device contract.
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
        const kindc: []const u8 = if (i < self.lowered.num_ports) "port" else if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) "branch flow" else "internal";
        try self.w("    {s}, // {s}\n", .{ n, kindc });
    }
    try self.w("}};\n\npub const num_ports: usize = {d};\nconst n_u = contract.nU(Self);\n\n", .{self.lowered.num_ports});

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
    // §3.6.1.2 the tolerance the DISCIPLINE settled on for each unknown.
    // `DisciplineInfo` has carried both halves since it was written, with
    // nothing consuming them; this is the consumer. A host solving `eval`
    // needs the absolute half of its stopping test per unknown and cannot
    // derive it — "negligible" is 1e-6 V on an electrical node, 1e-12 A on
    // its current, and 1e-4 K on a thermal one, and §3.6.2.3 lets a
    // discipline override the nature's number outright.
    try self.w("/// §3.6.1.2 `abstol` per unknown: the largest value of this\n", .{});
    try self.w("/// quantity a host may treat as zero, after any §3.6.2.3 override.\n", .{});
    try self.w("pub const u_abstol = [n_u]f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        try self.w("    {d},\n", .{abstolOf(self, @intCast(i))});
    }
    try self.w("}};\n\n", .{});
    try emitNodesets(self);
    try self.w(
        \\/// §4.6.1 analysis() / §5.10.2 global events. The host sets this per pass.
        \\pub const AnalysisKind = enum(u8) {{ static, ic, nodeset, dc, tran, ac, noise }};
        \\
        \\
    , .{});
}

/// §3.6.3.2 net discipline initial (nodeset) values, as one optional table
/// over `U` — the `u_abstol` shape, for the `u_abstol` reason: it is a
/// number per unknown that only the DECLARATION knows and only the SOLVER
/// can use, and the solver belongs to the host.
///
/// Emitted only when the module declares at least one, so a device that
/// has no nodeset is byte-identical to what it was before this existed and
/// a host reads "no opinion" off the decl's absence rather than off a table
/// of nulls.
///
/// `?f64` and not `f64`: "a null value ... indicates that no nodeset value
/// is being specified", and zero is a perfectly ordinary nodeset. Every
/// unknown that is not a declared net is null too — a §5.4.2 branch flow
/// has no net_decl_assignment to carry one, since the clause gives the
/// value to "the potential of the net".
pub fn emitNodesets(self: *Gen) Error!void {
    if (self.lowered.nodesets.items.len == 0) return;
    try self.w("/// §3.6.3.2 nodeset: the initial guess the source states for each\n", .{});
    try self.w("/// unknown's potential. A HINT to the solver — not an initial\n", .{});
    try self.w("/// condition and not a clamp; the solved answer is unchanged by it.\n", .{});
    try self.w("pub const u_nodeset = [n_u]?f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        // §3.6.3.2: "If different nets of a node have conflicting
        // initializers ... it is a race condition for which the initializer
        // wins." Two declarations of one net inside one module are the
        // non-hierarchical case of that sentence, so LAST wins here and the
        // clause permits either.
        var v: ?f64 = null;
        for (self.lowered.nodesets.items) |ns| {
            if (ns.node == i) v = ns.value;
        }
        if (v) |x| try self.w("    {s},\n", .{try fmtF64(self, x)}) else try self.w("    null,\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// §3.6.1.2 the `abstol` of the nature this unknown's quantity belongs to,
/// after §3.6.2.3's per-discipline override — which is why it is read off
/// `DisciplineInfo` and not off the nature table.
///
/// A §5.4.2 branch-flow unknown has no discipline of its own (`appendNode`
/// gives it `""`), so its tolerance comes from the discipline at its HIGH
/// node — which `Lower.NodeKind` carries as the slot's payload. It used to
/// be recovered by parsing `flow(a,b)` back apart, which is a guess about a
/// spelling and not a fact about the unknown, and which a node name holding
/// a `,` or a `>` (both legal inside a §2.8.1 escaped identifier) got wrong.
///
/// A §1.3.4.2 flow-only net is `.net` and its own node already, so it falls
/// straight through to `flow_abstol`.
///
/// The two fallbacks are annex D's own defaults for `Voltage` and `Current`
/// (`VOLTAGE_ABSTOL` 1e-6, `CURRENT_ABSTOL` 1e-12), reached only by an
/// unknown whose net never got a discipline — a §3.5 implicit net in a file
/// with no `default_discipline`, which cannot be contributed to anyway.
pub fn abstolOf(self: *const Gen, i: u32) f64 {
    const flow = plan_topo.isFlowUnknown(self.input(), i);
    var idx: u16 = @intCast(i);
    if (i < self.lowered.nodes.len) switch (self.lowered.nodes.items(.kind)[i]) {
        .net => {},
        .branch_flow, .port_flow => |n| idx = n,
    };
    if (idx == Lower.ground or idx >= self.lowered.nodes.len)
        return if (flow) 1e-12 else 1e-6;
    const info = self.lowered.disciplines.get(self.lowered.nodes.items(.disc)[idx]) orelse
        return if (flow) 1e-12 else 1e-6;
    return if (flow) info.flow_abstol else info.potential_abstol;
}

/// §3.4 parameters. One field, typed, with the constant-folded spec default.
pub fn emitModel(self: *Gen) Error!void {
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
    // §3.4.7 aliasparam. "The aliasparam declaration creates an alternate
    // name ... which can be used to override the value of the parameter" —
    // so the alias is part of the model-card ABI even though it is not a
    // parameter, and a card that only carried the original name would make
    // `nmos2 #(.trise(5))` unspellable. It is a SECOND FIELD rather than a
    // second name for the first because Zig has no field aliases; `derive`
    // below folds it back onto the original, which is the point at which
    // the two names become one storage again.
    //
    // The `__given` flag is unconditional here (unlike §9.19's, which is
    // emitted only for a parameter someone asked about): it is the only
    // thing that tells "the host overrode the alias" from "the host left
    // the alias at the original's default", and those two have to differ.
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
    // §9.15 the host-published nominal temperature this module reads.
    // Model, not Instance: `.options tnom` is one number per RUN, so an
    // Instance copy would replicate a global across every instance of
    // every batch for a value `derive()` reads once at build. The
    // initializer is Table 9-27's default, so `Model{}` is unchanged for a
    // host that never writes it.
    if (self.lowered.uses.contains(.host_simparam)) try self.w(
        "    {s}: f64 = {s}, // §9.15 $simparam(\"tnom\"), degC — host-written\n",
        .{ Lower.simparamHostField("tnom").?, try fmtF64(self, self.lowered.simparamValue("tnom").?) },
    );
    if (self.lowered.params.items.len == 0 and !self.lowered.uses.contains(.host_simparam)) {
        try self.w("    // (the module declares no parameters)\n    _unused: u8 = 0,\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// §6.3.4/§3.4.5 — recompute every parameter whose value is not its own.
///
/// The Model is a flat struct of independent fields, so a host write to
/// `base` cannot by itself reach a `doubled = 2.0*base` declared over it;
/// §6.3.4 requires that it does ("an update of gate_width ... automatically
/// updates gate_cap"). This is that seam: the host writes the model card,
/// calls `derive`, and only then builds an Instance.
///
/// Two kinds of field are rewritten, and nothing else — a parameter with a
/// literal default keeps costing exactly one field initializer:
///   - one whose default mentions another parameter (§6.3.4);
///   - every §3.4.5 localparam, whatever its default. "Local parameters ...
///     shall not be directly modified" — and since the field has to stay
///     readable as `model.<name>` from the units, the way to enforce that
///     against a host that writes it anyway is to overwrite it here.
///
/// Declaration order IS dependency order: a default may only name a
/// parameter declared before it (a forward or self reference is E0314 at
/// lowering), so a chain a→b→c derives correctly in one pass and a cycle
/// cannot be built in the first place — no SCC pass, no cycle diagnostic.
///
/// The field initializer is left as the fold-through-declared-defaults
/// value, so `Model{}` on its own is still the spec default and a host that
/// overrides nothing need not call this at all.
pub fn emitDerive(self: *Gen) Error!void {
    const at = self.out.items.len;
    try self.w(
        \\/// §6.3.4 parameter dependence + §3.4.5 localparam. Call ONCE after
        \\/// writing the model card and before the first solve: the fields below
        \\/// are defined by expressions over other parameters, so they are not
        \\/// valid until the parameters they read have their final values.
        \\pub fn derive(model: *Model) void {{
        \\
    , .{});
    const body = self.out.items.len;
    // §3.4.7 first, and that order is the rule and not a convenience: an
    // override written through the alias has to be the original's value
    // BEFORE a §6.3.4 dependent parameter reads it, or `dtemp` derives from
    // the alias and everything over `dtemp` derives from the default.
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
        // `resolve_params = false` ⇒ this folds only if the default is
        // self-contained, which is exactly "not derived from a parameter".
        if (self.an.foldConst(p.default, 0, false) != null and !p.is_local) continue;
        // Render in the parameter's numeric domain. A known initializer
        // cannot stand in for a dependency that changes after a host write.
        const e = (if (ty == .int) try gen_call.i64Const(self, p.default, 0) else try gen_call.f64Const(self, p.default, 0, false)) orelse {
            // Defaults with no compile-time value retain W1050's explicit
            // host-supplied-value contract (for example $simparam("gmin")).
            if (!p.is_local and p.folded == null and self.an.foldConst(p.default, 0, true) == null) continue;
            if (self.diags) |bag| try bag.add(.codegen, .E1004, self.lowered.tokenSpan(p.tok), "host derivation of `{s}` uses an unsupported expression; its declared value cannot be frozen after parameter overrides", .{p.name});
            return error.UnsupportedParameterDefault;
        };
        // §6.3.4 gives the DEFAULT; an explicit host write wins. Only a
        // localparam is overwritten unconditionally ("shall not be
        // directly modified"). Unguarded, BSIMSOI's `VTH0 = VTHO` erased
        // every card VTH0 back to VTHO's default. `initGiven` raised the
        // `__given` companion for every non-local derived parameter.
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
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("}}\n\n", .{});
}

/// W1050 — the one place a parameter whose default VerA never computes is
/// said out loud. Rendering `0` for such a field is what shipped four wrong
/// parameters in a real model, and the reason it was invisible is that
/// nothing complained.
///
/// A `0` initializer is honest under exactly two conditions, and this is
/// the negation of both:
///   - the two folds in `paramDefault` answered, so `0` is the real value;
///   - `derive()` overwrites the field, which it does whenever `f64Const`
///     can render the default over the model card (§6.3.4).
/// What is left is a default nothing in the pipeline evaluates. It is
/// reachable only through a ch9 call — §9.10 `$temperature`, §9.18
/// `$simparam` — which is not a §3.4.1 constant_expression and has no
/// compile-time value to fold to; the field is then the HOST's to write,
/// which is a promise better made in a warning than in silence.
///
/// A warning, not a refusal: refusing would reject a model whose default
/// reads a simulator quantity, and no evidence in this tree says those do
/// not exist. `--deny=W1050` is there for a host that wants the stricter
/// reading of §3.4.1.
pub fn checkParamDefault(self: *Gen, p: Lower.ParamInfo) Error!void {
    const bag = self.diags orelse return;
    if (!bag.enabled(.W1050)) return;
    if (p.folded != null or self.an.foldConst(p.default, 0, true) != null) return;
    if (try gen_call.f64Const(self, p.default, 0, false) != null) return;
    var d = bag.build(.codegen, .W1050, self.lowered.tokenSpan(p.tok));
    d.msg("`{s}`", .{p.name});
    d.point("this default has no compile-time value, so the field is 0", .{});
    d.help("write the model card field before the first solve, or give `{s}` a constant default", .{p.name});
    try d.emit();
}

/// §3.4 the field initializer: the parameter's value under the DECLARED
/// defaults, which is what `Model{}` promises a host that overrides nothing.
///
/// Two folds answer this, and the second is not a duplicate of the first.
/// `foldConst` walks the MIR, where §4.2.12's `?:` is not a value at all —
/// it is a CFG diamond and a phi (`Lower.lowerTernary`), which no
/// value-level fold can see through. `Lower.constEval` folded the same
/// default over the AST at declaration time, before the diamond existed,
/// and §3.4 defines the default as exactly that fold; `ParamInfo.folded`
/// carries its result here. Integral defaults use that exact result before
/// consulting the real-valued MIR fold, which cannot represent every i64.
pub fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
    if (want == .int) if (p.folded) |k| {
        const value = switch (k) {
            .int => |v| v,
            .real => |v| std.math.lossyCast(i64, @round(v)),
            .str => 0,
        };
        return std.fmt.allocPrint(self.arena, "{d}", .{if (p.integer32 and k == .int) Lower.wrap32(value) else value});
    };
    const c = self.an.foldConst(p.default, 0, true);
    if (c == null) if (p.folded) |k| return switch (want) {
        .real => try fmtF64(self, k.asReal()),
        // From the i64 side rather than through the f64 carrier: `folded`
        // kept the integer, so nothing has to be rounded back out of it.
        // A REAL default on an integer parameter goes through the same
        // saturating cast as the fold path below — `Lower.Const.asInt`
        // casts unguarded, and lower.zig is not this file's to change.
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
        // clamp to i64, NaN→0) instead of panicking the compiler. §4.2.1.1
        // only says real→integer ROUNDS; it fixes no overflow rule, and the
        // honest answer would be a lowering-time diagnostic on the default's
        // own span — that needs a new code in diag_code.zig and a check in
        // lower.zig's constant validation, both owned elsewhere right now.
        // Until then the field, the fold (`Analysis.asI64`) and the runtime
        // `fi_cast` all saturate the same way, so no path panics and all
        // three agree on the garbage.
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

/// Rendered form of a float constant, memoized on its BIT PATTERN.
///
/// `hisimhv_va` emits 385 395 float constants and they are **140 distinct
/// texts** — 68 600 of them are literally `0.0` and 63 149 are `1.0`. The
/// unmemoized form did two `allocPrint`s into an arena that is never freed,
/// so it was ~770 K allocations to produce 140 strings.
///
/// Keyed on `@bitCast`, not on the `f64`: `-0.0` and `0.0` compare equal but
/// render differently, and NaN is not equal to itself. `std.hash.int` on the
/// u64 is three multiplies and bijective, so it adds no collisions over the
/// identity — the same trick as `ssa.zig`'s defs context, and as
/// `InternPool.Index.Adapter.hash`.
pub fn fmtF64(self: *Gen, x: f64) Error![]const u8 {
    if (std.math.isNan(x)) return "std.math.nan(f64)";
    if (std.math.isInf(x)) return if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)";
    const gop = try self.f64_cache.getOrPut(self.arena, @bitCast(x));
    if (gop.found_existing) return gop.value_ptr.*;
    // Stack, then copy the survivor — `printFloat` renders into a stack
    // buffer too. `{d}` on an f64 is at most ~24 bytes.
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
/// user_string at its format, leaving the plusarg_string. The match comes back
/// without its `+`, which is what `$sscanf` then reads against the whole
/// user_string: the literal prefix matches itself and the format converts the
/// remainder (an empty one scans as 0 or "", §17.10.2's own answer).
const plusarg_txt =
    \\fn zPlusarg(args: []const [:0]const u8, want: []const u8, fmt: bool) ?[]const u8 {
    \\    const key = if (fmt) want[0 .. std.mem.indexOfScalar(u8, want, '%') orelse want.len] else want;
    \\    for (args) |a| if (a.len != 0 and a[0] == '+' and std.mem.startsWith(u8, a[1..], key)) return a[1..];
    \\    return null;
    \\}
    \\
;

/// Per-instance state: environment (§9.10) plus one field group per
/// stateful §4.5 operator, KEYED BY THE STABLE UNIT NAME so adding an
/// unrelated operator never renumbers existing state.
pub fn emitInstance(self: *Gen) Error!void {
    try self.w(
        \\/// Per-instance state. The host owns every field above the operator
        \\/// block: `abstime`/`dt` per timestep (§9.10), `analysis_kind` per pass
        \\/// (§4.6.1), `temperature` in kelvin (§9.10), `mfactor` (§6.3.6).
        \\pub const Instance = struct {{
        \\    temperature: f64 = 300.15,
        \\    abstime: f64 = 0.0,
        \\    dt: f64 = 0.0,
        \\    mfactor: f64 = 1.0,
        \\    analysis_kind: AnalysisKind = .dc,
        \\    is_initial_step: bool = false,
        \\    is_final_step: bool = false,
        \\    /// §5.2.1 is this evaluation an `analog initial` pass? The host
        \\    /// sets it on the first evaluation of every SUB-TASK — each point
        \\    /// of a parameter sweep — which is what that clause's "shall be
        \\    /// re-executed" asks for, and clears it in between.
        \\    ///
        \\    /// Defaults to TRUE, unlike the two events above, because §5.2.1
        \\    /// forbids access functions and analog operators inside the block:
        \\    /// its body is a function of parameters and $temperature alone, so
        \\    /// a host that does not know this field re-computes the same values
        \\    /// a few times over instead of skipping the seed entirely and
        \\    /// reading every one of them as its declaration default.
        \\    is_analog_initial: bool = true,
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
    if (self.lowered.uses.contains(.newton_iter)) try self.w(
        "    newton_iteration: u32 = 1,\n",
        .{},
    );
    // §9.13.1's "internal seed", one slot per seedless call site. The
    // DEFAULT is the seed "the simulator picks" — a fixed value, not a clock
    // read, because §9.13.2's "shall always return the same value given the
    // same seed" is only checkable if a run is reproducible, and a device
    // whose numbers move between two identical runs cannot be debugged.
    // Distinct per site: §9.13.1 says the internal seed "gets updated every
    // time the call ... is made", so two call sites are two streams.
    if (self.lowered.rng_auto_sites != 0) {
        try self.w(
            "    /// §9.13.1 the internal seed of each seedless `$random`/`$arandom`\n" ++
                "    /// call site. Advanced by `updateState` on the ACCEPTED step and only\n" ++
                "    /// READ by `eval`: a draw that moved between Newton iterations would\n" ++
                "    /// make the residual non-deterministic and the solve would not converge.\n" ++
                "    rng_auto: [{d}]i64 = .{{",
            .{self.lowered.rng_auto_sites},
        );
        for (0..self.lowered.rng_auto_sites) |k| try self.w("{s}{d}", .{
            if (k == 0) "" else ", ", 1 + 7919 * @as(u32, @intCast(k)),
        });
        try self.w("}},\n", .{});
    }
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op) continue;
        const n = self.names.unit_names[i];
        // The nine operators whose Instance shape is FIXED are a table
        // read — the per-operator prose that used to live in these arms is
        // now beside the row it explains, in ir/op.zig.
        for (opdb.get(u.op).slots) |s| {
            if (s.note.len == 0) {
                try self.w("    {s}__{s}: f64 = {s},\n", .{ n, s.suffix, s.default });
            } else {
                try self.w("    {s}__{s}: f64 = {s}, // {s}\n", .{ n, s.suffix, s.default, s.note });
            }
        }
        // The three whose field COUNT depends on the call (`shape =
        // .from_args`) stay here, because it does.
        switch (u.op) {
            .absdelay => {
                try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u32 = 0,\n",
                    .{ n, hist_len, n, hist_len, n },
                );
                // §4.5.7 the frozen td of the two-argument form. Emitted
                // only for a SIGNAL-valued td — a constant or parameter one
                // is already its own first value, so the common site keeps
                // exactly the fields it had.
                if (try gen_call.absdelayFreezes(self, self.names.opArgs(self.mir, i))) try self.w(
                    "    {s}__td: f64 = 0.0, // §4.5.7 td, frozen at the first evaluation\n",
                    .{n},
                );
            },
            // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
            // past inputs and past outputs per section, newest first. The
            // SHAPE is structural (it comes from the flattened call), which
            // is what keeps it a codegen-time constant even though every
            // coefficient VALUE is a runtime read of Model.
            .laplace, .zi => {
                if (self.names.opInstOf(@intCast(i)) == null) continue;
                const p = cg_filters.planOf(self, i);
                if (p.err != null) continue;
                try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                    n, p.ns * p.deg, if (u.op == .zi) "12" else "11",
                });
                try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                // §4.5.12 the filter's own clock as a COUNT of samples
                // taken, not as the next sample TIME. A time re-armed by
                // `next += zn*T` drifts off the k·T grid by an ulp or two
                // (1e-9 + 1e-9 + 1e-9 is strictly greater than the double
                // nearest 3e-9), and the first timepoint that lands under
                // the drifted clock loses a sample for the whole run.
                if (u.op == .zi) try self.w(
                    "    {s}__nk: f64 = 0.0, // §4.5.12 samples taken\n    {s}__out: f64 = 0.0,\n",
                    .{ n, n },
                );
            },
            // Every `.static` and `.none` row: already handled above, or
            // (§9.17) writing the two unconditional fields and no per-unit
            // one at all.
            .none, .ddt, .idt, .idtmod, .transition, .slew, .last_crossing, .cross, .above, .timer, .bound_step, .discontinuity => {},
        }
    }
    // §5.6.1.2 path-integrated reactive latches (ngspice NIintegrate
    // semantics, mesaload.c:341-344): pb__k = ddt operand at the last
    // ACCEPTED solve, pq__k = Σ committed A·ΔB increments — the charge
    // base, FIXED across one Newton attempt. wb__/wq__ stage the current
    // iterate's values (updateState); stateCtl(.commit) latches them.
    // Zero defaults make the first committed increment A·(B−0) = A·B —
    // exactly ngspice MODEINITTRAN's qgs = capgs·vgs product seeding.
    for (0..self.core.prev_lo.len) |k| {
        try self.w("    pb__{d}: f64 = 0.0, // path_prev latch\n    wb__{d}: f64 = 0.0, // staged\n", .{ k, k });
    }
    for (0..self.core.acc_lo.len) |k| {
        try self.w("    pq__{d}: f64 = 0.0, // path_acc latch\n    wq__{d}: f64 = 0.0, // staged\n", .{ k, k });
    }
    // §5.10 event-assigned variables. LAST, so a model that gains one does
    // not move a single operator field, and the default is the DECLARED
    // initializer — the only evaluation that can observe it is the first,
    // before `updateState` has ever run.
    for (self.lowered.held_vars.items, 0..) |h, i| {
        // ponytail: a parameter-dependent initializer takes the parameter's
        // SPEC default, exactly like every §4.5 operator control argument
        // (`f64Expr`/`argF64`), because a struct field default is a comptime
        // value and a model card is not. Upgrade path: write it in
        // `initState`, which already takes a mutable `*Instance`.
        const init = self.an.foldConst(self.an.rv(h.init), 0, true);
        const v: f64 = if (init) |c| c.f else 0.0;
        if (h.ty == .integer) {
            try self.w("    {s}: i64 = {d}, // §5.10 held across evaluations\n", .{
                // Saturating like every other fold-side real→int cast —
                // an initializer of `1e300` must not panic the compiler.
                self.names.held_names[i], std.math.lossyCast(i64, @round(v)),
            });
        } else {
            try self.w("    {s}: f64 = {s}, // §5.10 held across evaluations\n", .{
                self.names.held_names[i], try fmtF64(self, v),
            });
        }
    }
    // FSM accepted/working twins — `stateCtl`'s accepted copy. Emitted
    // only for modules whose hook has an FSM half (`fsmStateCtl`), so a
    // plain cross-observer — or a path-latch model — carries no dead
    // fields.
    if (fsmStateCtl(self)) {
        for (self.lowered.held_vars.items, 0..) |h, i| {
            const init = self.an.foldConst(self.an.rv(h.init), 0, true);
            const v: f64 = if (init) |c| c.f else 0.0;
            if (h.ty == .integer) {
                try self.w("    {s}__acc: i64 = {d}, // stateCtl accepted copy\n", .{
                    self.names.held_names[i], std.math.lossyCast(i64, @round(v)),
                });
            } else {
                try self.w("    {s}__acc: f64 = {s}, // stateCtl accepted copy\n", .{
                    self.names.held_names[i], try fmtF64(self, v),
                });
            }
        }
        for (self.names.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            switch (u.op) {
                .cross, .above => try self.w(
                    "    {s}__prev__acc: f64 = 0.0, // stateCtl accepted copy\n",
                    .{self.names.unit_names[i]},
                ),
                .none, .ddt, .idt, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
            }
        }
    }
    // Temperature/parameter-only prep, hoisted out of the per-eval path:
    // `precompute` writes these once per model-card/temperature write.
    // LAST, for the same insert-tolerance reason as the held block above.
    for (0..self.pc.vals.len) |k| {
        try self.w("    pc__{d}: f64 = 0.0, // precompute\n", .{k});
    }
    // §4.5.15 the solve-independent clamp arguments, latched by
    // `cg_limit.emitPrep` off the same `precompute` call. After `pc__`
    // because `emitPrep`'s core evaluation READS those fields.
    for (0..self.lp.vals.len) |k| {
        try self.w("    lp__{d}: f64 = 0.0, // $limit prep\n", .{k});
    }
    // The core's hoisted PREFIX (`planHoistPrefix`): the solve-independent
    // opening of the shared body, latched off the same `precompute` core
    // call the `lp__` fields ride. `hp_ok` is what the core tests, so it is
    // cleared on entry to `precompute` and set only once the values behind
    // it belong to the model card now in force.
    if (self.hp.real != 0) try self.w("    hp: [{d}]f64 = @splat(0.0), // core prefix cache\n", .{self.hp.real});
    if (self.hp.vals.len != self.hp.real)
        try self.w("    hpi: [{d}]i64 = @splat(0),\n", .{self.hp.vals.len - self.hp.real});
    if (self.hp.vals.len != 0) try self.w("    hp_ok: i64 = 0,\n", .{});
    try self.w("}};\n\n", .{});
}

/// The temperature hoist's writer: one flat body computing every `pc__<k>`
/// field from `model` and `inst.temperature` alone (see planPrecompute).
///
/// Emitted through the SAME plan/renderInst pipeline as the core, with the
/// pc roots standing in for the live-outs, so slot/inline decisions — and
/// with them the exact f64-vs-S composition of every value — reproduce
/// what the core used to emit inline. `P` supplies the S protocol with the
/// ARPice host Dual's value semantics; bit-identity of eval before/after
/// the hoist is the contract here (verified externally, /tmp/b4probe).
///
/// Flat on purpose (`plan.flat`): the slice admits only pure ops and the
/// two environment calls, so ascending value order IS a topological order
/// and no CFG needs reconstructing — a value guarded by an `if` in the
/// source is loop-free and total to compute, and an untaken guard's field
/// simply goes unread (same argument as the eager `sel`).
pub fn emitPrecompute(self: *Gen) Error!void {
    // §4.5.15's clamp-argument latch rides in this same function — it is the
    // same "once per model-card/temperature write" phase — so a model with
    // no `pc__` roots but a hoisted clamp argument still needs the body.
    const has_pc = self.pc.vals.len != 0;
    const has_lp = self.lp.vals.len != 0;
    // …and so does the core's hoisted prefix, off the same core call.
    const has_hp = self.hp.vals.len != 0;
    if (!has_pc and !has_lp and !has_hp) return;
    // `P`, not `R`, fills the hp latch below: eval reads those fields as
    // `S.con(...)`, so they must carry the HOST's value chain (see pscalar_txt).
    if (has_pc or has_hp) try self.out.appendSlice(self.gpa, pscalar_txt);

    // Plan the pc slice through the common-mode path: targets = pc_vals.
    // Skipped wholesale when there are none: `analyze` would clear the
    // live set for an empty target list and the `defer` would hand the
    // units back a `pc_on = true` that `planUnits` never set.
    const save_idx = self.plan.lo_idx;
    const save_vals = self.plan.lo_vals;
    if (has_pc) {
        self.plan.lo_idx = self.pc.idx;
        self.plan.lo_vals = self.pc.vals;
        self.plan.pc_on = false; // computing the fields, not reading them
        self.plan.flat = true;
        self.plan.display_unit = false;
        try self.plan.analyze(.undef, true);
    }
    defer if (has_pc) {
        self.plan.lo_idx = save_idx;
        self.plan.lo_vals = save_vals;
        self.plan.pc_on = true;
        self.plan.flat = false;
    };

    self.uses_model = false;
    self.uses_x = false;
    try self.w(
        \\/// Temperature/parameter-only prep (ngspice's `<dev>temp` phase, once
        \\/// instead of per eval). The host calls it after every model-card or
        \\/// temperature write, before the next solve.
        \\
    , .{});
    try self.w("pub fn precompute(inst: *Instance, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model) void {{\n", .{});
    try self.w("    @setFloatMode(.{t});\n", .{self.core.mode});
    if (has_pc) try self.w("    const S = P;\n", .{});
    self.float.strict = self.core.mode == .strict;
    // BEFORE the core call below, and not merely for tidiness: `precompute`
    // runs again on every parameter write and every `setTemp`, and a stale
    // `hp_ok` would make that call reload the OLD card's values and store
    // them straight back.
    if (has_hp) try self.w("    inst.hp_ok = 0;\n", .{});

    if (has_pc) {
        self.hoist_idx.clearRetainingCapacity();
        try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);
        // RPO blocks, statement order within — the def-before-use order the
        // structured emitter walks. Ascending VALUE order is not one: ifconv
        // and trivial-phi aliasing can point an operand at a later index.
        for (self.an.rpo) |bi| {
            for (self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]]) |inst| {
                const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
                if (!self.plan.needed[i] or self.plan.slot[i] == none_u32) continue;
                try self.w("    const t{d}: {s} = ", .{ self.plan.slot[i], gen_unit.zigTy(self.an.vty[i]) });
                try gen_render.renderInst(self, inst);
                try self.w(";\n", .{});
            }
        }
        for (self.pc.vals, 0..) |v, k| {
            const i = @intFromEnum(v);
            assert(self.plan.slot[i] != none_u32); // a target is never inlined
            try self.w("    inst.pc__{d} = t{d}.val();\n", .{ k, self.plan.slot[i] });
        }
    }
    assert(!self.uses_x); // pcClass excludes every §4.4 probe
    // §4.5.15 AFTER the `pc__` writes: `emitPrep`'s core call reads them.
    // It names both `model` and `inst`, so the unused-parameter patch below
    // must not fire once it has been emitted.
    try cg_limit.emitPrep(self);
    if (has_hp) {
        // The ONE evaluation of the prefix per model card; `hp_ok` is still 0
        // for it, which is what makes the region run rather than reload.
        // Through `P`, not `emitPrep`'s `R`: eval reads these fields back as
        // `S.con(...)`, so they must carry the host's value chain bit for bit
        // (`R` divides as a/b and routes exp/log through zDev*; the host's S
        // divides as a*(1/b)). The `$limit` latch stays on `R`: only `limit`,
        // which evaluates with `R` itself, reads it.
        try self.w(
            \\    var xp: [n_u]P = undefined;
            \\    for (&xp) |*p| p.* = P.con(0.0);
            \\    const mh = core(P, xp, model, inst);
            \\
        , .{});
        for (self.hp.vals, 0..) |v, j| {
            const f = self.core.lo_vals.len + j;
            if (self.an.vty[@intFromEnum(v)] == .int)
                try self.w("    inst.hpi[{d}] = mh.f{d};\n", .{ j - self.hp.real, f })
            else
                try self.w("    inst.hp[{d}] = mh.f{d}.v;\n", .{ j, f });
        }
        try self.w("    inst.hp_ok = 1;\n", .{});
    }
    if (has_lp or has_hp) self.uses_model = true;
    if (!self.uses_model) gen_unit.patchParam(self, at_model, "model".len);
    try self.w("}}\n\n", .{});
}

/// A module whose §5.10 event-HELD state is fed by `cross`/`above` edges
/// is a hysteresis FSM the transient can catch mid-step (a switch). It
/// gets `stateCtl` (contract.zig StateCtlOp): the driver rejects the
/// converged step whose accepted solution flipped the latch and shrinks
/// toward the crossing, so the conductance discontinuity lands SHARP —
/// which is what makes a piecewise-constant waveform interpolate
/// correctly onto ngspice's own output grid. Without the hook the flip
/// smears across whatever dt the integrator happened to carry
/// (devices/switch: one 0.8-of-full-scale sample against a 1e-11 match
/// everywhere else).
pub fn fsmStateCtl(self: *const Gen) bool {
    if (self.lowered.held_vars.items.len == 0) return false;
    for (self.names.units) |u| {
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => return true,
            .none, .ddt, .idt, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    return false;
}

/// Any path latch at all. The reactive lowering always plants prev+acc
/// pairs, but a source-level `$prev` site arrives alone — every gate that
/// keys the latch machinery (R text, state machine, core sweep, stateCtl)
/// tests this, not `acc_lo`, so a `$prev`-only model still gets its
/// updateState staging and commit advance.
pub fn pathLatches(self: *const Gen) bool {
    return self.core.acc_lo.len != 0 or self.core.prev_lo.len != 0;
}

/// §5.6.1.2 path-integrated reactive sites also ride `stateCtl`: the
/// driver's existing `.commit` calls (operating-point exit, transient
/// accepted step) are exactly the accepted-solve boundary the latches
/// advance on. They contribute nothing to `query` — the base moving is
/// the integrator's business, not a step-reject condition.
pub fn emitsStateCtl(self: *const Gen) bool {
    return fsmStateCtl(self) or pathLatches(self) or self.lowered.uses.contains(.newton_iter) or self.lowered.limit_slots.items.len != 0;
}

/// The hook body. `query` compares the HELD (discrete) state only; the
/// continuous cross histories are committed/reverted alongside so a
/// rejected attempt cannot leave a half-advanced edge test behind (which
/// would suppress the refire on the retry). Path latches commit `pb = wb`,
/// `pq += wq` (and zero `wq` so a commit with no fresh `updateState`
/// adds 0); on revert they need nothing — the base was never written
/// speculatively. Tag ORDER mirrors contract.StateCtlOp — the engine
/// converts by ordinal.
pub fn emitStateCtl(self: *Gen) Error!void {
    // ponytail: topology is fixed during emission; scan once for all three actions.
    const fsm = fsmStateCtl(self);
    try self.w(
        \\pub fn stateCtl(_: *const Model, inst: *Instance, {s}: *State, op: contract.StateCtlOp) bool {{
        \\    if (op == .query) {{
        \\        return
    , .{if (self.lowered.limit_slots.items.len != 0 or self.lowered.uses.contains(.newton_iter)) "state" else "_"});
    var first = true;
    for (self.names.held_names) |n| {
        if (!fsm) break;
        try self.w("{s}(inst.{s} != inst.{s}__acc)", .{ if (first) " " else "\n            or ", n, n });
        first = false;
    }
    if (first) try self.w(" false", .{});
    try self.w(
        \\;
        \\    }}
        \\    if (op == .commit) {{
        \\
    , .{});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        state.limiter_previous = inst.limiter_previous;\n",
        .{},
    );
    if (self.lowered.uses.contains(.newton_iter)) try self.w(
        "        state.newton_iteration = inst.newton_iteration;\n",
        .{},
    );
    for (0..self.core.prev_lo.len) |k| try self.w("        inst.pb__{d} = inst.wb__{d};\n", .{ k, k });
    for (0..self.core.acc_lo.len) |k| try self.w("        inst.pq__{d} += inst.wq__{d};\n        inst.wq__{d} = 0.0;\n", .{ k, k, k });
    if (fsm) for (self.names.held_names) |n| try self.w("        inst.{s}__acc = inst.{s};\n", .{ n, n });
    for (self.names.units, 0..) |u, i| {
        if (!fsm) break;
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => try self.w("        inst.{s}__prev__acc = inst.{s}__prev;\n", .{ self.names.unit_names[i], self.names.unit_names[i] }),
            .none, .ddt, .idt, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    try self.w("    }} else {{\n", .{});
    if (self.lowered.limit_slots.items.len != 0) try self.w(
        "        inst.limiter_previous = state.limiter_previous;\n",
        .{},
    );
    if (self.lowered.uses.contains(.newton_iter)) try self.w(
        "        inst.newton_iteration = state.newton_iteration;\n",
        .{},
    );
    if (fsm) for (self.names.held_names) |n| try self.w("        inst.{s} = inst.{s}__acc;\n", .{ n, n });
    for (self.names.units, 0..) |u, i| {
        if (!fsm) break;
        if (u.role != .analog_op) continue;
        switch (u.op) {
            .cross, .above => try self.w("        inst.{s}__prev = inst.{s}__prev__acc;\n", .{ self.names.unit_names[i], self.names.unit_names[i] }),
            .none, .ddt, .idt, .idtmod, .absdelay, .transition, .slew, .last_crossing, .laplace, .zi, .timer, .bound_step, .discontinuity => {},
        }
    }
    try self.w(
        \\    }}
        \\    return false;
        \\}}
        \\
        \\
    , .{});
}
