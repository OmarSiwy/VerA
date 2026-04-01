//! Dispatchers: §5.6 residual assembly, §1.3.1.2 reference directions.
//!
//! In: the unit functions. Out: `eval` (resistive) and `q` (reactive), stamping each unit's
//! result into the residual and Jacobian rows of its nodes.
//!
//! LRM clauses this file's code cites: §1.3.1.2, §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.3, §4.6.4.6, §5.4.2.1, §5.6, §5.6.1.2, §5.6.1.3, §5.6.6, §9.4.
//!
//! Cut verbatim from `codegen.zig`. Functions take `self: *Gen` and are called
//! directly, `gen_dispatch.f(self, ...)`; `codegen.zig` aliases only what other modules call.

const std = @import("std");
const plan_jac = @import("plan/jac.zig");
const plan_noise = @import("plan/noise.zig");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_file = @import("file.zig");
const gen_setup = @import("setup.zig");
const gen_state = @import("state.zig");
const gen_unit = @import("unit.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const assert = codegen.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

// =======================================================================
// Dispatchers — §5.6 residual assembly, §1.3.1.2 reference directions
// =======================================================================

pub fn emitDispatchers(self: *Gen) Error!void {
    self.pat[0] = try self.arena.alloc(u64, self.names.n_u);
    self.pat[1] = try self.arena.alloc(u64, self.names.n_u);
    @memset(self.pat[0], 0);
    @memset(self.pat[1], 0);
    self.rows = .{ 0, 0 };
    if (self.names.n_u <= 64) for (&self.lin) |*l| {
        l.* = try self.arena.alloc(f64, self.names.n_u * self.names.n_u);
        @memset(l.*, 0);
    };

    try emitResidual(self, false);
    const any_q = anyQ(self);
    if (any_q) {
        qPattern(self);
        try emitQ(self);
        try emitFused(self);
        try emitQSites(self);
    }
    // AFTER the dispatchers: the pattern is what they emitted, accumulated
    // row by row as each was written. Zig has no declaration order, so the
    // constant reading last in the file is the one written last.
    try emitPattern(self, any_q);
    try emitDisplay(self);
}

/// Does any charge site get a slot — i.e. is `q` emitted?
pub fn anyQ(self: *const Gen) bool {
    return self.qs.sites.len != 0;
}

/// `q_pattern`/`q_rows` off the stamps: row `ru` is written when a site
/// stamps it, and its columns are the union of those sites' dependences.
fn qPattern(self: *Gen) void {
    for (self.qs.stamps) |st| {
        const k = self.qs.sites[st.slot];
        const bits = self.an.unknownDeps(self.lowered.charge_sites.items[k].final);
        if (self.pat[1].len != 0) self.pat[1][st.row] |= bits;
        self.rows[1] |= uBit(st.row);
    }
}

/// The core field holding slot `j`'s charge.
fn siteField(self: *const Gen, j: usize) u32 {
    const k = self.qs.sites[j];
    return self.core.lo_idx[@intFromEnum(self.an.rv(self.lowered.charge_sites.items[k].final))];
}

/// `[n_q]S{ m.f<a>, m.f<b>, ... }`: every site's charge, in slot order.
pub fn writeSites(self: *Gen) Error!void {
    try self.b("[n_q]S{{", .{});
    for (0..self.qs.sites.len) |j| try self.b("{s}m.f{d}", .{ if (j == 0) " " else ", ", siteField(self, j) });
    try self.b(" }}", .{});
}

/// §5.6.1.2 the reactive residual, ONE CHARGE PER SITE (`plan/qsite.zig`):
/// `q_stamps` says which rows each enters, so a host tapes and truncation-
/// checks each charge on its own and stamps the rows it always stamped.
fn emitQ(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6.1.2 the charges, one per `ddt` site (`n_q`, `q_stamps`, `q_lte`);
        \\/// the host differentiates each and stamps it into its rows.
        \\pub fn q(comptime S: type, x: [n_u]S, model: *const Model, inst: InstancePtr, _: f64) [n_q]S {{
        \\    const m = @call(.always_inline, core, .{{ S, x, model, inst{s} }});
        \\
    , .{self.heldArg(false)});
    try self.w("    return ", .{});
    try writeSites(self);
    try self.w(";\n}}\n\n", .{});
}

/// `n_q`, `q_stamps`, `q_lte` and `q_site_pattern` — see `contract.QSites`.
fn emitQSites(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6.1.2 how many charge sites `q` returns.
        \\pub const n_q: usize = {d};
        \\
        \\/// Row `row` of the reactive residual is `Σ sign · q[site]` over its
        \\/// entries. Sorted by (row, site).
        \\pub const q_stamps = [_]contract.QStamp(U){{
        \\
    , .{self.qs.sites.len});
    for (self.qs.stamps) |st| try self.w("    .{{ .site = {d}, .row = .{s}, .sign = {s} }},\n", .{
        st.slot, self.names.u_names[st.row], try gen_file.fmtF64(self, st.sign),
    });
    try self.w(
        \\}};
        \\
        \\/// Which charge sites join the host's local-truncation-error check
        \\/// (VerA's `vera_lte` attribute; all of them unless a model says so).
        \\pub const q_lte = [n_q]bool{{
    , .{});
    for (self.qs.sites, 0..) |k, j| try self.w("{s}{}", .{ if (j == 0) " " else ", ", self.lowered.charge_sites.items[k].lte });
    try self.w(" }};\n\n", .{});
    if (self.names.n_u > 64) return;
    try self.w("/// Bit `cu` of `q_site_pattern[k]` is set when `∂q[k]/∂x[cu]` can be nonzero.\npub const q_site_pattern = [n_q]u64{{\n", .{});
    for (self.qs.sites) |k| try self.w("    0x{x:0>16},\n", .{self.an.unknownDeps(self.lowered.charge_sites.items[k].final)});
    try self.w("}};\n\n", .{});
}

/// §5.6 structural Jacobian: which columns of each residual row can be
/// nonzero. The host's local Jacobian is `n_u × n_u` by construction, but a
/// device fills only part of it — mos1 fills 21 of 64 resistive and 16 of
/// 64 reactive entries — and the rest are `+= 0.0` into a matrix slot,
/// per instance, per Newton iteration. A comptime-visible constant lets the
/// host delete those stamps instead of executing them.
///
/// OMITTED above 64 unknowns rather than widened: `Analysis.deps` is one
/// u64 per Value for exactly that reason, and a host that does not find
/// this declaration scatters densely, which is what it did before.
pub fn emitPattern(self: *Gen, any_q: bool) Error!void {
    if (self.names.n_u > 64) return;
    try self.w(
        \\/// §5.6 structural Jacobian: bit `cu` of `jac_pattern[ru]` is set
        \\/// when `∂eval(x)[ru]/∂x[cu]` can be nonzero. A clear bit is a
        \\/// stamp with no physics behind it, and the host may drop it at
        \\/// compile time. Over-approximate: a set bit costs a stamp that
        \\/// happens to be zero, never a missing matrix entry.
        \\
    , .{});
    try emitPatternRows(self, "jac_pattern", self.pat[0]);
    try emitWrittenRows(self, "jac_rows", "eval", self.rows[0]);
    if (!any_q) return;
    try self.w("/// Same, for `q`'s reactive residual (`dQ/dx`).\n", .{});
    try emitPatternRows(self, "q_pattern", self.pat[1]);
    try emitWrittenRows(self, "q_rows", "q", self.rows[1]);
}

/// §5.6 which residual ROWS the emitted half ever writes. A row outside
/// this set is `S.con(0.0)` at every bias, every time, so a host may drop
/// the whole row — residual stamp, charge tape entry and all — and not just
/// the Jacobian columns `jac_pattern` clears.
///
/// It exists because the host CANNOT infer it from the pattern. `patRow`
/// ORs `unknownDeps(value)` into the column mask, so a term with no unknown
/// in it leaves the mask clear while still writing the row — `isource` has
/// `jac_pattern` all zero and stamps its DC current into both rows. Reading
/// a clear pattern row as "identically zero" deletes it.
pub fn emitWrittenRows(self: *Gen, name: []const u8, half: []const u8, mask: u64) Error!void {
    try self.w(
        \\/// §5.6 which residual rows `{s}` ever WRITES: bit `ru` set means
        \\/// `res[ru]` is assigned somewhere in it. A CLEAR bit is the only
        \\/// licence to skip a row's stamp entirely — a clear PATTERN row is
        \\/// not, because a term that depends on no unknown writes the row
        \\/// with an empty column mask. Over-approximate the same way: a set
        \\/// bit costs a stamp that happens to be zero.
        \\pub const {s}: u64 = 0x{x:0>16};
        \\
        \\
    , .{ half, name, mask });
}

pub fn emitPatternRows(self: *Gen, name: []const u8, rows: []const u64) Error!void {
    try self.w("pub const {s} = [n_u]u64{{\n", .{name});
    for (rows, 0..) |m, i| try self.w("    0x{x:0>16}, // {s}\n", .{ m, self.names.u_names[i] });
    try self.w("}};\n\n", .{});
}

/// §9.4 the one entry point a host calls to run the module's display tasks.
///
/// Separate from `eval` on purpose. The prints live in a unit of their own,
/// so a caller decides WHEN text happens instead of getting it once per
/// Newton iteration as a side effect of the residual — and a device built
/// with `display == .drop` simply has no such declaration.
///
/// The unit returns an `S` (every unit does); it is the sum of the display
/// calls' zero results and is discarded here.
pub fn emitDisplay(self: *Gen) Error!void {
    if (self.jobs.display_name.len == 0) return;
    try self.w(
        \\/// §9.4 run this module's display tasks once, in source order.
        \\pub fn display(comptime S: type, x: [n_u]S, model: *const Model, inst: InstancePtr, _: f64) void {{
        \\    _ = {s}(S, x, model, inst);
        \\}}
        \\
        \\
    , .{self.jobs.display_name});
}

pub fn emitResidual(self: *Gen, react: bool) Error!void {
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;

    // Same reserve-and-backpatch as `emitUnit`. `res` needs a fourth slot:
    // with no stamps nothing assigns to it, and Zig rejects a `var` that is
    // never mutated. Here the shorter spelling is the one that gets padded.
    try self.w("/// {s}\n", .{
        if (react) "§5.6.1.2 reactive residual (charge/flux); the host differentiates it" else "§5.6 resistive residual: KCL at every unknown (§1.3.2)",
    });
    try self.w("pub fn {s}(comptime S: type, ", .{if (react) "q" else "eval"});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr, _: f64) [n_u]S {{\n    ", .{});
    const at_mut = self.out.items.len;
    try self.w("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
    const stamps = try emitStamps(self, react);

    if (!self.uses_x) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.uses_model) gen_unit.patchParam(self, at_model, "model".len);
    if (!self.uses_inst) gen_unit.patchParam(self, at_inst, "inst".len);
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.w("    return res;\n}}\n\n", .{});
}

/// The §5.6 stamp rows for one residual half, into a `res` the caller has
/// already declared. Accumulates `uses_x`/`uses_model`/`uses_inst` and
/// returns the row count, so the caller can back-patch its own signature.
///
/// Split out of `emitResidual` so `emitFused` can emit BOTH halves against
/// one `core` call without restating any of this.
pub fn emitStamps(self: *Gen, react: bool) Error!u32 {
    var stamps: u32 = 0;
    // Which half `patRow` accumulates into. `eval`/`q` and `evalQ` emit the
    // same rows, so the second pass ORs in bits the first already set.
    self.pat_react = react;
    // `lin` is a replay, not an accumulation: `evalQ` re-emits the same
    // stamps, and adding them twice would double every coefficient. The
    // guarded stamps are eval-only (`emitSwitchRow`), so eval resets them.
    @memset(self.lin[@intFromBool(react)], 0);
    if (!react) self.guarded.clearRetainingCapacity();
    // ONE core evaluation per residual, not one per contribution. LLVM does
    // not recover this by itself — measured, see `plan_core.plan`'s header — so
    // the number of times the model runs is decided here, in the emitter.
    var opened = false;
    if (self.lowered.table_effect != .f_zero) {
        opened = true;
        self.uses_x = true;
        self.uses_model = true;
        self.uses_inst = true;
        self.core_wanted = true;
        if (!self.core_hoisted) try self.b("    const m = @call(.always_inline, core, .{{ S, x, model, inst{s} }});\n", .{self.heldArg(false)});
        try self.b("    _ = m.f{d};\n", .{coreIdx(self, self.an.rv(self.lowered.table_effect)).?});
    }

    for (self.lowered.contributions.items, 0..) |c, i| {
        const val = if (react) self.an.rv(c.react_val) else self.an.rv(c.resist_val);
        // §5.6.1.3 a `.flow` entry whose branch row is runtime-selected is
        // consumed BY that row (`I_b − value`); its KCL current is the ±I_b
        // the potential entry already stamps. Stamping the value here too
        // would inject it twice — once through the unknown, once directly.
        if (c.kind == .direct and c.access == .flow and plan_topo.flowIsMerged(self.input(), i)) continue;
        // §5.6.1.3's three-way rule is decided per cycle. `.on`/`.off` fold
        // to today's static behaviour; `.runtime` keeps the row alive in
        // EVERY case, because the open-circuit form (`res[u] = I_b`) is
        // what pins the branch current when nothing is retained.
        const run_pot: ?plan_topo.Retention = if (c.kind == .direct and c.access == .potential) ret: {
            const r = plan_topo.retention(self.input(), c);
            break :ret if (r == .runtime) r else null;
        } else null;
        // A zero half normally contributes nothing, and §5.6.1.3's
        // `discardOpposite` relies on that: it writes `.f_zero` to BOTH
        // `acc.resist` and `acc.react`, so a discarded contribution still
        // emits no row at all, in either residual.
        //
        // ONE shape is an exception, and it is the inductor. A §5.6
        // POTENTIAL contribution's resistive row is `V(hi) - V(lo) - c`,
        // which is the DEFINING equation of its branch flow unknown, and
        // that same row is where the unknown enters KCL at hi and lo
        // (§1.3.1.2). `V(l) <+ L*ddt(I(l))` has `resist_val == .f_zero`
        // and a live `react_val`, so skipping it left the flow column with
        // no pivot and the inductor's current out of every node equation —
        // exit 0, no diagnostic. The row is still needed; only `c` is zero,
        // and at DC `V(hi) - V(lo) = 0` is exactly what an inductor is.
        //
        // A runtime-selected row's q half is live only when SOME selectable
        // form has a flux: its own react, or the switch partner's.
        const partner_react: Mir.Value = if (run_pot != null) blk: {
            const j = plan_topo.switchFlowOf(self.input(), i) orelse break :blk .f_zero;
            break :blk self.an.rv(self.lowered.contributions.items[j].react_val);
        } else .f_zero;
        const live = if (react)
            val != .f_zero or partner_react != .f_zero
        else
            val != .f_zero or run_pot != null or
                (c.access == .potential and self.an.rv(c.react_val) != .f_zero);
        if (!live) continue;
        self.uses_x = true;
        // `model`/`inst` are read through `core` alone, so a residual whose
        // every live row has a zero value never opens one — and an unused
        // parameter is a compile error in the HOST's build, not here. A
        // runtime-selected row always opens it: its retention flag is a
        // core field by construction (`buildJobs`).
        if (val != .f_zero or run_pot != null) {
            self.uses_model = true;
            self.uses_inst = true;
            if (!opened) {
                opened = true;
                self.core_wanted = true;
                if (!self.core_hoisted) {
                    try self.ind(1);
                    try self.b("const m = @call(.always_inline, core, .{{ S, x, model, inst{s} }});\n", .{self.heldArg(false)});
                }
            }
        }
        stamps += 1;
        try self.ind(1);
        try self.b("{{\n", .{});
        try self.ind(2);
        // `.f_zero` is rendered inline, never planned into `core` (see
        // `plan_core.plan`), so there is no `m.f<k>` to read for it.
        if (val == .f_zero)
            try self.b("const c = S.con(0.0);\n", .{})
        else
            try self.b("const c = m.f{d};\n", .{self.core.lo_idx[@intFromEnum(val)]});
        if (c.kind == .indirect) {
            // §5.6.7 nullor: `out` is driven by a source whose current is
            // the unknown `ib`, and the row is the CONSTRAINT alone —
            // `<probe> − <equation>`. There is deliberately no V(hi,lo)
            // term: "the source voltage needs to be adjusted so that the
            // given equation is satisfied", so the branch voltage is free.
            // The ib column is filled only by the two KCL stamps, which
            // makes the local 2x2 block off-diagonal.
            const u = self.names.branch_u[i];
            assert(!react); // splitContribution never runs on an indirect
            try self.ind(2);
            try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
            try stamp(self, 2, c.hi, "add", "ib", uBit(u), u);
            try stamp(self, 2, c.lo, "sub", "ib", uBit(u), u);
            try self.ind(2);
            patRow(self, @intCast(u), self.an.unknownDeps(val));
            linClear(self, u);
            try self.b("res[@intFromEnum(U.{s})] = c;\n", .{self.names.u_names[u]});
            try self.ind(1);
            try self.b("}}\n", .{});
            continue;
        }
        switch (c.access) {
            .flow => if (plan_topo.flowOnlySignalFlowNet(self.input(), c)) |n| {
                // §1.3.4.2 a flow signal-flow net has no potential, so its
                // one unknown IS its flow and the contribution is that
                // unknown's defining equation. Stamping KCL here instead
                // would write a row with no `x` in it at all — `e = 0` —
                // because the quantity the row is about is not a potential
                // difference. See `flowOnlySignalFlowNet`.
                if (!react) {
                    try self.ind(2);
                    patRow(self, n, uBit(n) | self.an.unknownDeps(val));
                    linClear(self, n);
                    linTerm(self, n, n, 1);
                    try self.b("res[@intFromEnum(U.{0s})] = x[@intFromEnum(U.{0s})].sub(c);\n", .{self.names.u_names[n]});
                } else {
                    try self.ind(2);
                    patRow(self, n, self.an.unknownDeps(val));
                    linClear(self, n);
                    try self.b("res[@intFromEnum(U.{s})] = c.neg();\n", .{self.names.u_names[n]});
                }
            } else {
                // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                try stamp(self, 2, c.hi, "add", "c", self.an.unknownDeps(val), null);
                try stamp(self, 2, c.lo, "sub", "c", self.an.unknownDeps(val), null);
                // §5.6.6: the model also READS `I(hi,lo)`, so there is an
                // unknown for this current and it needs the row that says
                // what it IS — `x[u] − Σ contributions`. Accumulated here
                // (several contributions to one branch are one sum, §5.6.1)
                // and closed with the `+ x[u]` term after the loop.
                if (self.topo.freeFlowOf(c.hi, c.lo)) |f| {
                    assert(f.sourced);
                    try stamp(self, 2, @intCast(f.u), "sub", "c", self.an.unknownDeps(val), null);
                }
            },
            .potential => {
                // §5.6 branch relation: the branch current is its own
                // unknown; its row carries V(hi,lo) − <value>.
                if (run_pot) |ret| {
                    try emitSwitchRow(self, i, c, ret.runtime, react);
                } else if (!react) {
                    const u = self.names.branch_u[i];
                    try self.ind(2);
                    try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
                    try stamp(self, 2, c.hi, "add", "ib", uBit(u), u);
                    try stamp(self, 2, c.lo, "sub", "ib", uBit(u), u);
                    try self.ind(2);
                    patRow(self, @intCast(u), nodeBit(c.hi) | nodeBit(c.lo) | self.an.unknownDeps(val));
                    linBranch(self, u, c.hi, c.lo);
                    try self.b("res[@intFromEnum(U.{s})] = ", .{self.names.u_names[u]});
                    try nodeVoltage(self, c.hi);
                    try self.b(".sub(", .{});
                    try nodeVoltage(self, c.lo);
                    try self.b(").sub(c);\n", .{});
                } else {
                    const u = self.names.branch_u[i];
                    // §5.6.1.2 the reactive part of a branch relation is a
                    // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                    try self.ind(2);
                    patRow(self, @intCast(u), self.an.unknownDeps(val));
                    linClear(self, u);
                    try self.b("res[@intFromEnum(U.{s})] = c.neg();\n", .{self.names.u_names[u]});
                }
            },
        }
        try self.ind(1);
        try self.b("}}\n", .{});
    }

    // §5.4.2 the branch-flow unknowns no branch row defines — see
    // `FreeFlow` for the two shapes and the clauses. Both rows are purely
    // RESISTIVE: a §5.6.6 implicit sum's reactive half is already on this
    // row as `−Σ q` (the `sub` above ran for both halves), and a §5.4.2.1
    // probe is a short, which stores no charge.
    if (!react) for (self.topo.free_flows) |f| {
        self.uses_x = true;
        stamps += 1;
        if (f.sourced) {
            // Closes `res[u] = x[u] − Σ contributions`, whose `−Σ` half the
            // contribution loop accumulated.
            try self.ind(1);
            patRow(self, @intCast(f.u), uBit(f.u));
            linTerm(self, f.u, f.u, 1);
            try self.b("res[@intFromEnum(U.{0s})] = res[@intFromEnum(U.{0s})].add(x[@intFromEnum(U.{0s})]);\n", .{self.names.u_names[f.u]});
        } else {
            // §5.4.2.1 "The branch potential of a flow probe is zero (0)" —
            // the ammeter of Figure 5-1. Its current is a real branch
            // current and enters KCL at both ends, which is the half that
            // makes it a SHORT rather than an observation.
            try stamp(self, 1, f.hi, "add", try std.fmt.allocPrint(self.arena, "x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), uBit(f.u), f.u);
            try stamp(self, 1, f.lo, "sub", try std.fmt.allocPrint(self.arena, "x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), uBit(f.u), f.u);
            try self.ind(1);
            patRow(self, @intCast(f.u), nodeBit(f.hi) | nodeBit(f.lo));
            linBranch(self, f.u, f.hi, f.lo);
            try self.b("res[@intFromEnum(U.{s})] = ", .{self.names.u_names[f.u]});
            try nodeVoltage(self, f.hi);
            try self.b(".sub(", .{});
            try nodeVoltage(self, f.lo);
            try self.b(");\n", .{});
        }
    };

    // §5.4.3 `I(<p>)` = "the flow into a port of a module". By KCL that is
    // exactly what this module has just stamped at p, so the row reuses the
    // accumulation above instead of restating it:
    //
    //     eval:  res[flow(<p>)] = x[flow(<p>)] − res[p]
    //     q:     res[flow(<p>)] =              − res[p]
    //
    // Total residual x − (I_dc + d/dt q_p) = 0, so the REACTIVE half of the
    // port current rides along for free — §5.4.3's own diode example probes
    // a node that carries a `ddt` junction-capacitance contribution, and a
    // DC-only I(<a>) there would be silently wrong in transient.
    //
    // Emitted AFTER the contribution loop because it reads the finished
    // res[p]; that is also why there is no separate summation helper.
    for (self.lowered.port_probes.items) |pp| {
        self.uses_x = true;
        stamps += 1;
        try self.ind(1);
        // Reads the FINISHED res[port], so this row's columns are that
        // row's — already accumulated by the contribution loop above.
        patRow(self, pp.u, patOf(self, pp.port) | (if (react) 0 else uBit(pp.u)));
        try linPortProbe(self, pp.u, pp.port, !react);
        if (react) {
            try self.b("res[@intFromEnum(U.{s})] = res[@intFromEnum(U.{s})].neg();\n", .{
                self.names.u_names[pp.u], self.names.u_names[pp.port],
            });
        } else {
            try self.b("res[@intFromEnum(U.{0s})] = x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})]);\n", .{
                self.names.u_names[pp.u], self.names.u_names[pp.port],
            });
        }
    }

    return stamps;
}

/// §5.6 + §5.6.1.2 — both residuals from ONE model evaluation.
///
/// `eval` and `q` are each correct alone and each opens its own `core`, so
/// a host that needs both — every transient step does — ran the entire
/// model twice. That is an artifact of the API shape, not of the physics:
/// `plan_core.plan` already put every shared subexpression in one core whose
/// returned struct carries BOTH halves' targets (see its header), and the
/// two dispatchers just read different fields of it. Measured on a host
/// SPICE: `<module>__common__core` appeared twice per instance evaluation
/// with identical inclusive cost, against device evaluation that was ~90%
/// of a transient. Halving it needs no new analysis, only this entry point.
///
/// Additive on purpose. `eval` and `q` are unchanged and still the §3.1
/// contract; DC wants the resistive half alone and should keep calling
/// `eval`. `evalQ` exists only when there IS a reactive half.
pub fn emitFused(self: *Gen) Error!void {
    self.uses_x = false;
    self.uses_model = false;
    self.uses_inst = false;
    self.core_wanted = false;
    self.core_hoisted = true;
    defer self.core_hoisted = false;

    try self.w(
        \\/// §5.6 + §5.6.1.2 both residuals from ONE core evaluation.
        \\/// Equivalent to `.{{ .res = eval(...), .q = q(...) }}`, at half the cost.
        \\
    , .{});
    try self.w("pub fn evalQ(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]S, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: InstancePtr, _: f64) struct {{ res: [n_u]S, q: [n_q]S }} {{\n", .{});
    // Reserved: the hoisted `core` line is INSERTED here afterwards, once
    // both halves have said whether either wants one. Every offset taken
    // above is before this point, so none of them move.
    const at_core = self.out.items.len;

    try self.ind(1);
    try self.b("const rr = blk: {{\n", .{});
    try self.ind(2);
    const at_mut = self.out.items.len;
    try self.b("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
    self.ind_base = 1;
    const stamps = try emitStamps(self, false);
    self.ind_base = 0;
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.ind(2);
    try self.b("break :blk res;\n", .{});
    try self.ind(1);
    try self.b("}};\n", .{});
    // §5.6.1.2 the charges, one per site, off the same core.
    self.uses_x = true;
    self.uses_model = true;
    self.uses_inst = true;
    self.core_wanted = true;
    try self.b("    return .{{ .res = rr, .q = ", .{});
    try writeSites(self);
    try self.b(" }};\n}}\n\n", .{});

    // `core_wanted` implies all three are used: `emitStamps` sets `uses_x`
    // for every live row and `uses_model`/`uses_inst` on the same branch
    // that opens the core, so this can never reference a patched-out `_`.
    if (self.core_wanted)
        try self.out.insertSlice(self.gpa, at_core, try std.fmt.allocPrint(self.arena, "    const m = @call(.always_inline, core, .{{ S, x, model, inst{s} }});\n", .{self.heldArg(false)}));

    if (!self.uses_x) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.uses_model) gen_unit.patchParam(self, at_model, "model".len);
    if (!self.uses_inst) gen_unit.patchParam(self, at_inst, "inst".len);
}

/// §5.6.1.3 the runtime-selected branch row — §5.6.5's switch branch, and
/// the clause's third ("otherwise the branch is an open circuit") case for
/// a lone conditional potential contribution, which used to be emitted as
/// an unconditional `V(hi,lo) − c` row: a phantom 0 V short on the arm
/// that never executed.
///
/// The matrix STRUCTURE stays constant — the standard compact-model shape
/// for a switch branch: the branch always carries its flow unknown I_b,
/// stamped ±I_b into the two KCL rows, and only the branch row's CONTENT
/// is selected per cycle on the retention flags lowering carried beside
/// the accumulators:
///
///     V retained this cycle:  res[u] = V(hi) − V(lo) − c_V   (potential source)
///     else I retained:        res[u] = I_b − c_I             (flow source)
///     else:                   res[u] = I_b                   (open: pins I_b = 0)
///
/// `S.sel` carries the winner's dual, so the Jacobian switches coherently
/// with the row: ±1 on the node columns for the potential form, 1 on the
/// I_b column (and −∂c_I/∂x) for the flow form, a bare 1 on I_b for the
/// open circuit — never singular. In the q residual the same select runs
/// over the fluxes (−φ, §5.6.1.2), the open case contributing none.
///
/// The flow form's ±c_I KCL stamps are NOT emitted (`flowIsMerged`): the
/// retained flow reaches KCL through I_b, which the row pins to c_I.
///
/// EXCEPT on a COLLAPSIBLE branch (`collapsePairs`), where the structure is
/// not constant, because `collapse` deletes I_b from the host's maps in
/// BOTH cases and contract.zig's `collapse_applied` says so. The row is
/// then split on the retention flag — a `buildFree` value, fixed for the
/// whole simulation, so a real `if` and not an `S.sel`:
///
///   flag set (0 V arm, dead short): the host aliased hi, lo and I_b onto
///     one unknown, so ±I_b and `V(hi) − V(lo)` are stamps that ADD AND
///     SUBTRACT THE SAME SLOT. "They cancel exactly" is false — float
///     addition into a shared accumulator is not associative, and I_b there
///     is a node VOLTAGE, so `3.5e-19 + (−0.2) + (−0.2) + 0.2 + 0.2 == 0`
///     erases a substrate leak that was already in the row. A host that
///     applied the aliases therefore gets no stamps at all; one that did
///     not keeps the full branch equations for standalone evaluation.
///   flag clear: I_b does not exist, so nothing can pin it. The branch is
///     a plain conductance and its flow reaches KCL directly, exactly like
///     an unswitched `.flow` contribution — `switchOpen` is that value.
///
/// THE GUARD (`contract.JacWhen`). On a collapsible branch whose flag is a
/// function of the card alone (`CollapsePair.card`), the flag-set arm's
/// coefficients ARE constants per (model card, host): ±1 for ib in the hi
/// and lo rows, ±1 for V(hi) and V(lo) in the branch row, nothing in q. They
/// leave as `jac_const` entries guarded by the published `Model` field, and
/// ib keeps no lane — it is read nowhere else (`collapsePairs` refuses a
/// probed flow). The flag-clear arm's `flow` is a core value whose lanes
/// the core already marked. Any other runtime row keeps every lane.
pub fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void {
    const u = self.names.branch_u[i];
    const partner = plan_topo.switchFlowOf(self.input(), i);
    const split = collapsible(self, i);
    const guard = guardOf(self, i);
    // Every coefficient on this row, and ib's in KCL, is picked per cycle by
    // a runtime flag — and on a collapsible branch by the host's S as well.
    // None is a constant, so every unknown it names keeps a lane, and so
    // does whatever the row held before a conditional overwrite. Unless the
    // guard above states them.
    if (guard) |k| {
        if (!react) {
            try guardTerm(self, c.hi, u, 1, k);
            try guardTerm(self, c.lo, u, -1, k);
            try guardTerm(self, u, c.hi, 1, k);
            try guardTerm(self, u, c.lo, -1, k);
        }
    } else self.deriv_reads |= uBit(u) | nodeBit(c.hi) | nodeBit(c.lo);
    linDynamic(self, u);
    const d: u32 = if (split) 4 else 2;
    if (split) {
        try self.ind(2);
        try self.b("if (", .{});
        try coreRef(self, flag);
        if (self.an.vty[@intFromEnum(self.an.rv(flag))] == .int)
            try self.b(" != 0) {{\n", .{})
        else
            try self.b(".val() != 0.0) {{\n", .{});
        try self.ind(3);
        try self.b("if (comptime !(@hasDecl(S, \"collapse_applied\") and S.collapse_applied)) {{\n", .{});
    }
    if (!react) {
        try self.ind(d);
        try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
        // Guarded: the constant is `guardTerm`'s, not an unconditional `lin`.
        const col: ?u32 = if (guard == null) u else null;
        try stamp(self, d, c.hi, "add", "ib", uBit(u), col);
        try stamp(self, d, c.lo, "sub", "ib", uBit(u), col);
        try self.ind(d);
        patRow(self, @intCast(u), uBit(u) | nodeBit(c.hi) | nodeBit(c.lo) | switchRowDeps(self, i, c, react));
        try self.b("res[@intFromEnum(U.{s})] = S.sel(", .{self.names.u_names[u]});
        try coreRef(self, flag);
        try self.b(", ", .{});
        try nodeVoltage(self, c.hi);
        try self.b(".sub(", .{});
        try nodeVoltage(self, c.lo);
        try self.b(").sub(c), ", .{});
        try switchElse(self, partner, react);
        try self.b(");\n", .{});
    } else {
        try self.ind(d);
        patRow(self, @intCast(u), uBit(u) | switchRowDeps(self, i, c, react));
        try self.b("res[@intFromEnum(U.{s})] = S.sel(", .{self.names.u_names[u]});
        try coreRef(self, flag);
        try self.b(", c.neg(), ", .{});
        try switchElse(self, partner, react);
        try self.b(");\n", .{});
    }
    if (split) {
        try self.ind(3);
        try self.b("}}\n", .{});
        try self.ind(2);
        try self.b("}} else {{\n", .{});
        try self.ind(3);
        try self.b("const flow = ", .{});
        try switchOpen(self, partner, react);
        try self.b(";\n", .{});
        const bits = switchRowDeps(self, i, c, react);
        try stamp(self, 3, c.hi, "add", "flow", bits, null);
        try stamp(self, 3, c.lo, "sub", "flow", bits, null);
        try self.ind(2);
        try self.b("}}\n", .{});
    }
}

/// Is potential contribution `i` one `collapse` aliases away? Keyed on the
/// branch-flow unknown, which `contribIndex` makes unique per branch.
pub fn collapsible(self: *const Gen, i: usize) bool {
    const u = self.names.branch_u[i];
    if (u == none_u32) return false;
    for (self.topo.cpairs) |p| if (p.flow_u == u) return true;
    return false;
}

/// The `cpairs` index whose card-only flag guards contribution `i`'s
/// constants (`emitSwitchRow`), or null. Above 64 unknowns there is no
/// table to put them in.
fn guardOf(self: *const Gen, i: usize) ?u32 {
    const u = self.names.branch_u[i];
    if (u == none_u32 or self.names.n_u > 64) return null;
    for (self.topo.cpairs, 0..) |p, k| if (p.flow_u == u) return if (p.card) @intCast(k) else null;
    return null;
}

/// One guarded constant: `g` at (row, col) of eval, under pair `k`'s guard.
/// Ground has no row and no column.
fn guardTerm(self: *Gen, row: u32, col: u32, g: f64, k: u32) Error!void {
    if (row == Lower.ground or col == Lower.ground) return;
    try self.guarded.append(self.arena, .{ .row = row, .col = col, .g = g, .c = 0, .when = k });
}

/// `<flow unknown>__retained`: the `Model` field `derive` publishes pair
/// `k`'s retention flag in, and the name a guarded `jac_const` entry cites.
pub fn guardField(self: *const Gen, k: u32) Error![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}__retained", .{self.names.u_names[self.topo.cpairs[k].flow_u]});
}

/// The value the branch row would have PINNED I_b to, for the arm where
/// I_b no longer exists: the partner's retained flow, or zero when nothing
/// is retained (§5.6.1.3's open circuit). `switchElse` writes the same
/// three cases as a residual — `I_b − c` and `−φ` — and this is that
/// residual solved for I_b, so the signs are the plain `.flow` stamp's.
pub fn switchOpen(self: *Gen, partner: ?usize, react: bool) Error!void {
    const j = partner orelse return self.b("S.con(0.0)", .{});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        .off => try self.b("S.con(0.0)", .{}),
        .on => try coreRef(self, fv),
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            try self.b(", ", .{});
            try coreRef(self, fv);
            try self.b(", S.con(0.0))", .{});
        },
    }
}

/// The not-a-potential-source-this-cycle half of a selected branch row:
/// the flow form when the switch partner retained one, the open circuit
/// otherwise. `react` picks the residual: I_b/current for eval, flux for q.
pub fn switchElse(self: *Gen, partner: ?usize, react: bool) Error!void {
    const open: []const u8 = if (react) "S.con(0.0)" else "ib";
    const j = partner orelse return self.b("{s}", .{open});
    const f = self.lowered.contributions.items[j];
    const fv = self.an.rv(if (react) f.react_val else f.resist_val);
    switch (plan_topo.retention(self.input(), f)) {
        // Discarded on every path: the partner entry is dead and the else
        // case is §5.6.1.3's open circuit.
        .off => try self.b("{s}", .{open}),
        // Unreachable by construction (a runtime potential flag implies a
        // conditional discard of the partner), but the general form is
        // correct if lowering ever changes: the flow is always retained.
        .on => if (react) {
            try coreRef(self, fv);
            try self.b(".neg()", .{});
        } else {
            try self.b("ib.sub(", .{});
            try coreRef(self, fv);
            try self.b(")", .{});
        },
        .runtime => |fw| {
            try self.b("S.sel(", .{});
            try coreRef(self, fw);
            if (react) {
                try self.b(", ", .{});
                try coreRef(self, fv);
                try self.b(".neg(), {s})", .{open});
            } else {
                try self.b(", ib.sub(", .{});
                try coreRef(self, fv);
                try self.b("), {s})", .{open});
            }
        },
    }
}

/// One value as the residual reads it: a core field, or the inline zero
/// `plan_core.plan` never plans (`.f_zero` has no `m.f<k>`).
pub fn coreRef(self: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return self.b("S.con(0.0)", .{});
    try self.b("m.f{d}", .{self.core.lo_idx[@intFromEnum(v)]});
}

/// `col` names the unknown when `val` is exactly `x[col]` — a ±1 term whose
/// coefficient `Gen.lin` records — and is null for a core value, whose
/// columns are all lanes `renderValueRef` already marked.
pub fn stamp(self: *Gen, depth: u32, node: u16, opx: []const u8, val: []const u8, bits: u64, col: ?u32) Error!void {
    if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
    patRow(self, node, bits);
    if (col) |k| linTerm(self, node, k, if (std.mem.eql(u8, opx, "add")) 1 else -1);
    try self.ind(depth);
    try self.b("res[@intFromEnum(U.{0s})] = res[@intFromEnum(U.{0s})].{1s}({2s});\n", .{
        self.names.u_names[node], opx, val,
    });
}

/// Row `node` gained a term whose derivative lives in `bits`. Ground has no
/// equation, so it has no row and no pattern. `pat_react` is set by the
/// residual half currently emitting, so every writer of `res[...]` records
/// its columns with one call beside the line that emits them — and, in
/// `rows`, the fact that it wrote the row at all, whatever the columns are.
pub fn patRow(self: *Gen, node: u16, bits: u64) void {
    if (node == Lower.ground) return;
    if (self.pat[@intFromBool(self.pat_react)].len == 0) return;
    self.pat[@intFromBool(self.pat_react)][node] |= bits;
    self.rows[@intFromBool(self.pat_react)] |= uBit(node);
}

/// Row `row` of the half being emitted gains `k · x[col]`. The two `Gen.lin`
/// writers below and this one mirror the `res[...]` text beside them, the
/// way `patRow` does: a ±1 on an unknown is the only term that is recorded,
/// and every other term is a core value whose lanes are already marked.
fn linTerm(self: *Gen, row: u32, col: u32, k: f64) void {
    if (row == Lower.ground or col == Lower.ground) return;
    const l = self.lin[@intFromBool(self.pat_react)];
    if (l.len == 0) return;
    l[row * self.names.n_u + col] += k;
}

/// Row `row` is ASSIGNED a term with no recorded unknown in it.
fn linClear(self: *Gen, row: u32) void {
    const l = self.lin[@intFromBool(self.pat_react)];
    if (l.len == 0) return;
    @memset(l[row * self.names.n_u ..][0..self.names.n_u], 0);
    // Its guarded constants go with the assignment too.
    if (self.pat_react) return;
    var k: usize = 0;
    while (k < self.guarded.items.len) {
        if (self.guarded.items[k].row == row) _ = self.guarded.orderedRemove(k) else k += 1;
    }
}

/// Row `row` is assigned `V(hi) − V(lo) − <core value>`: §5.6's branch
/// relation, and §5.4.2.1's zero-potential flow probe.
fn linBranch(self: *Gen, row: u32, hi: u16, lo: u16) void {
    linClear(self, row);
    linTerm(self, row, hi, 1);
    linTerm(self, row, lo, -1);
}

/// §5.4.3 `res[u] = x[u] − res[port]` (eval) or `−res[port]` (q): the row
/// is the FINISHED port row negated, so its constants are too.
fn linPortProbe(self: *Gen, u: u32, port: u32, with_x: bool) Error!void {
    const l = self.lin[@intFromBool(self.pat_react)];
    if (l.len == 0) return;
    const n = self.names.n_u;
    for (0..n) |c| l[u * n + c] = -l[port * n + c];
    if (with_x) l[u * n + u] += 1;
    // The port row's guarded constants are copied too, under the same guard
    // (`emitSwitchRow`): they are eval-only, and each is appended once per row.
    if (self.pat_react) return;
    const k0 = self.guarded.items.len;
    for (0..k0) |k| {
        const e = self.guarded.items[k];
        if (e.row != port) continue;
        try self.guarded.append(self.arena, .{ .row = u, .col = e.col, .g = 0 - e.g, .c = 0 - e.c, .when = e.when });
    }
}

/// Row `row` is about to be written under a runtime condition, so whatever
/// constants it holds may or may not survive: each of their columns loses
/// the promise and keeps a lane instead.
fn linDynamic(self: *Gen, row: u32) void {
    const l = self.lin[@intFromBool(self.pat_react)];
    if (l.len == 0) return;
    for (l[row * self.names.n_u ..][0..self.names.n_u], 0..) |k, c| {
        if (k != 0) self.deriv_reads |= uBit(@intCast(c));
    }
}

/// `deriv_reads`, `ddx_reads` and `jac_const` — see `contract.derivReads`.
/// After every unit and residual is written, because all three are read off
/// what was.
///
/// The derivation, and why it is sound. An unknown's lane can matter only
/// if some emitted text reads `x[u]` or `.ddxAt(u)`. Every read in a core or
/// unit goes through `renderValueRef`, which marks it whatever op surrounds
/// it; `ddx` marks its lane in `ddx_reads`; the dispatcher marks every
/// unknown under a runtime-selected row. What is left unmarked is an unknown
/// the residual reads only in the dispatcher's own unconditional ±1 stamps,
/// and `lin` replays those stamps exactly, so its entries ARE the partials.
/// `ddx_reads` and `limit`'s writes are ORed in for `contract`'s rules.
///
/// Omitted above 64 unknowns, like `jac_pattern`: the defaults — every lane,
/// no table — are correct.
pub fn emitDerivReads(self: *Gen, limit_writes: u64) Error!void {
    const jc = try plan_jac.plan(self.arena, self.names.n_u, self.deriv_reads, self.ddx_reads, limit_writes, .{ self.lin[0], self.lin[1] }, self.guarded.items) orelse return;
    try self.w(
        \\/// Unknowns whose derivative lane `eval`/`q` read. Every other
        \\/// column's partials are constants, listed in `jac_const`; see
        \\/// `contract.derivReads`.
        \\pub const deriv_reads: u64 = 0x{x:0>16};
        \\
        \\/// The lanes §4.5.14 `ddx` reads by unknown index through `ddxAt`;
        \\/// see `contract.ddxReads`.
        \\pub const ddx_reads: u64 = 0x{x:0>16};
        \\
        \\/// The exact constant partials of the columns outside `deriv_reads`:
        \\/// `g` of `eval`, `c` of `q`. Sorted by (row, col); absent is 0.
        \\pub const jac_const = [_]contract.JacConst(U){{
        \\
    , .{ jc.mask, self.ddx_reads });
    for (jc.entries) |e| {
        try self.w("    .{{ .row = .{s}, .col = .{s}, .g = {s}, .c = {s}", .{
            self.names.u_names[e.row], self.names.u_names[e.col], try gen_file.fmtF64(self, e.g), try gen_file.fmtF64(self, e.c),
        });
        if (e.when) |k| try self.w(", .when = .{{ .flag = \"{s}\", .collapse_open = true }}", .{try guardField(self, k)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// The column bit of one unknown. Out of `u64` range answers "every
/// column", which is the dense fallback `emitPattern` also takes.
pub fn uBit(u: u32) u64 {
    return if (u >= 64) std.math.maxInt(u64) else @as(u64, 1) << @intCast(u);
}

/// Same, for a node that may be ground (no unknown, no column).
pub fn nodeBit(node: u16) u64 {
    return if (node == Lower.ground) 0 else uBit(node);
}

/// The columns accumulated so far on row `u` of the half being emitted.
pub fn patOf(self: *const Gen, u: u32) u64 {
    const half = self.pat[@intFromBool(self.pat_react)];
    return if (half.len == 0) std.math.maxInt(u64) else half[u];
}

/// Columns of the row `emitSwitchRow` emits. Which arm the `S.sel` takes is
/// a runtime decision, so the row carries EVERY arm's columns: its own
/// value, the switch partner's, and `ib` — the open circuit and both flow
/// forms all name it.
pub fn switchRowDeps(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) u64 {
    var acc = uBit(self.names.branch_u[i]) |
        self.an.unknownDeps(if (react) c.react_val else c.resist_val);
    if (plan_topo.switchFlowOf(self.input(), i)) |j| {
        const f = self.lowered.contributions.items[j];
        acc |= self.an.unknownDeps(if (react) f.react_val else f.resist_val);
    }
    return acc;
}

pub fn nodeVoltage(self: *Gen, node: u16) Error!void {
    if (node == Lower.ground) return self.b("S.con(0.0)", .{});
    try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[node]});
}

/// §4.6.4 noise generator topology AND the generators' own PSDs.
///
/// `noise_gens[k]` is the branch and the tag; `noisePsd(x, m, i)[k]` is
/// the PSD, evaluated from the model's own expression at an arbitrary
/// state vector. THE TAG IS NOT THE PSD and never could be: §4.6.4.1's
/// `white_noise(pwr)` states the power spectral density outright, so
/// `white_noise(2·q·|I|)` (shot, 16 models in ARPice's device set write
/// exactly that) and `white_noise(4·k·T/R)` (thermal) are the same call
/// with different arguments. A host that saw only the tag had to guess,
/// and the only guess a Jacobian supports — 4kT·|∂I_row/∂V_col| — is off
/// by 2 on a junction (g = I/(N·V_t) ⇒ 4kT·g = (2/N)·2q·I) and off by
/// whatever the branch's other terms happen to be everywhere else.
/// §4.6.4.2's `kf·I^af / f^ef` it could not express at all.
///
/// ONE ENTRY PER GENERATOR, not per contribution. §4.6.4's own shape is
/// several sources on one branch, and `Lower.Contribution.noise_srcs` is a
/// set for that reason; iterating it here is what makes the thermal source
/// of `combined/13_noise_temperature_analysis.va` reach the table at all.
///
/// §4.6.4.6 correlation is the `source` column: `NoiseSrc.id` (the AST id
/// of the declaring call) renamed densely in first-seen order, so two rows
/// that reached one call through a variable share one `source` and two
/// textually separate calls never do.
///
/// §4.6.4.3/.4 `noise_table`/`noise_table_log` are the fourth kind, and
/// their PSD is a piecewise (frequency, power) table that neither
/// `PsdTerm`'s `white + flicker/f^ef` nor any tag can state. It leaves
/// through a SECOND comptime export, `noise_tables`, with `NoiseGen.table`
/// naming the row's entry — data and not a function, because a host that
/// integrates a spectrum wants the knots (a log-log segment has a
/// closed-form integral and a sampled evaluator does not), and because the
/// clause's input is a property of the model rather than of a bias. Such a
/// row's `PsdTerm` is all-zero, so `white + flicker/f^ef + table` is the
/// whole spectrum for every kind at once.
///
/// A generator that cannot be exported at all — a ground-ground branch
/// (§1.3.1.1, E0520) or a table that is not constant pairs (E0519) — takes
/// the whole `noise_gens` decl with it, rather than leaving a table that is
/// quietly missing a generator. See `refuseNoise`.
pub fn emitNoiseTable(self: *Gen) Error!void {
    if (self.noise.fatal) |msg| {
        // A `@compileError` VALUE, not a statement: the decl exists, so a
        // host that never touches noise still builds, and `contract.validate`
        // — which reads `noise_gens` — reports this message instead of a
        // table with a generator missing from it.
        try self.w("/// §4.6.4 refused by codegen; see the diagnostic.\n", .{});
        try self.w("pub const noise_gens = @compileError(\"{s}\");\n\n", .{msg});
        return;
    }
    if (self.noise.rows.len == 0) return;
    if (self.noise.tabs.len != 0) {
        try self.w(
            \\/// §4.6.4.3/.4 the tabulated PSDs, ascending in frequency (the
            \\/// clause's own sort, done here so the host never repeats it).
            \\pub const noise_tables = [_]contract.NoiseTable{{
            \\
        , .{});
        for (self.noise.tabs, 0..) |pts, k| {
            const log = for (self.noise.rows) |nr| {
                if (nr.table == @as(u16, @intCast(k))) break nr.kind == .table_log;
            } else false;
            try self.w("    .{{ .interp = .{s}, .points = &.{{", .{if (log) "log" else "linear"});
            for (pts, 0..) |p, i| {
                try self.w("{s}.{{ {s}, {s} }}", .{
                    if (i == 0) " " else ", ",
                    try gen_file.fmtF64(self, p[0]),
                    try gen_file.fmtF64(self, p[1]),
                });
            }
            try self.w(" }} }},\n", .{});
        }
        try self.w("}};\n\n", .{});
        try emitNoiseTablePoints(self);
    }
    try self.w("/// §4.6.4 noise sources declared by the model.\npub const noise_gens = [_]contract.NoiseGen(Self){{\n", .{});
    for (self.noise.rows) |nr| {
        try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .kind = .{s}, .source = {d}", .{
            self.names.u_names[nr.row], self.names.u_names[nr.col], contractNoiseKind(nr.kind), nr.source,
        });
        if (nr.table) |k| try self.w(", .table = {d}", .{k});
        if (nr.name.len != 0) try self.w(", .name = \"{f}\"", .{std.zig.fmtString(nr.name)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});

    // §4.6.4.1/.2 the PSDs, positionally. One `core(R, …)` sweep at the
    // caller's state vector, exactly like `updateState` — a generator
    // whose declaring statement did not execute at this bias reads back
    // the zero `probeBody` seeds a conditional live-out with, which is
    // also its physical answer.
    try self.w(
        \\/// §4.6.4.1/.2 each generator's PSD at `x`: S(f) = white + flicker/f^ef.
        \\/// Position k belongs to `noise_gens[k]`. A §4.6.4.3/.4 `.table` row
        \\/// reads zero here — its spectrum is `noise_tables[k]` instead.
        \\pub fn noisePsd(
    , .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance) [noise_gens.len]contract.PsdTerm {{\n", .{});
    const uses_core = for (self.noise.rows) |nr| {
        if (coreIdx(self, nr.pwr) != null or coreIdx(self, nr.exp) != null or coreIdx(self, nr.coeff) != null) break true;
    } else false;
    if (uses_core) {
        try self.w("    var xr: [n_u]R = undefined;\n", .{});
        try self.w("    for (x, 0..) |xv, i| xr[i] = R.con(xv);\n", .{});
        try self.w("    const m = core(R, xr, model, {s}{s});\n", .{ try gen_setup.probeInstance(self), self.heldArg(true) });
    } else {
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_model, "model".len);
        gen_unit.patchParam(self, at_inst, "inst".len);
    }
    try self.w("    return .{{\n", .{});
    for (self.noise.rows) |nr| {
        // §4.6.4.6's per-use factor. It rides beside the PSD rather than
        // being folded into it: a §4.6.4.3 table row's spectrum is comptime
        // data that cannot absorb a bias-dependent factor, and the cross
        // term between two rows sharing a source needs the two coefficients
        // separately — their PRODUCT, sign and all, is the cross-spectrum.
        const coeff = try psdRef(self, nr.coeff, true);
        switch (nr.kind) {
            // §4.6.4.3/.4 the table IS the spectrum: anything here would be
            // added to it, so the parametric part of a table row is zero.
            .table, .table_log => try self.w("        .{{ .white = 0, .coeff = {s} }}, // noise_tables[{d}]\n", .{ coeff, nr.table.? }),
            .flicker => try self.w("        .{{ .white = 0, .flicker = {s}, .ef = {s}, .coeff = {s} }},\n", .{
                try psdRef(self, nr.pwr, false), try psdRef(self, nr.exp, true), coeff,
            }),
            .thermal => try self.w("        .{{ .white = {s}, .coeff = {s} }},\n", .{ try psdRef(self, nr.pwr, false), coeff }),
            // Split off by `plan/noise.zig`; a stimulus never reaches this table.
            .ac_stim => unreachable,
        }
    }
    try self.w("    }};\n}}\n\n", .{});
}

/// §4.6.4.3's ARRAY-PARAMETER input, which `noise_tables` alone cannot
/// state: "The vector can either be specified as an array parameter or an
/// array assignment pattern", and §3.4 makes a parameter something
/// "modified at compilation time to have values which are different from
/// those specified in the declaration assignment". So the knots are a
/// property of the model CARD, and a comptime array can only hold the
/// declared defaults — which is what `noise_tables` holds, unchanged, and
/// which is the right shape for the three spellings that ARE literal.
///
/// This is the card's answer, one flat array over every table in
/// `noise_tables` order. FLAT and not indexed by a comptime `k`, because a
/// per-table return type is a generic function and `contract.expectFn`
/// cannot check one: the segment for table k starts at the sum of the
/// earlier `noise_tables[i].points.len`, which a host computes at comptime
/// from a decl it already reads.
///
/// Emitted ONLY when some knot is a parameter. A device of literal tables
/// keeps exactly the text it had, and a host is never obliged to read a
/// hook that would tell it what `noise_tables` already did.
///
/// RE-SORTED at run time. §4.6.4.3's "the simulator shall internally sort
/// the pairs into ascending frequency" is discharged at compile time for
/// the defaults, and a card that reorders the parameter re-opens it; the
/// host's `noiseTableAt` needs ascending knots, so the sort is here rather
/// than in a precondition nobody can check.
pub fn emitNoiseTablePoints(self: *Gen) Error!void {
    var any = false;
    for (self.noise.tab_vals) |mvs| any = any or mvs.len != 0;
    if (!any) return;
    var total: usize = 0;
    for (self.noise.tabs) |pts| total += pts.len;
    try self.w(
        \\/// §4.6.4.3 every tabulated knot AT THIS CARD, in `noise_tables`
        \\/// order and ascending in frequency within each table. Table k is
        \\/// the segment starting at the sum of `noise_tables[i].points.len`
        \\/// for i < k; `noise_tables` itself carries the array parameter's
        \\/// DECLARED DEFAULTS, which is all a comptime table can hold.
        \\pub fn noiseTablePoints(
    , .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model) [{d}][2]f64 {{\n", .{total});
    const saved_model = self.uses_model;
    self.uses_model = false;
    var body: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (self.noise.tabs, 0..) |pts, k| {
        const mvs = if (k < self.noise.tab_vals.len) self.noise.tab_vals[k] else &.{};
        for (pts, 0..) |p, i| {
            const pair: [2][]const u8 = if (i < mvs.len) .{
                (try gen_call.f64Const(self, mvs[i][0], 0, false)) orelse try gen_file.fmtF64(self, p[0]),
                (try gen_call.f64Const(self, mvs[i][1], 0, false)) orelse try gen_file.fmtF64(self, p[1]),
            } else .{ try gen_file.fmtF64(self, p[0]), try gen_file.fmtF64(self, p[1]) };
            try body.print(self.arena, "        .{{ {s}, {s} }},\n", .{ pair[0], pair[1] });
        }
        at += pts.len;
    }
    const reads_model = self.uses_model;
    self.uses_model = saved_model or reads_model;
    if (!reads_model) gen_unit.patchParam(self, at_model, "model".len);
    try self.w("    var pts: [{d}][2]f64 = .{{\n", .{total});
    try self.w("{s}", .{body.items});
    try self.w("    }};\n", .{});
    at = 0;
    for (self.noise.tabs) |pts| {
        try self.w("    contract.sortNoiseTable(pts[{d}..{d}]);\n", .{ at, at + pts.len });
        at += pts.len;
    }
    try self.w("    return pts;\n}}\n\n", .{});
}

/// §4.6.3 the AC stimulus topology AND each stimulus' phasor.
///
/// `ac_gens[k]` is the branch and the analysis name; `acStim(x, m, i)[k]`
/// is `(mag, phase)`. The split is `noise_gens`/`noisePsd`'s, for the same
/// reason: the branch and the name are model TEXT, the two numbers are the
/// model CARD — `ac_stim("ac", AMPL)` with `AMPL` a parameter has a
/// magnitude the card sets, and a comptime table could only have frozen
/// its declared default.
///
/// WHY THIS EXPORT EXISTS AT ALL, given that `emitCall` also lowers
/// `ac_stim` into the residual. The residual is REAL, so what it can carry
/// is `mag·cos(phase)` — the phasor's real part — and the quadrature half
/// is gone: a source at phase π/2 contributes 6.1e-17 instead of a unit
/// imaginary excitation, which is not a rounding error but a missing
/// source. This table is the whole phasor, for a host that solves a
/// complex system. Both spell the SAME source, so such a host reads this
/// INSTEAD OF the residual term — see `contract.AcGen`.
///
/// A.8.2 makes both numeric arguments `analog_expression`, so a magnitude
/// the SOLVE computes — `ac_stim("ac", k*V(ctrl))`, a swept-amplitude
/// source — is legal, and this hook takes the `[n_u]f64` state vector
/// `noisePsd` takes for exactly that reason. A stimulus that folds through
/// `f64Const` still renders over `Model` and touches neither `x` nor the
/// core, which is what keeps a constant-magnitude device's body what it
/// always was.
pub fn emitAcTable(self: *Gen) Error!void {
    if (self.noise.ac_rows.len == 0) return;

    // Rendered BEFORE anything is written, so the `x`/`model`/`inst`
    // parameters can be patched to `_` when nothing reached them — same
    // bookkeeping `emitUnit` does, and the flags are saved because they are
    // Gen-wide.
    const saved_model = self.uses_model;
    const saved_inst = self.uses_inst;
    self.uses_model = false;
    self.uses_inst = false;
    const vals = try self.arena.alloc([2][]const u8, self.noise.ac_rows.len);
    var all_stated = true;
    var uses_core = false;
    for (self.noise.ac_rows, vals) |nr, *v| {
        // §4.6.4.6's per-use coefficient, FOLDED into the magnitude rather
        // than exported beside it. A phasor is scaled by a real factor
        // exactly — `c·m·e^(jφ)` — including the sign, which rides as a
        // negative magnitude (`−m·e^(jφ)` is `m·e^(j(φ+π))`). §4.6.4.6's
        // own reason for keeping it separate does not apply here: there is
        // no cross-spectrum between two stimuli and no comptime table to
        // keep a bias-dependent factor out of.
        const mag = try acRef(self, nr.pwr, &uses_core);
        const phase = try acRef(self, nr.exp, &uses_core);
        const coeff = try acRef(self, nr.coeff, &uses_core);
        if (mag == null or phase == null or coeff == null) {
            all_stated = false;
            break;
        }
        v.* = .{
            if (nr.coeff == .f_one) mag.? else try std.fmt.allocPrint(self.arena, "({s}) * ({s})", .{ mag.?, coeff.? }),
            phase.?,
        };
    }
    const reads_model = self.uses_model or uses_core;
    const reads_inst = self.uses_inst or uses_core;
    self.uses_model = saved_model or reads_model;
    self.uses_inst = saved_inst or reads_inst;
    if (!all_stated) return refuseAc(self);

    try self.w("/// §4.6.3 AC stimulus sources declared by the model.\npub const ac_gens = [_]contract.AcGen(Self){{\n", .{});
    for (self.noise.ac_rows) |nr| {
        try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .name = \"{f}\" }},\n", .{
            self.names.u_names[nr.row], self.names.u_names[nr.col], std.zig.fmtString(nr.name),
        });
    }
    try self.w("}};\n\n", .{});

    try self.w(
        \\/// §4.6.3 each stimulus' phasor at `x`: mag·e^(j·phase), phase in
        \\/// radians. Position k belongs to `ac_gens[k]`.
        \\pub fn acStim(
    , .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance) [ac_gens.len]contract.AcPhasor {{\n", .{});
    if (!uses_core) gen_unit.patchParam(self, at_x, "x".len);
    if (!reads_model) gen_unit.patchParam(self, at_model, "model".len);
    if (!reads_inst) gen_unit.patchParam(self, at_inst, "inst".len);
    if (uses_core) {
        try self.w("    var xr: [n_u]R = undefined;\n", .{});
        try self.w("    for (x, 0..) |xv, i| xr[i] = R.con(xv);\n", .{});
        try self.w("    const m = core(R, xr, model, {s}{s});\n", .{ try gen_setup.probeInstance(self), self.heldArg(true) });
    }
    try self.w("    return .{{\n", .{});
    for (vals) |v| try self.w("        .{{ .mag = {s}, .phase = {s} }},\n", .{ v[0], v[1] });
    try self.w("    }};\n}}\n\n", .{});
}

/// Does any §4.6.3 stimulus need `acStim` to sweep the core? Asked before
/// `emitAcTable` renders anything, because the `R` scalar the sweep runs in
/// is declared far earlier in the file — same question `noise_rows.len != 0`
/// answers for `noisePsd`, which always sweeps.
pub fn acUsesCore(self: *Gen) Error!bool {
    for (self.noise.ac_rows) |nr| {
        for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
            if (v == .f_zero) continue;
            if (try gen_call.ctrlIsDynamic(self, v)) return true;
        }
    }
    return false;
}

/// One §4.6.3 magnitude, phase or §4.6.4.6 coefficient in `acStim`'s frame.
///
/// `f64Const` first, so a literal or a model parameter renders over `Model`
/// exactly as it did before this hook had an `x` at all. What does not fold
/// is a solve result, and the only thing that holds one here is the core
/// sweep `buildJobs` queued a field for — the same two-frame split
/// `ctrlStep` makes in `updateState`. Null means neither, which is a
/// planning defect rather than a legal program, and `refuseAc` says so
/// instead of exporting a wrong number.
pub fn acRef(self: *Gen, v: Mir.Value, uses_core: *bool) Error!?[]const u8 {
    if (try gen_call.f64Const(self, v, 0, false)) |s| return s;
    const k = self.core.lo_idx[@intFromEnum(v)];
    if (k == none_u32) return null;
    uses_core.* = true;
    return try std.fmt.allocPrint(self.arena, "m.f{d}.v", .{k});
}

/// §4.6.3 a stimulus VerA cannot state, as a `@compileError` VALUE on
/// `ac_gens` — the shape `refuseNoise` gives `noise_gens`, so a host that
/// never asks for stimuli still builds and one that does is told why.
///
/// No diagnostic of its own: the only way to get here is a mag or phase
/// `f64Const` will not answer for, and `emitCall` lowered the same argument
/// into the residual first and already reported E0515 on the same token.
pub fn refuseAc(self: *Gen) Error!void {
    try self.w("/// §4.6.3 refused by codegen; see the diagnostic.\n", .{});
    try self.w("pub const ac_gens = @compileError(\"LRM 4.6.3: an ac_stim magnitude or " ++
        "phase must be a constant or parameter expression\");\n\n", .{});
}

/// `Lower.NoiseKind` in the vocabulary `contract.NoiseGen.kind` speaks:
/// §4.6.4.3 and §4.6.4.4 are two spellings of ONE exported kind, because
/// what a host does with either is read `noise_tables`, and which
/// interpolation to use is the table's own `interp` field.
pub fn contractNoiseKind(k: Lower.NoiseKind) []const u8 {
    return switch (k) {
        .thermal => "thermal",
        .flicker => "flicker",
        .table, .table_log => "table",
        // §4.6.3 has no `NoiseGen.kind` because it has no `noise_gens` row.
        .ac_stim => unreachable,
    };
}

/// The core field holding `v`, or null when `v` is rendered inline —
/// structurally zero, or a constant `plan_core.plan` never had to carry.
pub fn coreIdx(self: *const Gen, v: Mir.Value) ?u32 {
    if (v == .f_zero) return null;
    const k = self.core.lo_idx[@intFromEnum(v)];
    return if (k == none_u32) null else k;
}

/// One PSD argument as an `f64` expression in `noisePsd`'s body. `is_exp`
/// allows the inline-constant shortcut — see `buildJobs` for why only the
/// exponent may take it.
pub fn psdRef(self: *Gen, v: Mir.Value, is_exp: bool) Error![]const u8 {
    if (v == .f_zero) return "0";
    if (is_exp) if (plan_noise.psdConst(self.mir, v)) |c| return try std.fmt.allocPrint(self.arena, "{d}", .{c});
    const k = self.core.lo_idx[@intFromEnum(v)];
    // A live-out the planner dropped cannot happen (`buildJobs` queued it),
    // but a zero is the one answer that cannot invent noise.
    if (k == none_u32) return "0";
    return try std.fmt.allocPrint(self.arena, "m.f{d}.v", .{k});
}
