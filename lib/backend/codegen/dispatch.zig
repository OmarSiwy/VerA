//! Core live-outs -> the host entry points: `eval` (resistive), `q` (reactive,
//! one charge per site), `evalQ`, the structural Jacobian tables, and the
//! §4.6.3/§4.6.4 small-signal source tables. Stamps follow §1.3.1.2 reference
//! directions.
//! LRM: §1.3.1.2, §2.9, §4.6.3, §4.6.4, §5.4.2.1, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3,
//! §5.6.6, §9.4.

const std = @import("std");
const plan_jac = @import("plan/jac.zig");
const plan_noise = @import("plan/noise.zig");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_file = @import("file.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lower;
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// The Jacobian evidence emission leaves behind (`Gen.jac`), read by the
/// pattern tables and `emitDerivReads` after the dispatchers. Written by the
/// dispatchers through `patRow` and the `lin*` recorders, except the two lane
/// masks, which the renderer (`x[u]`) and `ddx` (`.ddxAt(u)`) also set.
/// `[2]` columns are indexed by `@intFromBool(react)`: 0 `eval`, 1 `q`.
/// `pat`, `dpat` and `lin` are arena slices allocated by `emitDispatchers`;
/// empty before it.
pub const Jac = struct {
    /// Structural Jacobian columns per residual row: `pat[react][ru]` has bit
    /// `cu` set when `∂res[ru]/∂x[cu]` can be nonzero. `emitStamps` fills it as
    /// it writes each row. The host reads the emitted constant to drop
    /// structurally-zero stamps at compile time.
    pat: [2][]u64 = .{ &.{}, &.{} },
    /// Which residual rows each half ever writes: bit `ru` of `rows[react]` is
    /// set when the emitted `eval` (resp. `q`) contains any `res[ru] = ...`.
    /// Not `pat[react][ru] != 0`: a term that depends on no unknown writes the
    /// row with a clear pattern (an independent current source), and a host
    /// that read a clear pattern as "identically zero" would drop it.
    /// Set beside `pat` in `patRow`, which every `res[...]` writer goes through.
    rows: [2]u64 = .{ 0, 0 },
    /// Which half of `pat` the current `emitStamps` writes.
    react: bool = false,
    /// Per residual row, either half: the columns whose partial reaches it
    /// through a frequency-dependent operator (`Analysis.acDynDeps`), the
    /// source of `ac_dyn_slots`. `patRow` fills it from `cur_dyn`.
    dpat: []u64 = &.{},
    /// `acDynDeps` of the contribution `emitStamps` is writing.
    cur_dyn: u64 = 0,
    /// Unknowns whose derivative lane `eval`/`q` may read: the mask behind the
    /// emitted `deriv_reads`. Syntactic, so a superset: every `x[u]`
    /// `renderValueRef` writes, every `.ddxAt(u)`, and every dispatcher term
    /// with a non-constant coefficient. See `emitDerivReads`.
    deriv_reads: u64 = 0,
    /// The lanes a §4.5.14 `ddx` reads BY INDEX (`.ddxAt(u)`): the emitted
    /// `ddx_reads`, and a subset of `deriv_reads` by construction.
    ddx_reads: u64 = 0,
    /// The dispatcher's constant-coefficient terms, per half:
    /// `lin[react][row * n_u + col]` is the exact coefficient of `x[col]` in
    /// `res[row]` as far as the stamps are linear. Only the columns OUTSIDE
    /// `deriv_reads` leave as `jac_const`; inside, the lane carries them.
    /// Empty above 64 unknowns, where neither decl is emitted.
    lin: [2][]f64 = .{ &.{}, &.{} },
    /// The constants of a collapsible switch row that hold only under its
    /// guard (`emitSwitchRow`), eval half; `plan/jac.zig` merges them into
    /// `jac_const` with a `.when`. Arena list.
    guarded: std.ArrayList(plan_jac.Entry) = .empty,
};

// =======================================================================
// Dispatchers: §5.6 residual assembly, §1.3.1.2 reference directions
// =======================================================================

/// Emits `eval`, and `q`/`evalQ`/the charge-site tables when any charge site
/// exists, then the pattern tables, `display` and (optionally) `vpiContribs`.
/// Allocates `jac.pat`, `jac.dpat` and `jac.lin` on the arena.
pub fn emitDispatchers(self: *Gen) Error!void {
    self.jac.pat[0] = try self.arena.alloc(u64, self.names.n_u);
    self.jac.pat[1] = try self.arena.alloc(u64, self.names.n_u);
    @memset(self.jac.pat[0], 0);
    @memset(self.jac.pat[1], 0);
    self.jac.dpat = try self.arena.alloc(u64, self.names.n_u);
    @memset(self.jac.dpat, 0);
    self.jac.rows = .{ 0, 0 };
    if (self.names.n_u <= 64) for (&self.jac.lin) |*l| {
        l.* = try self.arena.alloc(f64, self.names.n_u * self.names.n_u);
        @memset(l.*, 0);
    };

    try emitEval(self);
    const any_q = anyQ(self);
    if (any_q) {
        qPattern(self);
        try emitQ(self);
        try emitFused(self);
        try emitQSites(self);
    }
    // After the dispatchers: the pattern is accumulated as each row is written.
    try emitPattern(self, any_q);
    try emitAcDyn(self, any_q);
    try emitDisplay(self);
    if (self.vpi_contribs) try emitVpiContribs(self);
}

/// Emits `vpiContribs` (`Options.vpi_contribs`): each §5.6 contribution's
/// resistive and reactive value at `x`, by `Lowered.contributions` index,
/// beside the row shape (access, the `U` of each terminal and of a potential
/// source's flow unknown, -1 for ground or none). A §11.6.7 flow-source flow
/// is its row value plus d/dt of the reactive half, which the host forms.
/// Reads `core` as `eval` and `q` do, so the numbers are the residual's own.
fn emitVpiContribs(self: *Gen) Error!void {
    const cs = self.lowered.contributions.items;
    try self.w("/// Clause 12 (`Options.vpi_contribs`): the §5.6 contribution rows.\n", .{});
    try self.w("pub const vpi_contrib_access = [_]u8{{", .{});
    for (cs) |c| try self.w(" {d},", .{@backingInt(c.access)});
    try self.w(" }};\npub const vpi_contrib_hi = [_]i32{{", .{});
    for (cs) |c| try self.w(" {d},", .{nodeCol(c.hi)});
    try self.w(" }};\npub const vpi_contrib_lo = [_]i32{{", .{});
    for (cs) |c| try self.w(" {d},", .{nodeCol(c.lo)});
    try self.w(" }};\npub const vpi_contrib_flow_u = [_]i32{{", .{});
    for (self.names.branch_u) |u| try self.w(" {d},", .{if (u == none_u32) @as(i64, -1) else u});
    try self.w(" }};\n", .{});
    try self.w("pub fn vpiContribs(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) [{d}][2]f64 {{\n", .{cs.len});
    const uses_core = for (cs) |c| {
        if (coreIdx(self, self.an.rv(c.resist_val)) != null or coreIdx(self, self.an.rv(c.react_val)) != null) break true;
    } else false;
    if (uses_core)
        try self.w("    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});\n", .{self.heldArg(false)})
    else
        try self.w("    _ = x;\n    _ = model;\n    _ = inst;\n    _ = sim;\n", .{});
    try self.w("    return .{{\n", .{});
    for (cs) |c| {
        try self.w("        .{{ ", .{});
        for ([_]Mir.Value{ c.resist_val, c.react_val }, 0..) |v, k| {
            if (k != 0) try self.w(", ", .{});
            if (coreIdx(self, self.an.rv(v))) |f|
                try self.w("m.f{d}.val()", .{f})
            else
                try self.w("0.0", .{});
        }
        try self.w(" }},\n", .{});
    }
    try self.w("    }};\n}}\n\n", .{});
}

fn nodeCol(n: u16) i64 {
    return if (n == Lower.ground) -1 else n;
}

/// Returns whether any charge site gets a slot, that is, whether `q` is emitted.
pub fn anyQ(self: *const Gen) bool {
    return self.qs.sites.len != 0;
}

/// Fills `q_pattern`/`q_rows` from the sites: row `ru` is written when a site
/// stamps it, and its columns are the union of those sites' dependences.
fn qPattern(self: *Gen) void {
    for (self.qs.stamps) |st| {
        const k = self.qs.sites[st.slot];
        const bits = self.an.unknownDeps(self.lowered.charge_sites.items[k].final);
        if (self.jac.pat[1].len != 0) self.jac.pat[1][st.row] |= bits;
        self.jac.dpat[st.row] |= self.an.acDynDeps(self.lowered.charge_sites.items[k].final);
        self.jac.rows[1] |= uBit(st.row);
    }
}

/// The core field holding slot `j`'s charge.
fn siteField(self: *const Gen, j: usize) u32 {
    const k = self.qs.sites[j];
    return self.core.lo_idx[@backingInt(self.an.rv(self.lowered.charge_sites.items[k].final))];
}

/// Writes a `contract.Sites(Self, S)` literal: every site's charge, in slot order.
pub fn writeSites(self: *Gen) Error!void {
    try self.b("@as(contract.Sites(Self, S), .{{", .{});
    for (0..self.qs.sites.len) |j| try self.b("{s}m.f{d}", .{ if (j == 0) " " else ", ", siteField(self, j) });
    try self.b(" }})", .{});
}

/// Emits `q`, the §5.6.1.2 reactive residual as one charge per site
/// (`plan/qsite.zig`). `q_stamps` says which rows each enters, so a host
/// integrates and truncation-checks each charge on its own.
fn emitQ(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6.1.2 the charges, one per `ddt` site (`n_q`, `q_stamps`, `q_lte`);
        \\/// the host differentiates each and stamps it into its rows.
        \\pub fn q(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Sites(Self, S) {{
        \\
    , .{});
    try writeLead(self, "q", "out");
    try self.w(
        \\{s}    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});
        \\{s}
    , .{
        if (gen_file.hasStatus(self)) status_pre ++ "zSitesZero(S);\n" else "",
        self.heldArg(false),
        if (gen_file.hasStatus(self)) status_post ++ "zSitesZero(S);\n" else "",
    });
    try self.w("    return ", .{});
    try writeSites(self);
    try self.w(";\n}}\n\n", .{});
}

/// Emits `n_q`, `q_stamps`, `q_lte` and `q_site_pattern` (`contract.QSites`).
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

/// Emits the §5.6 structural Jacobian: which columns of each residual row can
/// be nonzero, as a comptime constant so the host can drop the structurally
/// zero stamps. Omitted above 64 unknowns (`Analysis.deps` is one u64 per
/// value); a host that finds no declaration scatters densely.
fn emitPattern(self: *Gen, any_q: bool) Error!void {
    if (self.names.n_u > 64) return;
    try self.w(
        \\/// §5.6 structural Jacobian: bit `cu` of `jac_pattern[ru]` is set
        \\/// when `∂eval(x)[ru]/∂x[cu]` can be nonzero. A clear bit is a
        \\/// stamp with no physics behind it, and the host may drop it at
        \\/// compile time. Over-approximate: a set bit costs a stamp that
        \\/// happens to be zero, never a missing matrix entry.
        \\
    , .{});
    try emitPatternRows(self, "jac_pattern", self.jac.pat[0]);
    try emitWrittenRows(self, "jac_rows", "eval", self.jac.rows[0]);
    if (!any_q) return;
    try self.w("/// Same, for `q`'s reactive residual (`dQ/dx`).\n", .{});
    try emitPatternRows(self, "q_pattern", self.jac.pat[1]);
    try emitWrittenRows(self, "q_rows", "q", self.jac.rows[1]);
}

/// Emits `ac_dyn_slots` and `acDyn` (`contract.acDynSlots`) when a
/// frequency-dependent operator reaches a residual row. Above 64 unknowns
/// `dpat` is folded, so a reached row lists every column.
fn emitAcDyn(self: *Gen, any_q: bool) Error!void {
    const n = self.names.n_u;
    var slots: std.ArrayList(u32) = .empty;
    for (self.jac.dpat, 0..) |m, r| for (0..n) |c| {
        const hit = if (n > 64) m != 0 else (m >> @intCast(c)) & 1 != 0;
        if (hit) try slots.append(self.arena, @intCast(r * n + c));
    };
    if (slots.items.len == 0) return;
    try self.w(
        \\/// §4.5.7/§4.5.11/§4.5.12 the slots `row * n_u + col` whose small-signal
        \\/// value depends on frequency; `acDyn` supplies them (`contract.acDynSlots`).
        \\pub const ac_dyn_slots = [_]u32{{
    , .{});
    for (slots.items, 0..) |k, i| try self.w("{s}{d}", .{ if (i == 0) " " else ", ", k });
    try self.w(
        \\ }};
        \\
        \\/// Each `ac_dyn_slots` entry's complex term at `omega`, one per lane of `F`
        \\/// (`contract.acDynSlots`).
        \\pub fn acDyn(comptime F: type, model: *const Model, inst: InstancePtr, x: *const [n_u]f64, sim: contract.SimState, omega: F, out: *[ac_dyn_slots.len]std.math.Complex(F)) void {{
        \\    const S = zAc(F);
        \\    var xs = zProbe(S, x);
        \\    inline for (0..n_u) |u| xs[u].w = &omega;
        \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
        \\    const g = zResidual(S, xs, m);
        \\
    , .{self.heldArg(false)});
    if (any_q) {
        try self.b("    const c = contract.qRows(Self, S, ", .{});
        try writeSites(self);
        try self.b(");\n", .{});
    }
    try self.w(
        \\    inline for (ac_dyn_slots, 0..) |s, k| {{
        \\        const r = s / n_u;
        \\        const u = s % n_u;
        \\
    , .{});
    // A = G + jωC: the charge's complex lanes enter rotated by jω.
    if (any_q) try self.w(
        \\        const re = g[r].acRe(u) - omega * c[r].acIm(u);
        \\        const im = g[r].acIm(u) + omega * c[r].acRe(u);
        \\
    , .{}) else try self.w(
        \\        const re = g[r].acRe(u);
        \\        const im = g[r].acIm(u);
        \\
    , .{});
    try self.w(
        \\        out[k] = .{{ .re = re, .im = im }};
        \\    }}
        \\}}
        \\
        \\
    , .{});
}

/// Emits which §5.6 residual rows the half ever writes. A row outside the set
/// is zero at every bias, so a host may drop it whole. The host cannot infer
/// this from the pattern: a term with no unknown in it (an independent
/// current source) writes its row with a clear pattern.
fn emitWrittenRows(self: *Gen, name: []const u8, half: []const u8, mask: u64) Error!void {
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

fn emitPatternRows(self: *Gen, name: []const u8, rows: []const u64) Error!void {
    try self.w("pub const {s} = [n_u]u64{{\n", .{name});
    for (rows, 0..) |m, i| try self.w("    0x{x:0>16}, // {s}\n", .{ m, self.names.u_names[i] });
    try self.w("}};\n\n", .{});
}

/// Emits `display`, the §9.4 entry point a host calls to run the module's
/// display tasks. Separate from `eval` so the host decides when text happens
/// rather than getting it once per Newton iteration. Not emitted under
/// `display == .drop`. The unit's `S` result is discarded.
pub fn emitDisplay(self: *Gen) Error!void {
    if (self.jobs.display_name.len == 0) return;
    try self.w(
        \\/// §9.4 run this module's display tasks once, in source order.
        \\pub fn display(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) void {{
        \\    _ = {s}(S, zProbe(S, x), model, inst, sim);
        \\}}
        \\
        \\
    , .{self.jobs.display_name});
}

/// Emits `eval` over `zResidual`: the §5.6 rows, emitted once and shared with
/// `evalQ`, which passes them its own core result.
fn emitEval(self: *Gen) Error!void {
    self.core_wanted = false;
    self.core_hoisted = true;
    // `model` and `inst` reach a row only through `core`, so the rows take
    // its result and not them.
    try self.w("/// §5.6 the resistive rows over the core result `m`: `eval` and `evalQ`.\n", .{});
    try self.w("inline fn zResidual(comptime S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: anytype, ", .{});
    const at_m = self.out.items.len;
    try self.w("m: anytype) contract.Rows(Self, S) {{\n    ", .{});
    const at_mut = self.out.items.len;
    try self.w("var   res: contract.Rows(Self, S) = zRowsZero(S);\n", .{});
    const stamps = try emitStamps(self, false);
    self.core_hoisted = false;
    // `uses.x` also counts a row that reads `x` only through the core, so ask
    // the text: every direct read is `x[@intFromEnum(U.<name>)]`.
    if (std.mem.indexOf(u8, self.out.items[at_mut..], "x[@intFromEnum(") == null) gen_unit.patchParam(self, at_x, "x".len);
    if (!self.core_wanted) gen_unit.patchParam(self, at_m, "m".len);
    if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
    try self.w("    return res;\n}}\n\n", .{});

    try self.w("/// §5.6 resistive residual: KCL at every unknown (§1.3.2)\n", .{});
    const st = gen_file.hasStatus(self);
    if (self.core_wanted and (self.lowered.timepoints.items.len != 0 or st)) {
        // VerA's `vera_timepoint` (§2.9): the core result fills a stale cache.
        // §9.7.3 a status latches, and a latched one zeroes every row.
        try self.w(
            \\pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{
            \\{s}    const xs = zProbe(S, x);
            \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
            \\{s}{s}    return zResidual(S, xs, m);
            \\}}
            \\
            \\
        , .{
            if (st) status_pre ++ "zRowsZero(S);\n" else "",
            self.heldArg(false),
            if (self.lowered.timepoints.items.len != 0) "    zTpStore(inst, sim, m);\n" else "",
            if (st) status_post ++ "zRowsZero(S);\n" else "",
        });
    } else if (self.core_wanted) {
        try self.w(
            \\pub fn eval(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Rows(Self, S) {{
            \\
        , .{});
        try writeLead(self, "eval", "out");
        try self.w(
            \\    const xs = zProbe(S, x);
            \\    return zResidual(S, xs, @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }}));
            \\}}
            \\
            \\
        , .{self.heldArg(false)});
    } else try self.w(
        \\pub fn eval(comptime S: type, x: *const [n_u]S.V, _: *const Model, _: InstancePtr, _: contract.SimState) contract.Rows(Self, S) {{
        \\    return zResidual(S, zProbe(S, x), {{}});
        \\}}
        \\
        \\
    , .{});
}

/// Whether the device is `batch_lead` (`file.batchLead`): its entry points
/// then open with the lead loop.
fn leads(self: *const Gen) bool {
    return gen_file.batchLead(self);
}

/// Writes the lead loop an entry point opens with (`batch_lead`): a family
/// running the protocol (`S.Inner`) evaluates the batch once per leader,
/// merging each run's points that followed the leader's path, until every
/// point has run on its own. A scalar family skips it at compile time. The
/// first run is inlined and the re-runs (divergent batches) share one
/// out-of-line copy, so a coherent batch costs one inlined body.
fn writeLead(self: *Gen, call: []const u8, ret: []const u8) Error!void {
    if (!leads(self)) return;
    try self.w(
        \\    if (comptime zLeads(S)) {{
        \\        S.leadBegin();
        \\        var out = @call(.always_inline, {0s}, .{{ S.Inner, x, model, inst, sim }});
        \\        while (S.leadNext()) S.leadMerge(&out, @call(.never_inline, {0s}, .{{ S.Inner, x, model, inst, sim }}));
        \\        return {1s};
        \\    }}
        \\
    , .{ call, ret });
}

/// §9.7.3 a status device's entry-point guards (`gen_file.hasStatus`): a
/// latched status returns zero rows before the core runs, and the core's own
/// report latches and does the same. Each is followed by the zero value.
const status_pre = "    if (inst.vera_status__ != 0) return ";
const status_post = "    zStatusStore(inst, m);\n" ++ status_pre;
const zero_both = ".{ .res = zRowsZero(S), .q = zSitesZero(S) };\n";

/// Emits the §5.6 stamp rows for one residual half into a `res` the caller
/// has declared. Accumulates `uses.x`/`uses.model`/`uses.inst`, `jac.pat`, `jac.rows`
/// and `lin`, and returns the row count so the caller can back-patch its
/// signature. Opens a `core` call unless `core_hoisted` is set.
pub fn emitStamps(self: *Gen, react: bool) Error!u32 {
    var stamps: u32 = 0;
    // Which half `patRow` accumulates into. `eval`/`q` and `evalQ` emit the
    // same rows, so the second pass ORs in bits the first already set.
    self.jac.react = react;
    // `lin` is a replay, not an accumulation: `evalQ` re-emits the same
    // stamps, and adding them twice would double every coefficient. The
    // guarded stamps are eval-only (`emitSwitchRow`), so eval resets them.
    @memset(self.jac.lin[@intFromBool(react)], 0);
    if (!react) self.jac.guarded.clearRetainingCapacity();
    // One core evaluation per residual, not one per contribution: LLVM does
    // not merge them (see `plan_core.plan`'s header).
    var opened = false;
    if (self.lowered.table_effect != .f_zero) {
        opened = true;
        self.uses.x = true;
        self.uses.model = true;
        self.uses.inst = true;
        self.core_wanted = true;
        if (!self.core_hoisted) try self.b("    const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
        try self.b("    _ = m.f{d};\n", .{coreIdx(self, self.an.rv(self.lowered.table_effect)).?});
    }

    for (self.lowered.contributions.items, 0..) |c, i| {
        const val = if (react) self.an.rv(c.react_val) else self.an.rv(c.resist_val);
        self.jac.cur_dyn = contribDyn(self, i, c, react);
        // §5.6.1.3 a `.flow` entry whose branch row is runtime-selected is
        // consumed by that row (`I_b − value`); its KCL current is the ±I_b
        // the potential entry already stamps. Stamping the value here too
        // would inject it twice.
        if (c.kind == .direct and c.access == .flow and plan_topo.flowIsMerged(self.input(), i)) continue;
        // §5.6.1.3's three-way rule is decided per cycle. `.on`/`.off` fold
        // statically; `.runtime` keeps the row alive in every case, because
        // the open-circuit form (`res[u] = I_b`) pins the branch current when
        // nothing is retained.
        const run_pot: ?plan_topo.Retention = if (c.kind == .direct and c.access == .potential) ret: {
            const r = plan_topo.retention(self.input(), c);
            break :ret if (r == .runtime) r else null;
        } else null;
        // A zero half normally contributes nothing, and §5.6.1.3's
        // `discardOpposite` relies on that: it writes `.f_zero` to BOTH
        // `acc.resist` and `acc.react`, so a discarded contribution still
        // emits no row at all, in either residual.
        //
        // The exception is the inductor. A §5.6 potential contribution's
        // resistive row `V(hi) - V(lo) - c` defines its branch flow unknown,
        // and the same row enters KCL at hi and lo (§1.3.1.2).
        // `V(l) <+ L*ddt(I(l))` has `resist_val == .f_zero` and a live
        // `react_val`; skipping it would leave the flow column with no pivot.
        // Only `c` is zero, and at DC `V(hi) - V(lo) = 0` is an inductor.
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
        self.uses.x = true;
        // `model`/`inst` are read through `core` alone, so a residual whose
        // every live row is zero never opens one (an unused parameter would
        // fail the host's build). A runtime-selected row always opens it: its
        // retention flag is a core field (`buildJobs`).
        if (val != .f_zero or run_pot != null) {
            self.uses.model = true;
            self.uses.inst = true;
            if (!opened) {
                opened = true;
                self.core_wanted = true;
                if (!self.core_hoisted) {
                    try self.ind(1);
                    try self.b("const m = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(false)});
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
            try self.b("const c = m.f{d};\n", .{self.core.lo_idx[@backingInt(val)]});
        if (c.kind == .indirect) {
            // §5.6.7 nullor: `out` is driven by a source whose current is
            // the unknown `ib`, and the row is the constraint alone,
            // `<probe> − <equation>`, with no V(hi,lo) term: "the source
            // voltage needs to be adjusted so that the given equation is
            // satisfied". The ib column is filled only by the two KCL stamps.
            const u = self.names.branch_u[i];
            assert(!react); // splitContribution never runs on an indirect
            try self.ind(2);
            try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.names.u_names[u]});
            try stamp(self, 2, c.hi, "add", "ib", uBit(u), u);
            try stamp(self, 2, c.lo, "sub", "ib", uBit(u), u);
            try self.ind(2);
            patRow(self, @intCast(u), self.an.unknownDeps(val));
            linClear(self, u);
            try rowSet(self, u);
            try self.b("c", .{});
            try rowEnd(self);
            try self.ind(1);
            try self.b("}}\n", .{});
            continue;
        }
        switch (c.access) {
            .flow => if (plan_topo.flowOnlySignalFlowNet(self.input(), c)) |n| {
                // §1.3.4.2 a flow signal-flow net has no potential, so its
                // one unknown is its flow and the contribution is that
                // unknown's defining equation. A KCL stamp here would write a
                // row with no `x` in it. See `flowOnlySignalFlowNet`.
                if (!react) {
                    try self.ind(2);
                    patRow(self, n, uBit(n) | self.an.unknownDeps(val));
                    linClear(self, n);
                    linTerm(self, n, n, 1);
                    try rowSet(self, n);
                    try self.b("x[@intFromEnum(U.{s})].sub(c)", .{self.names.u_names[n]});
                    try rowEnd(self);
                } else {
                    try self.ind(2);
                    patRow(self, n, self.an.unknownDeps(val));
                    linClear(self, n);
                    try rowSet(self, n);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            } else {
                // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                try stamp(self, 2, c.hi, "add", "c", self.an.unknownDeps(val), null);
                try stamp(self, 2, c.lo, "sub", "c", self.an.unknownDeps(val), null);
                // §5.6.6: the model also reads `I(hi,lo)`, so this current is
                // an unknown whose row is `x[u] − Σ contributions`. Accumulated
                // here (contributions to one branch are one sum, §5.6.1) and
                // closed with the `+ x[u]` term after the loop.
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
                    try rowSet(self, u);
                    try nodeVoltage(self, c.hi);
                    try self.b(".sub(", .{});
                    try nodeVoltage(self, c.lo);
                    try self.b(").sub(c)", .{});
                    try rowEnd(self);
                } else {
                    const u = self.names.branch_u[i];
                    // §5.6.1.2 the reactive part of a branch relation is a
                    // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                    try self.ind(2);
                    patRow(self, @intCast(u), self.an.unknownDeps(val));
                    linClear(self, u);
                    try rowSet(self, u);
                    try self.b("c.neg()", .{});
                    try rowEnd(self);
                }
            },
        }
        try self.ind(1);
        try self.b("}}\n", .{});
    }

    self.jac.cur_dyn = 0;

    // §5.4.2 the branch-flow unknowns no branch row defines (`FreeFlow`).
    // Both rows are purely resistive: a §5.6.6 implicit sum's reactive half
    // is already on this row as `−Σ q`, and a §5.4.2.1 probe is a short,
    // which stores no charge.
    if (!react) for (self.topo.free_flows) |f| {
        self.uses.x = true;
        stamps += 1;
        if (f.sourced) {
            // Closes `res[u] = x[u] − Σ contributions`, whose `−Σ` half the
            // contribution loop accumulated.
            try self.ind(1);
            patRow(self, @intCast(f.u), uBit(f.u));
            linTerm(self, f.u, f.u, 1);
            try rowSet(self, f.u);
            try self.b("res[@intFromEnum(U.{0s})].add(x[@intFromEnum(U.{0s})])", .{self.names.u_names[f.u]});
            try rowEnd(self);
        } else {
            // §5.4.2.1 "The branch potential of a flow probe is zero (0)",
            // the ammeter of Figure 5-1. Its current enters KCL at both ends,
            // which makes it a short rather than an observation.
            try stamp(self, 1, f.hi, "add", try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), uBit(f.u), f.u);
            try stamp(self, 1, f.lo, "sub", try self.arena.print("x[@intFromEnum(U.{s})]", .{self.names.u_names[f.u]}), uBit(f.u), f.u);
            try self.ind(1);
            patRow(self, @intCast(f.u), nodeBit(f.hi) | nodeBit(f.lo));
            linBranch(self, f.u, f.hi, f.lo);
            try rowSet(self, f.u);
            try nodeVoltage(self, f.hi);
            try self.b(".sub(", .{});
            try nodeVoltage(self, f.lo);
            try self.b(")", .{});
            try rowEnd(self);
        }
    };

    // §5.4.3 `I(<p>)` = "the flow into a port of a module". By KCL that is
    // exactly what this module has just stamped at p, so the row reuses the
    // accumulation above instead of restating it:
    //
    //     eval:  res[flow(<p>)] = x[flow(<p>)] − res[p]
    //     q:     res[flow(<p>)] =              − res[p]
    //
    // Total residual x − (I_dc + d/dt q_p) = 0, so the reactive half of the
    // port current comes along: §5.4.3's own diode example probes a node
    // with a `ddt` junction capacitance. Emitted after the contribution loop
    // because it reads the finished res[p].
    for (self.lowered.port_probes.items) |pp| {
        self.uses.x = true;
        stamps += 1;
        try self.ind(1);
        // Reads the finished res[port], so this row's columns are that row's.
        patRow(self, pp.u, patOf(self, pp.port) | (if (react) 0 else uBit(pp.u)));
        self.jac.dpat[pp.u] |= self.jac.dpat[pp.port];
        try linPortProbe(self, pp.u, pp.port, !react);
        if (react) {
            try rowSet(self, pp.u);
            try self.b("res[@intFromEnum(U.{s})].neg()", .{self.names.u_names[pp.port]});
            try rowEnd(self);
        } else {
            try rowSet(self, pp.u);
            try self.b("x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})])", .{
                self.names.u_names[pp.u], self.names.u_names[pp.port],
            });
            try rowEnd(self);
        }
    }

    return stamps;
}

/// Emits `evalQ`: both §5.6/§5.6.1.2 residuals from one core evaluation,
/// where calling `eval` and `q` separately runs the model twice. `eval` and
/// `q` are unchanged; DC should keep calling `eval`. Emitted only when there
/// is a reactive half.
pub fn emitFused(self: *Gen) Error!void {
    try self.w(
        \\/// §5.6 + §5.6.1.2 both residuals from ONE core evaluation.
        \\/// Equivalent to `.{{ .res = eval(...), .q = q(...) }}`, at half the cost.
        \\pub fn evalQ(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) struct {{ res: contract.Rows(Self, S), q: contract.Sites(Self, S) }} {{
        \\
    , .{});
    try writeLead(self, "evalQ", ".{ .res = out.res, .q = out.q }");
    try self.w(
        \\{s}    const xs = zProbe(S, x);
        \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
        \\{s}{s}
    , .{
        if (gen_file.hasStatus(self)) status_pre ++ zero_both else "",
        self.heldArg(false),
        if (self.lowered.timepoints.items.len != 0) "    zTpStore(inst, sim, m);\n" else "",
        if (gen_file.hasStatus(self)) status_post ++ zero_both else "",
    });
    // §5.6.1.2 the charges, one per site, off the same core.
    try self.b("    return .{{ .res = zResidual(S, xs, m), .q = ", .{});
    try writeSites(self);
    try self.b(" }};\n}}\n\n", .{});
}

/// Emits the §5.6.1.3 runtime-selected branch row: §5.6.5's switch branch,
/// and the clause's "otherwise the branch is an open circuit" case for a lone
/// conditional potential contribution.
///
/// The matrix structure stays constant: the branch always carries its flow
/// unknown I_b, stamped ±I_b into the two KCL rows, and only the branch row's
/// content is selected per cycle on the retention flags:
///
///     V retained this cycle:  res[u] = V(hi) − V(lo) − c_V   (potential source)
///     else I retained:        res[u] = I_b − c_I             (flow source)
///     else:                   res[u] = I_b                   (open: pins I_b = 0)
///
/// `S.sel` carries the winner's dual, so the Jacobian switches coherently
/// with the row: ±1 on the node columns for the potential form, 1 on the
/// I_b column (and −∂c_I/∂x) for the flow form, a bare 1 on I_b for the
/// open circuit, so never singular. In the q residual the same select runs
/// over the fluxes (−φ, §5.6.1.2), the open case contributing none.
///
/// The flow form's ±c_I KCL stamps are not emitted (`flowIsMerged`): the
/// retained flow reaches KCL through I_b, which the row pins to c_I.
///
/// A collapsible branch (`collapsePairs`) is the exception: `collapse`
/// deletes I_b from the host's maps, so the row is split on the retention
/// flag, a `buildFree` value fixed for the whole simulation (a real `if`):
///
///   flag set (0 V arm, dead short): the host aliased hi, lo and I_b onto
///     one unknown, so ±I_b and `V(hi) − V(lo)` would add and subtract the
///     same slot, and float addition there is not exact. A host that applied
///     the aliases gets no stamps; one that did not keeps the full equations.
///   flag clear: I_b does not exist. The branch is a plain conductance whose
///     flow reaches KCL directly, like an unswitched `.flow` (`switchOpen`).
///
/// The guard (`contract.JacWhen`): when the flag depends on the card alone
/// (`CollapsePair.card`), the flag-set arm's coefficients (±1) are constants
/// per card and leave as `jac_const` entries guarded by the published `Model`
/// field, so ib keeps no lane. Any other runtime row keeps every lane.
pub fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void {
    const u = self.names.branch_u[i];
    const partner = plan_topo.switchFlowOf(self.input(), i);
    const split = collapsible(self, i);
    const guard = guardOf(self, i);
    // Every coefficient on this row, and ib's in KCL, is picked per cycle by
    // a runtime flag, so every unknown it names keeps a lane, as does
    // whatever the row held before, unless the guard states them.
    if (guard) |k| {
        if (!react) {
            try guardTerm(self, c.hi, u, 1, k);
            try guardTerm(self, c.lo, u, -1, k);
            try guardTerm(self, u, c.hi, 1, k);
            try guardTerm(self, u, c.lo, -1, k);
        }
    } else self.jac.deriv_reads |= uBit(u) | nodeBit(c.hi) | nodeBit(c.lo);
    linDynamic(self, u);
    const d: u32 = if (split) 4 else 2;
    if (split) {
        try self.ind(2);
        try self.b("if (", .{});
        try coreRef(self, flag);
        if (self.an.vty[@backingInt(self.an.rv(flag))] == .int)
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
        try rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", ", .{});
        try nodeVoltage(self, c.hi);
        try self.b(".sub(", .{});
        try nodeVoltage(self, c.lo);
        try self.b(").sub(c), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try rowEnd(self);
    } else {
        try self.ind(d);
        patRow(self, @intCast(u), uBit(u) | switchRowDeps(self, i, c, react));
        try rowSet(self, u);
        try self.b("S.sel(", .{});
        try coreRef(self, flag);
        try self.b(", c.neg(), ", .{});
        try switchElse(self, partner, react);
        try self.b(")", .{});
        try rowEnd(self);
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

/// Returns whether `collapse` aliases potential contribution `i` away. Keyed on the
/// branch-flow unknown, which `contribIndex` makes unique per branch.
pub fn collapsible(self: *const Gen, i: usize) bool {
    const u = self.names.branch_u[i];
    if (u == none_u32) return false;
    for (self.topo.cpairs) |p| if (p.flow_u == u) return true;
    return false;
}

/// Returns the `cpairs` index whose card-only flag guards contribution `i`'s
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
    try self.jac.guarded.append(self.arena, .{ .row = row, .col = col, .g = g, .c = 0, .when = k });
}

/// Returns `<flow unknown>__retained`: the `Model` field `derive` publishes
/// pair `k`'s retention flag in, and the name a guarded `jac_const` entry cites.
pub fn guardField(self: *const Gen, k: u32) Error![]const u8 {
    return self.arena.print("{s}__retained", .{self.names.u_names[self.topo.cpairs[k].flow_u]});
}

/// The value the branch row would have PINNED I_b to, for the arm where
/// I_b no longer exists: the partner's retained flow, or zero when nothing
/// is retained (§5.6.1.3's open circuit). `switchElse` writes the same
/// cases as a residual (`I_b − c` and `−φ`); this is that residual solved
/// for I_b, so the signs are the plain `.flow` stamp's.
fn switchOpen(self: *Gen, partner: ?usize, react: bool) Error!void {
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
fn switchElse(self: *Gen, partner: ?usize, react: bool) Error!void {
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
fn coreRef(self: *Gen, v: Mir.Value) Error!void {
    if (v == .f_zero) return self.b("S.con(0.0)", .{});
    try self.b("m.f{d}", .{self.core.lo_idx[@backingInt(v)]});
}

/// Emits one term into row `node`: `opx` (`add`/`sub`) of `val`, recording
/// `bits` in the row pattern. `col` names the unknown when `val` is exactly `x[col]` (a ±1 term
/// whose coefficient `Gen.jac.lin` records), and is null for a core value, whose
/// lanes `renderValueRef` already marked. Ground has no row and writes nothing.
pub fn stamp(self: *Gen, depth: u32, node: u16, opx: []const u8, val: []const u8, bits: u64, col: ?u32) Error!void {
    if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
    patRow(self, node, bits);
    if (col) |k| linTerm(self, node, k, if (std.mem.eql(u8, opx, "add")) 1 else -1);
    try self.ind(depth);
    try rowSet(self, node);
    try self.b("res[@intFromEnum(U.{s})].{s}({s})", .{ self.names.u_names[node], opx, val });
    try rowEnd(self);
}

/// `res[@intFromEnum(U.<u>)] = zRow(S, .<u>, `: row `u` is typed by its
/// pattern (`contract.rowMask`), so every value assigned to it widens there.
/// `rowEnd` closes it.
fn rowSet(self: *Gen, u: u32) Error!void {
    const n = self.names.u_names[u];
    try self.b("res[@intFromEnum(U.{s})] = ", .{n});
    try self.b("zRow(S, .{s}, ", .{n});
}

fn rowEnd(self: *Gen) Error!void {
    try self.b(");\n", .{});
}

/// Records that row `node` of the half being emitted (`jac.react`) gained a
/// term whose derivative lives in `bits`, and that the row is written at all
/// (`rows`). Ground has no row. Every `res[...]` writer calls this.
pub fn patRow(self: *Gen, node: u16, bits: u64) void {
    if (node == Lower.ground) return;
    if (self.jac.pat[@intFromBool(self.jac.react)].len == 0) return;
    self.jac.pat[@intFromBool(self.jac.react)][node] |= bits;
    // A superset: a stamp of `x[u]` itself (an `ib`) is marked when the
    // contribution reaches `u` through an operator too.
    self.jac.dpat[node] |= self.jac.cur_dyn & bits;
    self.jac.rows[@intFromBool(self.jac.react)] |= uBit(node);
}

/// Records that row `row` of the half being emitted gains `k · x[col]`. The
/// `lin*` writers mirror the `res[...]` text beside them as `patRow` does:
/// only a ±1 on an unknown is recorded; every other term is a core value
/// whose lanes are already marked.
fn linTerm(self: *Gen, row: u32, col: u32, k: f64) void {
    if (row == Lower.ground or col == Lower.ground) return;
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    l[row * self.names.n_u + col] += k;
}

/// Records that row `row` is assigned a term with no recorded unknown in it.
fn linClear(self: *Gen, row: u32) void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    @memset(l[row * self.names.n_u ..][0..self.names.n_u], 0);
    // Its guarded constants go with the assignment too.
    if (self.jac.react) return;
    var k: usize = 0;
    while (k < self.jac.guarded.items.len) {
        if (self.jac.guarded.items[k].row == row) _ = self.jac.guarded.orderedRemove(k) else k += 1;
    }
}

/// Records that row `row` is assigned `V(hi) − V(lo) − <core value>`: §5.6's branch
/// relation, and §5.4.2.1's zero-potential flow probe.
fn linBranch(self: *Gen, row: u32, hi: u16, lo: u16) void {
    linClear(self, row);
    linTerm(self, row, hi, 1);
    linTerm(self, row, lo, -1);
}

/// Records §5.4.3 `res[u] = x[u] − res[port]` (eval) or `−res[port]` (q):
/// the row is the finished port row negated, so its constants are too.
fn linPortProbe(self: *Gen, u: u32, port: u32, with_x: bool) Error!void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    const n = self.names.n_u;
    for (0..n) |c| l[u * n + c] = -l[port * n + c];
    if (with_x) l[u * n + u] += 1;
    // The port row's guarded constants are copied too, under the same guard
    // (`emitSwitchRow`): they are eval-only, and each is appended once per row.
    if (self.jac.react) return;
    const k0 = self.jac.guarded.items.len;
    for (0..k0) |k| {
        const e = self.jac.guarded.items[k];
        if (e.row != port) continue;
        try self.jac.guarded.append(self.arena, .{ .row = u, .col = e.col, .g = 0 - e.g, .c = 0 - e.c, .when = e.when });
    }
}

/// Records that row `row` is about to be written under a runtime condition:
/// its constants may not survive, so each of their columns keeps a lane.
fn linDynamic(self: *Gen, row: u32) void {
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    for (l[row * self.names.n_u ..][0..self.names.n_u], 0..) |k, c| {
        if (k != 0) self.jac.deriv_reads |= uBit(@intCast(c));
    }
}

/// Emits `deriv_reads`, `ddx_reads` and `jac_const` (`contract.derivReads`).
/// Must run after every unit and residual is written, since all three are
/// read off them. Sound because an unknown's lane matters only if emitted
/// text reads `x[u]` or `.ddxAt(u)`: `renderValueRef` marks every read in a
/// core or unit, `ddx` marks `ddx_reads`, and the dispatcher marks every
/// unknown under a runtime-selected row. An unmarked unknown is read only in
/// the dispatcher's unconditional ±1 stamps, which `lin` replays exactly.
/// Omitted above 64 unknowns, where the defaults (every lane) are correct.
pub fn emitDerivReads(self: *Gen, limit_writes: u64) Error!void {
    const jc = try plan_jac.plan(self.arena, self.names.n_u, self.jac.deriv_reads, self.jac.ddx_reads, limit_writes, .{ self.jac.lin[0], self.jac.lin[1] }, self.jac.guarded.items) orelse return;
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
    , .{ jc.mask, self.jac.ddx_reads });
    for (jc.entries) |e| {
        try self.w("    .{{ .row = .{s}, .col = .{s}, .g = {s}, .c = {s}", .{
            self.names.u_names[e.row], self.names.u_names[e.col], try gen_file.fmtF64(self, e.g), try gen_file.fmtF64(self, e.c),
        });
        if (e.when) |k| try self.w(", .when = .{{ .flag = \"{s}\", .collapse_open = true }}", .{try guardField(self, k)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
    try family.emitLaneMasks(self, jc.mask);
}

/// Returns the column bit of unknown `u`. Above 63 it returns every bit, the
/// dense fallback `emitPattern` also takes.
pub fn uBit(u: u32) u64 {
    return if (u >= 64) std.math.maxInt(u64) else @as(u64, 1) << @intCast(u);
}

/// Same, for a node that may be ground (no unknown, no column).
fn nodeBit(node: u16) u64 {
    return if (node == Lower.ground) 0 else uBit(node);
}

/// The columns accumulated so far on row `u` of the half being emitted.
fn patOf(self: *const Gen, u: u32) u64 {
    const half = self.jac.pat[@intFromBool(self.jac.react)];
    return if (half.len == 0) std.math.maxInt(u64) else half[u];
}

/// Returns the columns contribution `i`'s rows reach through a
/// frequency-dependent operator: its value's, and a §5.6.5 switch partner's,
/// whose value the same row selects (`switchRowDeps`).
fn contribDyn(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) u64 {
    if (self.an.acdyn.len == 0) return 0;
    var acc = self.an.acDynDeps(if (react) c.react_val else c.resist_val);
    if (plan_topo.switchFlowOf(self.input(), i)) |j| {
        const f = self.lowered.contributions.items[j];
        acc |= self.an.acDynDeps(if (react) f.react_val else f.resist_val);
    }
    return acc;
}

/// Returns the columns of the row `emitSwitchRow` emits. The `S.sel` arm is
/// chosen at run time, so the row carries every arm's columns: its own
/// value, the switch partner's, and `ib`.
fn switchRowDeps(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) u64 {
    var acc = uBit(self.names.branch_u[i]) |
        self.an.unknownDeps(if (react) c.react_val else c.resist_val);
    if (plan_topo.switchFlowOf(self.input(), i)) |j| {
        const f = self.lowered.contributions.items[j];
        acc |= self.an.unknownDeps(if (react) f.react_val else f.resist_val);
    }
    return acc;
}

fn nodeVoltage(self: *Gen, node: u16) Error!void {
    if (node == Lower.ground) return self.b("S.con(0.0)", .{});
    try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[node]});
}

/// Emits the §4.6.4 noise tables: `noise_gens[k]` (branch and kind),
/// `noisePsd(x, m, i)[k]` (the PSD from the model's own expression at any
/// state vector) and `noise_tables` (the knots of §4.6.4.3/.4 table
/// sources). The kind alone cannot give the PSD: `white_noise(2·q·|I|)` and
/// `white_noise(4·k·T/R)` are the same call with different arguments.
///
/// One entry per generator, not per contribution (a branch may carry
/// several). §4.6.4.6 correlation is the `source` column: the declaring
/// call's AST id, renumbered densely in first-seen order. A table row's
/// `PsdTerm` is all zero, so `white + flicker/f^ef + table` is the whole
/// spectrum for every kind. A generator that cannot be exported (a
/// ground-ground branch, E0520; non-constant table pairs, E0519) replaces
/// the whole `noise_gens` decl with a `@compileError` (`refuseNoise`).
pub fn emitNoiseTable(self: *Gen) Error!void {
    if (self.noise.fatal) |msg| {
        // A `@compileError` value, not a statement: a host that never touches
        // noise still builds, and one that reads `noise_gens` gets this
        // message instead of a table missing a generator.
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

    // §4.6.4.1/.2 the PSDs, positionally, from one value-only core sweep at
    // the caller's state vector. A generator whose statement did not execute
    // at this bias reads the zero `probeBody` seeds, its physical answer.
    try self.w(
        \\/// §4.6.4.1/.2 each generator's PSD at `x`: S(f) = white + flicker/f^ef.
        \\/// Position k belongs to `noise_gens[k]`. A §4.6.4.3/.4 `.table` row
        \\/// reads zero here — its spectrum is `noise_tables[k]` instead.
        \\pub fn noisePsd(comptime
    , .{});
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) [noise_gens.len]contract.PsdTerm {{\n", .{});
    const full = self.core;
    defer self.core = full;
    if (self.noise_core.lo_vals.len != 0) {
        self.core = self.noise_core;
        try self.w("    const m = {s}(S, zVals(S, &x), model, {s}, sim{s});\n", .{ self.core.name, try gen_setup.probeInstance(self), self.heldArg(true) });
    } else {
        gen_unit.patchParam(self, at_s, "S".len);
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_model, "model".len);
        gen_unit.patchParam(self, at_inst, "inst".len);
        gen_unit.patchParam(self, at_sim, "sim".len);
    }
    try self.w("    return .{{\n", .{});
    for (self.noise.rows) |nr| {
        // §4.6.4.6's per-use factor rides beside the PSD rather than folded
        // in: a table row's spectrum is comptime data that cannot absorb a
        // bias-dependent factor, and two rows sharing a source need both
        // coefficients, since their signed product is the cross-spectrum.
        const coeff = try psdRef(self, nr.coeff, true);
        switch (nr.kind) {
            // §4.6.4.3/.4 the table is the spectrum: anything here would be
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

/// Emits `<core>__noise`, the core's slice computing only the PSD arguments
/// `noisePsd` reads off it. Called from `emitUnits`, so its range tiles with
/// the other unit declarations.
pub fn emitNoiseCore(self: *Gen) Error!void {
    if (self.noise.fatal != null or self.noise.rows.len == 0) return;
    const keep = try self.arena.alloc(bool, self.core.lo_vals.len);
    @memset(keep, false);
    var any = false;
    for (self.noise.rows) |nr| for ([_]Mir.Value{ nr.pwr, nr.exp, nr.coeff }) |v| {
        const k = coreIdx(self, v) orelse continue;
        keep[k] = true;
        any = true;
    };
    if (!any) return;
    self.noise_core = try gen_unit.sliceCore(self, "noise", keep,
        \\/// §4.6.4 the PSD arguments the core computes, and only what they read:
        \\/// `noisePsd` evaluates them at the operating point `x`.
        \\
    );
}

/// Emits `noiseTablePoints`: the knots of every §4.6.4.3 table as the model
/// card sets them, since "the vector can either be specified as an array
/// parameter" and `noise_tables` holds only the declared defaults. One flat
/// array in `noise_tables` order (a per-table return type would be generic,
/// which `contract.expectFn` cannot check); table k starts at the sum of the
/// earlier `noise_tables[i].points.len`. Emitted only when some knot is a
/// parameter. Re-sorted at run time, because §4.6.4.3's "the simulator shall
/// internally sort the pairs into ascending frequency" must hold for any card.
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
    const saved_model = self.uses.model;
    self.uses.model = false;
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
    const reads_model = self.uses.model;
    self.uses.model = saved_model or reads_model;
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

/// Emits the §4.6.3 AC stimulus tables: `ac_gens[k]` (branch and analysis
/// name, model text) and `acStim(x, m, i)[k]` (`(mag, phase)`, which the
/// card or the solve may set). The residual is real and carries only
/// `mag·cos(phase)`; this table is the whole phasor, and a host solving a
/// complex system reads it instead of the residual term (`contract.AcGen`).
/// It takes the state vector because A.8.2 makes both arguments
/// `analog_expression`; a stimulus that folds renders over `Model` alone.
pub fn emitAcTable(self: *Gen) Error!void {
    if (self.noise.ac_rows.len == 0) return;

    // Rendered before anything is written, so the `x`/`model`/`inst`
    // parameters can be patched to `_` when nothing reached them, as
    // `emitUnit` does. The flags are Gen-wide, so they are saved.
    const saved_model = self.uses.model;
    const saved_inst = self.uses.inst;
    self.uses.model = false;
    self.uses.inst = false;
    const vals = try self.arena.alloc([2][]const u8, self.noise.ac_rows.len);
    var all_stated = true;
    var uses_core = false;
    for (self.noise.ac_rows, vals) |nr, *v| {
        // §4.6.4.6's per-use coefficient, folded into the magnitude: a real
        // factor scales a phasor exactly (a negative one rides as a negative
        // magnitude), and stimuli have no cross-spectrum or comptime table
        // to keep it out of.
        const mag = try acRef(self, nr.pwr, &uses_core);
        const phase = try acRef(self, nr.exp, &uses_core);
        const coeff = try acRef(self, nr.coeff, &uses_core);
        if (mag == null or phase == null or coeff == null) {
            all_stated = false;
            break;
        }
        v.* = .{
            if (nr.coeff == .f_one) mag.? else try self.arena.print("({s}) * ({s})", .{ mag.?, coeff.? }),
            phase.?,
        };
    }
    const reads_model = self.uses.model or uses_core;
    const reads_inst = self.uses.inst or uses_core;
    self.uses.model = saved_model or reads_model;
    self.uses.inst = saved_inst or reads_inst;
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
        \\pub fn acStim(comptime
    , .{});
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) [ac_gens.len]contract.AcPhasor {{\n", .{});
    if (!uses_core) {
        gen_unit.patchParam(self, at_s, "S".len);
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_sim, "sim".len);
    }
    if (!reads_model) gen_unit.patchParam(self, at_model, "model".len);
    if (!reads_inst) gen_unit.patchParam(self, at_inst, "inst".len);
    if (uses_core) {
        try self.w("    const m = core(S, zVals(S, &x), model, {s}, sim{s});\n", .{ try gen_setup.probeInstance(self), self.heldArg(true) });
    }
    try self.w("    return .{{\n", .{});
    for (vals) |v| try self.w("        .{{ .mag = {s}, .phase = {s} }},\n", .{ v[0], v[1] });
    try self.w("    }};\n}}\n\n", .{});
}

/// Returns one §4.6.3 magnitude, phase or §4.6.4.6 coefficient in `acStim`'s
/// frame: `f64Const` over `Model` when it folds, else the core field
/// `buildJobs` queued (setting `uses_core`). Null means neither, a planning
/// defect that `refuseAc` reports instead of exporting a wrong number.
fn acRef(self: *Gen, v: Mir.Value, uses_core: *bool) Error!?[]const u8 {
    if (try gen_call.f64Const(self, v, 0, false)) |s| return s;
    const k = self.core.lo_idx[@backingInt(v)];
    if (k == none_u32) return null;
    uses_core.* = true;
    return try self.arena.print("m.f{d}.val()", .{k});
}

/// Emits `ac_gens` as a `@compileError` value for a §4.6.3 stimulus VerA
/// cannot state, as `refuseNoise` does for `noise_gens`. No diagnostic of its
/// own: `emitCall` already reported E0515 on the same argument.
fn refuseAc(self: *Gen) Error!void {
    try self.w("/// §4.6.3 refused by codegen; see the diagnostic.\n", .{});
    try self.w("pub const ac_gens = @compileError(\"LRM 4.6.3: an ac_stim magnitude or " ++
        "phase must be a constant or parameter expression\");\n\n", .{});
}

/// Returns `Lower.NoiseKind` as a `contract.NoiseGen.kind` name. §4.6.4.3
/// and §4.6.4.4 are one exported kind: the host reads `noise_tables` for
/// either, and the table's `interp` field says which interpolation.
fn contractNoiseKind(k: Lower.NoiseKind) []const u8 {
    return switch (k) {
        .thermal => "thermal",
        .flicker => "flicker",
        .table, .table_log => "table",
        // §4.6.3 has no `NoiseGen.kind` because it has no `noise_gens` row.
        .ac_stim => unreachable,
    };
}

/// Returns the core field holding `v`, or null when `v` is rendered inline
/// (structurally zero, or a constant `plan_core.plan` never carries).
pub fn coreIdx(self: *const Gen, v: Mir.Value) ?u32 {
    if (v == .f_zero) return null;
    const k = self.core.lo_idx[@backingInt(v)];
    return if (k == none_u32) null else k;
}

/// Returns one PSD argument as an `f64` expression in `noisePsd`'s body.
/// `is_exp` allows the inline-constant shortcut, which only the exponent may
/// take (see `buildJobs`).
fn psdRef(self: *Gen, v: Mir.Value, is_exp: bool) Error![]const u8 {
    if (v == .f_zero) return "0";
    if (is_exp) if (plan_noise.psdConst(self.mir, v)) |c| return try self.arena.print("{d}", .{c});
    const k = self.core.lo_idx[@backingInt(v)];
    // A live-out the planner dropped cannot happen (`buildJobs` queued it),
    // but a zero is the one answer that cannot invent noise.
    if (k == none_u32) return "0";
    return try self.arena.print("m.f{d}.val()", .{k});
}
