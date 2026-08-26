//! The `--dyn` host `vera --emit-osdi` builds a device under: a VerA device
//! (tools/contract.zig) in, an OSDI 0.4 shared object out, so a simulator
//! that loads OpenVAF's `.osdi` files (ngspice `pre_osdi`) loads VerA's.
//! Exports `OSDI_VERSION_MAJOR`/`MINOR`, `OSDI_NUM_DESCRIPTORS` (1),
//! `OSDI_DESCRIPTORS`, `OSDI_DESCRIPTOR_SIZE` and the `osdi_log` slot the
//! simulator fills.
//!
//! Layout and semantics: OpenVAF-Reloaded `openvaf/osdi/header/osdi_0_4.h`
//! and `openvaf/osdi/src/load.rs` at fdf2522b70f4, and ngspice-45
//! `src/osdi/` (osdiregistry.c, osdisetup.c, osdiload.c, osdinoise.c,
//! osdiparam.c), which reads the 0.3 prefix of the descriptor and steps
//! through the array by `OSDI_DESCRIPTOR_SIZE`.
//!
//! The mapping onto the contract:
//!   nodes        every unknown of `U` (ports first, so the first
//!                `num_ports` are the terminals); a `.current`/`.flow`
//!                unknown is an OSDI flow node (ngspice `CKTmkCur`)
//!   Jacobian     every (row, col) in `jac_pattern | q_pattern`, plus the
//!                `jac_const` and `ac_dyn_slots` entries
//!   params       every scalar real, integer or string `Model` field that
//!                is a §3.4 parameter (no `__` in its name), listed TWICE:
//!                as an instance parameter and as a model parameter, since
//!                the contract does not say which a parameter is. An
//!                instance value overrides the card's. `$mfactor` is an
//!                instance parameter when `Instance` has `mfactor`.
//!   eval         one `evalQ` (or `eval`) over the sparse reference family
//!                at the limited point: `seed` under ngspice's INIT_LIM,
//!                `limit` against the previous limited point under
//!                ENABLE_LIM. The residuals and Jacobian are kept in the
//!                instance; the `load_*` calls stamp them, and the RHS is
//!                linearized at the limited point (OpenVAF's lim_rhs).
//!   noise        one OSDI source per `noise_gens` row, its PSD
//!                coeff²·(white + flicker/f^ef + table) from `noisePsd` at the
//!                last evaluated point
//!   $mfactor     §6.3.6's scaling, which the device leaves to its host:
//!                KCL rows (and noise power) times `Instance.mfactor`
//!   temperature  each instance runs on its own `Model` row: the card,
//!                the instance's own parameters and `temperature__`, then
//!                `derive`, `checkShape`, `setup`, `setupInstance`
//!   collapse     a flow unknown whose branch a card switches off
//!                (`<flow>__retained` = 0 after `derive`) collapses into
//!                ground; every other `collapse` alias is left unapplied
//!                (the uncollapsed system is exact, a 0 V branch's flow kept
//!                as an unknown)
//!
//! Not mapped, each because OSDI 0.4 has no slot for it (specification/Vague_Decisions.md
//! VD-102): opvars; correlated noise (`NoiseGen.source` shared by rows,
//! `PsdTerm.corr_with`): each row is an independent source, and `vera`
//! warns W1098; a step rejection a device asks for (`request_reject_at`),
//! which `vera` refuses (E1099) before building this; the device's display
//! records (`say`); and acceptance itself: OSDI has no accept
//! callback, so `updateState` and `stateCtl(.commit)` run at every iterate
//! of a static solve and, in a transient, at the last point evaluated before
//! the simulator moves time forward (a rejected step retries at an earlier
//! time, so it is never committed). `$bound_step` is `bound_step_offset`.
//!
//! Host-only: never imported by the device text, so the device stays
//! GPU-compilable.

/// Opt into the contract's conformance checks (AGENTS.md §6).
pub const vera_validate_contract = true;

const std = @import("std");
const contract = @import("contract");

// ---------------------------------------------------------------------------
// osdi_0_4.h
// ---------------------------------------------------------------------------

const Str = ?[*:0]const u8;
const no_off = std.math.maxInt(u32);

const para_ty_real: u32 = 0;
const para_ty_int: u32 = 1;
const para_ty_str: u32 = 2;
const para_kind_inst: u32 = 1 << 30;

const access_flag_set: u32 = 1;
const access_flag_instance: u32 = 4;

const jacobian_entry_resist: u32 = 4;
const jacobian_entry_react: u32 = 8;

const calc_react_residual: u32 = 2;
const enable_lim: u32 = 256;
const init_lim: u32 = 512;
const analysis_noise: u32 = 1024;
const analysis_ac: u32 = 4096;
const analysis_tran: u32 = 8192;

const eval_ret_flag_lim: u32 = 1;
const eval_ret_flag_fatal: u32 = 2;

const log_lvl_warn: u32 = 3;
const log_lvl_err: u32 = 4;
const log_lvl_fatal: u32 = 5;

const SimParas = extern struct {
    names: ?[*]const Str,
    vals: ?[*]const f64,
    names_str: ?[*]const Str,
    vals_str: ?[*]const Str,
};
const SimInfo = extern struct {
    paras: SimParas,
    abstime: f64,
    prev_solve: [*]const f64,
    prev_state: ?[*]f64,
    next_state: ?[*]f64,
    flags: u32,
};
const InitError = extern struct { code: u32, parameter_id: u32 };
const InitInfo = extern struct { flags: u32, num_errors: u32, errors: ?*InitError };
const NodePair = extern struct { node_1: u32, node_2: u32 };
const JacobianEntry = extern struct { nodes: NodePair, react_ptr_off: u32, flags: u32 };
const Node = extern struct {
    name: Str,
    units: Str,
    residual_units: Str,
    resist_residual_off: u32,
    react_residual_off: u32,
    resist_limit_rhs_off: u32,
    react_limit_rhs_off: u32,
    is_flow: bool,
};
const ParamOpvar = extern struct {
    name: [*]const Str,
    num_alias: u32,
    description: Str,
    units: Str,
    flags: u32,
    len: u32,
};
const NoiseSource = extern struct { name: Str, nodes: NodePair };
const NatureRef = extern struct { ref_type: u32, index: u32 };
const AbsDelayInfo = extern struct {
    input_node_1: u32,
    input_node_2: u32,
    output_node: u32,
    delay_offset: u32,
    max_delay_offset: u32,
};

const Descriptor = extern struct {
    name: Str,
    num_nodes: u32,
    num_terminals: u32,
    nodes: [*]const Node,
    num_jacobian_entries: u32,
    jacobian_entries: [*]const JacobianEntry,
    num_collapsible: u32,
    collapsible: ?[*]const NodePair,
    collapsed_offset: u32,
    noise_sources: ?[*]const NoiseSource,
    num_noise_src: u32,
    num_params: u32,
    num_instance_params: u32,
    num_opvars: u32,
    param_opvar: [*]const ParamOpvar,
    node_mapping_offset: u32,
    jacobian_ptr_resist_offset: u32,
    num_states: u32,
    state_idx_off: u32,
    bound_step_offset: u32,
    instance_size: u32,
    model_size: u32,
    access: *const fn (?*anyopaque, ?*anyopaque, u32, u32) callconv(.c) ?*anyopaque,
    setup_model: *const fn (?*anyopaque, *anyopaque, *const SimParas, *InitInfo) callconv(.c) void,
    setup_instance: *const fn (?*anyopaque, *anyopaque, *anyopaque, f64, u32, *const SimParas, *InitInfo) callconv(.c) void,
    eval: *const fn (?*anyopaque, *anyopaque, *const anyopaque, *const SimInfo) callconv(.c) u32,
    load_noise: *const fn (*anyopaque, *anyopaque, f64, [*]f64) callconv(.c) void,
    load_residual_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_residual_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_limit_rhs_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_limit_rhs_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    load_spice_rhs_dc: *const fn (*anyopaque, *anyopaque, [*]f64, [*]const f64) callconv(.c) void,
    load_spice_rhs_tran: *const fn (*anyopaque, *anyopaque, [*]f64, [*]const f64, f64) callconv(.c) void,
    load_jacobian_resist: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    load_jacobian_react: *const fn (*anyopaque, *anyopaque, f64) callconv(.c) void,
    load_jacobian_tran: *const fn (*anyopaque, *anyopaque, f64) callconv(.c) void,
    // 0.4 additions, past the 0.3 prefix ngspice-45 reads.
    given_flag_model: *const fn (*anyopaque, u32) callconv(.c) u32,
    given_flag_instance: *const fn (*anyopaque, u32) callconv(.c) u32,
    num_resistive_jacobian_entries: u32,
    num_reactive_jacobian_entries: u32,
    write_jacobian_array_resist: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    write_jacobian_array_react: *const fn (*anyopaque, *anyopaque, [*]f64) callconv(.c) void,
    num_inputs: u32,
    inputs: ?[*]const NodePair,
    // ponytail: the remaining 0.4 slots are null/0: no 0.4 host here calls
    // them (ngspice-45 stops at load_jacobian_tran). Fill them when one does.
    load_jacobian_with_offset_resist: ?*const fn (*anyopaque, *anyopaque, usize) callconv(.c) void,
    load_jacobian_with_offset_react: ?*const fn (*anyopaque, *anyopaque, usize) callconv(.c) void,
    unknown_nature: ?[*]const NatureRef,
    residual_nature: ?[*]const NatureRef,
    noise_source_type: ?[*]const u32,
    load_noise_params: ?*const fn (*anyopaque, *anyopaque, [*]f64, [*]f64) callconv(.c) void,
    absdelay_count: u32,
    absdelay_info: ?[*]const AbsDelayInfo,
};

const osdi_version_major: u32 = 0;
const osdi_version_minor: u32 = 4;
const osdi_num_descriptors: u32 = 1;
const osdi_descriptor_size: u32 = @sizeOf(Descriptor);
/// ngspice writes its logger here when it loads the library (INIT_CALLBACK).
var osdi_log: ?*const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) void = null;

fn log(handle: ?*anyopaque, lvl: u32, msg: []const u8) void {
    const f = osdi_log orelse return;
    var buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}\n", .{msg}, 0) catch return;
    f(handle, z.ptr, lvl);
}

/// The `dyn` hook `vera --emit-so` calls: exports device `D` as the one
/// OSDI descriptor, named `name` (the module's name, which a `.model` card
/// names).
pub fn exportDevice(comptime D: type, comptime name: []const u8) void {
    const H = Osdi(D, name);
    contract.validateHost(H, D);
    @export(&osdi_version_major, .{ .name = "OSDI_VERSION_MAJOR" });
    @export(&osdi_version_minor, .{ .name = "OSDI_VERSION_MINOR" });
    @export(&osdi_num_descriptors, .{ .name = "OSDI_NUM_DESCRIPTORS" });
    @export(&osdi_descriptor_size, .{ .name = "OSDI_DESCRIPTOR_SIZE" });
    @export(&H.descriptors, .{ .name = "OSDI_DESCRIPTORS" });
    @export(&osdi_log, .{ .name = "osdi_log" });
}

/// `name` as a C string, VerA's identifier escape undone (`naming.sanitize`:
/// `Z<hex><hex>` is one byte, a trailing lone `Z` marks a Zig keyword).
fn cName(comptime s: []const u8) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var i = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == 'Z' and i + 3 <= s.len) {
                out = out ++ [_]u8{std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable};
                i += 2;
            } else if (s[i] != 'Z') out = out ++ [_]u8{s[i]};
        }
        const z = out ++ [_]u8{0};
        return z[0..out.len :0];
    }
}

fn Osdi(comptime D: type, comptime name: []const u8) type {
    @setEvalBranchQuota(10_000_000);
    return struct {
        const n = contract.nU(D);
        const State = if (contract.stateClass(D) == .none) void else D.State;

        // validateHost's obligations, each met below.
        pub const calls_setup = true;
        pub const mutable_eval = true;
        pub const iteration_hooks = true;
        pub const noise_table_points = true;
        pub const shape_check = true;
        pub const calls_ac_dyn = true;

        /// The value-only hooks' family: no lanes.
        const Val = contract.RefFamily(f64, &@as([n]u8, @splat(contract.no_lane)), .{ .dense = true });
        /// `eval`'s family: unknown `u` on lane `u`.
        const Dual = contract.RefFamily(f64, &lanes, .{ .dense = false });
        const lanes = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [n]u8 = undefined;
            for (&a, 0..) |*l, i| l.* = i;
            break :blk a;
        };
        const has_q = @hasDecl(D, "q");

        // ---- parameters ----------------------------------------------------

        const Kind = enum { real, int, str };
        const Param = struct { field: []const u8, kind: Kind };
        /// The §3.4 parameters: `Model` fields with no `__` (VerA's own
        /// fields all carry one, and a sanitized leaf never does) other
        /// than the setup cache.
        const params: []const Param = blk: {
            @setEvalBranchQuota(10_000_000);
            var ps: []const Param = &.{};
            const s = @typeInfo(D.Model).@"struct";
            for (s.field_names, s.field_types) |f, T| {
                if (std.mem.indexOf(u8, f, "__") != null or std.mem.eql(u8, f, "su") or std.mem.eql(u8, f, "su_ok")) continue;
                const k: Kind = switch (@typeInfo(T)) {
                    .float => .real,
                    .int => .int,
                    else => if (T == []const u8) .str else continue,
                };
                ps = ps ++ [_]Param{.{ .field = f, .kind = k }};
            }
            break :blk ps;
        };
        const np = params.len;
        const has_mf = @hasField(D.Instance, "mfactor");
        const num_inst_params = np + @intFromBool(has_mf);
        const num_params = num_inst_params + np;

        /// One 8-byte slot per parameter, in OSDI's C types: double, int32,
        /// char*. ngspice writes them through `access` before setup.
        const Vals = [np]u64;

        fn slot(comptime T: type, vals: *Vals, comptime i: usize) *T {
            return @ptrCast(@alignCast(&vals[i]));
        }

        /// Writes the given parameters of `vals` into `m`.
        fn overlay(m: *D.Model, vals: *Vals, given: *const [np]bool) void {
            @setEvalBranchQuota(10_000_000);
            inline for (params, 0..) |p, i| if (given[i]) {
                const F = @FieldType(D.Model, p.field);
                @field(m, p.field) = switch (p.kind) {
                    .real => @floatCast(slot(f64, vals, i).*),
                    .int => @intCast(slot(i32, vals, i).*),
                    .str => if (slot(Str, vals, i).*) |z| std.mem.span(z) else @as(F, ""),
                };
                if (@hasField(D.Model, p.field ++ "__given")) @field(m, p.field ++ "__given") = true;
            };
        }

        /// Writes `m`'s value of every parameter not given into `vals`, so a
        /// host reading one back (ngspice `show`) sees the default.
        fn readback(m: *const D.Model, vals: *Vals, given: *const [np]bool) void {
            @setEvalBranchQuota(10_000_000);
            inline for (params, 0..) |p, i| if (!given[i]) switch (p.kind) {
                .real => slot(f64, vals, i).* = @field(m, p.field),
                .int => slot(i32, vals, i).* = std.math.lossyCast(i32, @field(m, p.field)),
                // ponytail: a default string is not known to be NUL-terminated.
                .str => slot(Str, vals, i).* = null,
            };
        }

        const host_fields = [_][2][]const u8{
            .{ "tnom", "nom_temp__" },
            .{ "gmin", "gmin__" },
            .{ "reltol", "reltol__" },
            .{ "abstol", "abstol__" },
            .{ "vntol", "vntol__" },
            .{ "sourceScaleFactor", "source_scale__" },
        };

        /// Copies the simulator's `$simparam` values into `m`'s host fields;
        /// returns whether one changed.
        fn hostParams(m: *D.Model, p: SimParas) bool {
            @setEvalBranchQuota(10_000_000);
            const names = p.names orelse return false;
            const vals = p.vals orelse return false;
            var changed = false;
            var i: usize = 0;
            while (names[i]) |nm| : (i += 1) {
                inline for (host_fields) |h| if (@hasField(D.Model, h[1]) and std.mem.eql(u8, std.mem.span(nm), h[0])) {
                    if (@field(m, h[1]) != vals[i]) changed = true;
                    @field(m, h[1]) = vals[i];
                };
            }
            return changed;
        }

        // ---- Jacobian entries ----------------------------------------------

        const Entry = struct { r: u8, c: u8, resist: bool, react: bool };
        fn bit(row: anytype, c: usize) bool {
            return c >= @bitSizeOf(@TypeOf(row)) or (row >> @intCast(c)) & 1 != 0;
        }
        const entries: []const Entry = blk: {
            @setEvalBranchQuota(10_000_000);
            var es: []const Entry = &.{};
            for (0..n) |r| for (0..n) |c| {
                var e: Entry = .{ .r = r, .c = c, .resist = bit(if (@hasDecl(D, "jac_pattern")) D.jac_pattern[r] else ~@as(u64, 0), c), .react = has_q and bit(if (@hasDecl(D, "q_pattern")) D.q_pattern[r] else ~@as(u64, 0), c) };
                for (contract.jacConst(D)) |j| if (@backingInt(j.row) == r and @backingInt(j.col) == c) {
                    e.resist = e.resist or j.g != 0;
                    e.react = e.react or j.c != 0;
                };
                for (contract.acDynSlots(D)) |s| if (s == r * n + c) {
                    e.resist = true;
                    e.react = true;
                };
                if (e.resist or e.react) es = es ++ [_]Entry{e};
            };
            break :blk es;
        };
        const nj = entries.len;
        fn entryOf(comptime r: usize, comptime c: usize) usize {
            @setEvalBranchQuota(10_000_000);
            for (entries, 0..) |e, k| if (e.r == r and e.c == c) return k;
            unreachable;
        }
        /// The §5.4.2 flow unknowns a card can switch off: `derive` writes
        /// `<flow>__retained` = 0 when the branch's `V(...) <+` arm is not
        /// taken, and `eval` then writes neither the flow's row nor its
        /// column. Each is an OSDI collapsible pair into ground, collapsed
        /// in `setupInstance` when off, so the simulator drops the unknown.
        const dead_flows: []const u8 = blk: {
            @setEvalBranchQuota(10_000_000);
            var fs: []const u8 = &.{};
            for (@typeInfo(D.U).@"enum".field_names, 0..) |f, u| {
                if (@hasField(D.Model, f ++ "__retained")) fs = fs ++ [_]u8{u};
            }
            break :blk fs;
        };

        /// Whether row `i` is a KCL row: a voltage unknown's.
        fn kcl(comptime i: usize) bool {
            return !@hasDecl(D, "u_kinds") or D.u_kinds[i] == .voltage;
        }

        /// Rows `q` writes.
        fn reactRow(comptime i: usize) bool {
            @setEvalBranchQuota(10_000_000);
            return has_q and bit(if (@hasDecl(D, "q_rows")) D.q_rows else ~@as(u64, 0), i);
        }

        // ---- model and instance data ---------------------------------------

        const Model = struct {
            vals: Vals,
            given: [np]bool,
            /// The card: defaults, the simulator's `$simparam`s and the given
            /// parameters, before `derive`.
            card: D.Model,
        };

        const Instance = struct {
            vals: Vals,
            given: [np]bool,
            mfactor: f64,
            mfactor_given: bool,
            /// This instance's own `Model` row, derived and set up.
            row: D.Model,
            inst: D.Instance,
            node_mapping: [n]u32,
            collapsed: [@max(dead_flows.len, 1)]bool,
            state_idx: [1]u32,
            jac_ptr: [nj]?*f64,
            react_ptr: [nj]?*f64,
            res: [n]f64,
            q: [n]f64,
            lim_res: [n]f64,
            lim_q: [n]f64,
            jac: [nj]f64,
            jac_q: [nj]f64,
            /// The point `eval` last evaluated at (limited), and the
            /// simulator's unlimited one.
            x: [n]f64,
            cur: [n]f64,
            have_x: bool,
            sim: contract.SimState,
            state: State,
            t_prev: f64,
            t_last: f64,
        };

        comptime {
            // ngspice places both at max_align_t (16 bytes).
            std.debug.assert(@alignOf(Model) <= 16 and @alignOf(Instance) <= 16);
        }

        fn access(ip: ?*anyopaque, mp: ?*anyopaque, id: u32, flags: u32) callconv(.c) ?*anyopaque {
            const set = flags & access_flag_set != 0;
            if (id < np and flags & access_flag_instance != 0) {
                const self: *Instance = @ptrCast(@alignCast(ip orelse return null));
                if (set) self.given[id] = true;
                return &self.vals[id];
            }
            if (has_mf and id == np) {
                const self: *Instance = @ptrCast(@alignCast(ip orelse return null));
                if (set) self.mfactor_given = true;
                return &self.mfactor;
            }
            // A model-side id, or an instance parameter asked of the model
            // (OpenVAF's semantics: the card's value of it).
            const j = if (id < np) id else if (id >= num_inst_params and id < num_params) id - num_inst_params else return null;
            const m: *Model = @ptrCast(@alignCast(mp orelse return null));
            if (set) m.given[j] = true;
            return &m.vals[j];
        }

        fn givenModel(mp: *anyopaque, id: u32) callconv(.c) u32 {
            const m: *Model = @ptrCast(@alignCast(mp));
            if (id < num_inst_params or id >= num_params) return 0;
            return @intFromBool(m.given[id - num_inst_params]);
        }

        fn givenInstance(ip: *anyopaque, id: u32) callconv(.c) u32 {
            const self: *Instance = @ptrCast(@alignCast(ip));
            if (has_mf and id == np) return @intFromBool(self.mfactor_given);
            return if (id < np) @intFromBool(self.given[id]) else 0;
        }

        /// `derive` and `checkShape` on `m`; false (and a fatal log) when
        /// the card moves a shape parameter.
        fn derive(handle: ?*anyopaque, m: *D.Model) bool {
            if (@hasDecl(D, "derive")) D.derive(Val, m);
            if (@hasDecl(D, "checkShape")) if (D.checkShape(m)) |why| {
                log(handle, log_lvl_fatal, why);
                return false;
            };
            if (@hasDecl(D, "checkCard")) if (D.checkCard(m)) |why| log(handle, log_lvl_err, why);
            return true;
        }

        fn setupModel(handle: ?*anyopaque, mp: *anyopaque, paras: *const SimParas, res: *InitInfo) callconv(.c) void {
            const m: *Model = @ptrCast(@alignCast(mp));
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            m.card = .{};
            _ = hostParams(&m.card, paras.*);
            overlay(&m.card, &m.vals, &m.given);
            var d = m.card;
            if (!derive(handle, &d)) res.flags |= eval_ret_flag_fatal;
            readback(&d, &m.vals, &m.given);
        }

        fn setupInstance(handle: ?*anyopaque, ip: *anyopaque, mp: *anyopaque, temperature: f64, connected: u32, paras: *const SimParas, res: *InitInfo) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self: *Instance = @ptrCast(@alignCast(ip));
            const m: *Model = @ptrCast(@alignCast(mp));
            res.* = .{ .flags = 0, .num_errors = 0, .errors = null };
            self.row = m.card;
            _ = hostParams(&self.row, paras.*);
            overlay(&self.row, &self.vals, &self.given);
            if (@hasField(D.Model, "temperature__")) self.row.temperature__ = temperature;
            // §9.19 `$port_connected`: ngspice connects the first
            // `connected` terminals and makes the rest internal nodes.
            if (@hasField(D.Model, "port_connected__"))
                self.row.port_connected__ = if (connected >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(connected)) - 1;
            if (!derive(handle, &self.row)) res.flags |= eval_ret_flag_fatal;
            readback(&self.row, &self.vals, &self.given);
            if (@hasDecl(D, "setup")) D.setup(Val, &self.row);
            inline for (dead_flows, 0..) |u, k| {
                const f = @typeInfo(D.U).@"enum".field_names[u];
                self.collapsed[k] = @field(self.row, f ++ "__retained") == 0;
            }
            self.inst = .{};
            if (has_mf) {
                if (!self.mfactor_given) self.mfactor = 1;
                self.inst.mfactor = self.mfactor;
            }
            if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            if (State != void) self.state = D.initState(&self.row, &self.inst);
            self.have_x = false;
            self.sim = .{};
            self.t_prev = 0;
            self.t_last = 0;
        }

        /// The analysis OSDI's flags describe (ngspice osdiload.c sets them).
        fn simState(self: *Instance, info: *const SimInfo) contract.SimState {
            const f = info.flags;
            var s: contract.SimState = .{ .t = info.abstime, .analog_initial = false };
            if (f & analysis_ac != 0) {
                s.kind = .ac;
            } else if (f & analysis_noise != 0) {
                s.kind = .noise;
            } else if (f & analysis_tran != 0 and f & calc_react_residual != 0) {
                // ponytail: OSDI passes no step, so dt is the distance to the
                // last earlier time evaluated; a rejected-and-retried step
                // sees the right one, a later retry at a time past the
                // rejected one does not. Only `$simparam("dt")` reads it.
                if (info.abstime > self.t_last) {
                    self.t_prev = self.t_last;
                    self.t_last = info.abstime;
                } else if (info.abstime < self.t_last) self.t_last = info.abstime;
                s.kind = .tran;
                s.dt = info.abstime - self.t_prev;
            } else {
                // A transient's own operating point is §4.6.1's IC analysis.
                s.kind = if (f & analysis_tran != 0) .ic else .dc;
                s.initial_step = true;
                s.analog_initial = true;
            }
            return s;
        }

        fn eval(handle: ?*anyopaque, ip: *anyopaque, _: *const anyopaque, info: *const SimInfo) callconv(.c) u32 {
            @setEvalBranchQuota(10_000_000);
            const self: *Instance = @ptrCast(@alignCast(ip));
            var ret: u32 = 0;
            // Gmin and source stepping move a `$simparam` mid-solve.
            if (hostParams(&self.row, info.paras)) {
                if (@hasDecl(D, "setup")) D.setup(Val, &self.row);
                if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            }
            // The last point before the simulator moves time forward is the
            // one it accepted (a rejected step retries at an earlier time).
            if (State != void and self.have_x and self.sim.kind == .tran and info.abstime > self.sim.t and info.flags & calc_react_residual != 0) accept(self);
            const sim = simState(self, info);
            if (@hasDecl(D, "advanceIteration") and self.have_x) D.advanceIteration(Val, &self.row, &self.inst, self.x, sim);

            var cur: [n]f64 = undefined;
            for (&cur, self.node_mapping) |*c, k| c.* = info.prev_solve[k];
            var x = cur;
            if (info.flags & init_lim != 0 and @hasDecl(D, "seed")) {
                // SPICE MODEINITJCT: the seeds are node values from a 0 V root.
                x = @splat(0);
                for (D.seed(Val, &self.row, &self.inst, sim), &x) |s, *xi| if (s) |v| {
                    xi.* = v;
                };
            } else if (info.flags & enable_lim != 0 and @hasDecl(D, "limit") and self.have_x) {
                const r = D.limit(Val, &self.row, &self.inst, cur, self.x, sim);
                x = r.x;
                if (!r.converged) ret |= eval_ret_flag_lim;
            }

            if (has_q) {
                const out = D.evalQ(Dual, &x, &self.row, &self.inst, sim);
                const qr = contract.qRows(D, Dual, out.q);
                inline for (0..n) |i| {
                    self.res[i] = out.res[i].val();
                    self.q[i] = qr[i].val();
                }
                inline for (entries, 0..) |e, k| {
                    self.jac[k] = out.res[e.r].ddxAt(e.c);
                    self.jac_q[k] = qr[e.r].ddxAt(e.c);
                }
            } else {
                const rows = D.eval(Dual, &x, &self.row, &self.inst, sim);
                inline for (0..n) |i| self.res[i] = rows[i].val();
                inline for (entries, 0..) |e, k| {
                    self.jac[k] = rows[e.r].ddxAt(e.c);
                    self.jac_q[k] = 0;
                }
            }
            inline for (comptime contract.jacConst(D)) |e| {
                if (contract.jacConstApplies(D, e, &self.row, false)) {
                    const k = comptime entryOf(@backingInt(e.row), @backingInt(e.col));
                    self.jac[k] = e.g;
                    self.jac_q[k] = e.c;
                }
            }

            // §6.3.6: every flow contribution is multiplied by $mfactor and
            // every flow probe divided by it. The device applies neither, so
            // the KCL rows (a voltage unknown's) scale by it here; a flow
            // unknown's own row is its branch's potential equation and does
            // not, which leaves the flow unknown the per-device current the
            // probe reads.
            if (has_mf and self.inst.mfactor != 1) {
                const m = self.inst.mfactor;
                inline for (0..n) |i| if (comptime kcl(i)) {
                    self.res[i] *= m;
                    self.q[i] *= m;
                };
                inline for (entries, 0..) |e, k| if (comptime kcl(e.r)) {
                    self.jac[k] *= m;
                    self.jac_q[k] *= m;
                };
            }

            // OpenVAF's lim_rhs: J·(x_limited − x), which turns the RHS
            // J·prev_solve − f into the linearization at the limited point.
            self.lim_res = @splat(0);
            self.lim_q = @splat(0);
            inline for (entries, 0..) |e, k| {
                const dx = x[e.c] - cur[e.c];
                self.lim_res[e.r] += self.jac[k] * dx;
                self.lim_q[e.r] += self.jac_q[k] * dx;
            }
            self.x = x;
            self.cur = cur;
            self.have_x = true;
            self.sim = sim;

            // A static solve has no steps to reject: every iterate is accepted.
            if (State != void and (sim.kind == .dc or sim.kind == .ic)) accept(self);
            if (@hasDecl(D, "checkConvergence") and !D.checkConvergence(Val, &self.row, &self.inst, x, sim)) ret |= eval_ret_flag_lim;
            if (@hasField(D.Instance, "vera_status__") and self.inst.vera_status__ != 0) {
                var buf: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                contract.formatStatus(D, &self.inst, &w) catch {};
                log(handle, log_lvl_fatal, w.buffered());
                ret |= eval_ret_flag_fatal;
            }
            return ret;
        }

        /// `updateState` and `stateCtl(.commit)` at the last evaluated point.
        fn accept(self: *Instance) void {
            _ = D.updateState(Val, &self.row, &self.inst, self.x, &self.state, self.sim);
            if (@hasDecl(D, "stateCtl")) _ = D.stateCtl(&self.row, &self.inst, &self.state, .commit);
        }

        fn inst(ip: *anyopaque) *Instance {
            return @ptrCast(@alignCast(ip));
        }

        fn loadResidualResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.res, self.node_mapping) |v, k| dst[k] += v;
        }
        fn loadResidualReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.q, self.node_mapping) |v, k| dst[k] += v;
        }
        fn loadLimitRhsResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.lim_res, self.node_mapping) |v, k| dst[k] -= v;
        }
        fn loadLimitRhsReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            const self = inst(ip);
            for (self.lim_q, self.node_mapping) |v, k| dst[k] -= v;
        }

        /// SPICE's RHS: J·x − f at the limited point `x` (OpenVAF
        /// load_spice_rhs_dc: J·prev_solve − f + lim_rhs, the same sum).
        fn loadSpiceRhsDc(ip: *anyopaque, _: *anyopaque, dst: [*]f64, _: [*]const f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            var rhs: [n]f64 = undefined;
            for (&rhs, self.res) |*r, f| r.* = -f;
            inline for (entries, 0..) |e, k| rhs[e.r] += self.jac[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += v;
        }

        /// The DC RHS plus alpha·Jq·x; the simulator subtracts its own
        /// integrated dQ/dt (ngspice osdiload.c).
        fn loadSpiceRhsTran(ip: *anyopaque, mp: *anyopaque, dst: [*]f64, prev: [*]const f64, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            loadSpiceRhsDc(ip, mp, dst, prev);
            const self = inst(ip);
            var rhs: [n]f64 = @splat(0);
            inline for (entries, 0..) |e, k| rhs[e.r] += self.jac_q[k] * self.x[e.c];
            for (rhs, self.node_mapping) |v, k| dst[k] += alpha * v;
        }

        fn loadJacobianResist(ip: *anyopaque, _: *anyopaque) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.resist) {
                if (self.jac_ptr[k]) |p| p.* += self.jac[k];
            };
        }

        /// alpha·dQ/dx into the imaginary half; under AC or noise also the
        /// frequency-dependent slots `eval` left out (`acDyn`), whose real
        /// part goes to the real half and whose imaginary part already
        /// carries ω (ngspice passes alpha = ω, osdiacld.c).
        fn loadJacobianReact(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.react) {
                if (self.react_ptr[k]) |p| p.* += alpha * self.jac_q[k];
            };
            if (@hasDecl(D, "acDyn") and (self.sim.kind == .ac or self.sim.kind == .noise)) {
                var out: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
                D.acDyn(f64, &self.row, &self.inst, &self.x, self.sim, alpha, &out);
                inline for (D.ac_dyn_slots, 0..) |s, j| {
                    const k = comptime entryOf(s / n, s % n);
                    if (self.jac_ptr[k]) |p| p.* += out[j].re;
                    if (self.react_ptr[k]) |p| p.* += out[j].im;
                }
            }
        }

        fn loadJacobianTran(ip: *anyopaque, _: *anyopaque, alpha: f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (0..nj) |k| if (self.jac_ptr[k]) |p| {
                p.* += self.jac[k] + alpha * self.jac_q[k];
            };
        }

        fn writeJacobianResist(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.resist) {
                dst[k] = self.jac[k];
            };
        }
        fn writeJacobianReact(ip: *anyopaque, _: *anyopaque, dst: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            const self = inst(ip);
            inline for (entries, 0..) |e, k| if (e.react) {
                dst[k] = self.jac_q[k];
            };
        }

        // ---- noise ---------------------------------------------------------

        const gens = if (@hasDecl(D, "noise_gens")) D.noise_gens else [0]contract.NoiseGen(D){};

        /// §4.6.4.3/.4 a table generator's PSD at `f`, from the card's
        /// knots (`contract.noiseTable` on the derived row).
        fn tableAt(row: *const D.Model, comptime table: ?u16, f: f64) f64 {
            const ti = table orelse return 0;
            return contract.noiseTableAt(contract.noiseTable(D, row, ti), f);
        }

        fn loadNoise(ip: *anyopaque, _: *anyopaque, freq: f64, dens: [*]f64) callconv(.c) void {
            @setEvalBranchQuota(10_000_000);
            if (gens.len == 0) return;
            const self = inst(ip);
            const psd = D.noisePsd(Val, self.x, &self.row, &self.inst, self.sim);
            inline for (gens, 0..) |g, k| {
                const t = psd[k];
                const shape = if (t.flicker == 0 or freq <= 0) t.white else t.white + t.flicker / std.math.pow(f64, freq, t.ef);
                // §6.3.6: a flow's noise scales with $mfactor too, in power.
                const m = if (has_mf) self.inst.mfactor else 1;
                dens[k] = m * t.coeff * t.coeff * (shape + tableAt(&self.row, g.table, freq));
            }
        }

        // ---- the descriptor ------------------------------------------------

        const nodes = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [n]Node = undefined;
            for (&a, @typeInfo(D.U).@"enum".field_names, 0..) |*nd, f, i| {
                const flow = @hasDecl(D, "u_kinds") and D.u_kinds[i] != .voltage;
                nd.* = .{
                    .name = cName(f),
                    .units = if (flow) "A" else "V",
                    .residual_units = if (flow) "V" else "A",
                    .resist_residual_off = @offsetOf(Instance, "res") + 8 * i,
                    .react_residual_off = if (reactRow(i)) @offsetOf(Instance, "q") + 8 * i else no_off,
                    .resist_limit_rhs_off = @offsetOf(Instance, "lim_res") + 8 * i,
                    .react_limit_rhs_off = if (reactRow(i)) @offsetOf(Instance, "lim_q") + 8 * i else no_off,
                    .is_flow = flow,
                };
            }
            break :blk a;
        };

        const jacobian_entries = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [nj]JacobianEntry = undefined;
            for (&a, entries, 0..) |*je, e, k| je.* = .{
                .nodes = .{ .node_1 = e.r, .node_2 = e.c },
                .react_ptr_off = if (e.react) @offsetOf(Instance, "react_ptr") + @sizeOf(?*f64) * k else no_off,
                .flags = (if (e.resist) jacobian_entry_resist else 0) | (if (e.react) jacobian_entry_react else 0),
            };
            break :blk a;
        };

        const collapsible = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [dead_flows.len]NodePair = undefined;
            for (&a, dead_flows) |*p, u| p.* = .{ .node_1 = u, .node_2 = no_off };
            break :blk a;
        };

        const noise_sources = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [gens.len]NoiseSource = undefined;
            for (&a, gens, 0..) |*s, g, k| s.* = .{
                .name = if (g.name.len != 0) cName(g.name) else std.fmt.comptimePrint("noise{d}", .{k}),
                .nodes = .{ .node_1 = g.row, .node_2 = if (g.row == g.col) no_off else g.col },
            };
            break :blk a;
        };

        const param_opvar = blk: {
            @setEvalBranchQuota(10_000_000);
            var a: [num_params]ParamOpvar = undefined;
            for (params, 0..) |p, i| {
                const names: []const Str = &.{cName(p.field)};
                const ty = switch (p.kind) {
                    .real => para_ty_real,
                    .int => para_ty_int,
                    .str => para_ty_str,
                };
                a[i] = .{ .name = names.ptr, .num_alias = 0, .description = "", .units = "", .flags = ty | para_kind_inst, .len = 0 };
                a[num_inst_params + i] = .{ .name = names.ptr, .num_alias = 0, .description = "", .units = "", .flags = ty, .len = 0 };
            }
            if (has_mf) {
                const names: []const Str = &.{"$mfactor"};
                a[np] = .{ .name = names.ptr, .num_alias = 0, .description = "multiplicity", .units = "", .flags = para_ty_real | para_kind_inst, .len = 0 };
            }
            break :blk a;
        };

        const n_resist = blk: {
            @setEvalBranchQuota(10_000_000);
            var c: u32 = 0;
            for (entries) |e| c += @intFromBool(e.resist);
            break :blk c;
        };
        const n_react = blk: {
            @setEvalBranchQuota(10_000_000);
            var c: u32 = 0;
            for (entries) |e| c += @intFromBool(e.react);
            break :blk c;
        };

        pub const descriptors = [1]Descriptor{.{
            .name = cName(name),
            .num_nodes = n,
            .num_terminals = D.num_ports,
            .nodes = &nodes,
            .num_jacobian_entries = nj,
            .jacobian_entries = &jacobian_entries,
            .num_collapsible = dead_flows.len,
            .collapsible = &collapsible,
            .collapsed_offset = @offsetOf(Instance, "collapsed"),
            .noise_sources = &noise_sources,
            .num_noise_src = gens.len,
            .num_params = num_params,
            .num_instance_params = num_inst_params,
            .num_opvars = 0,
            .param_opvar = &param_opvar,
            .node_mapping_offset = @offsetOf(Instance, "node_mapping"),
            .jacobian_ptr_resist_offset = @offsetOf(Instance, "jac_ptr"),
            .num_states = 0,
            .state_idx_off = @offsetOf(Instance, "state_idx"),
            .bound_step_offset = if (State != void and @hasField(D.Instance, "bound_step")) @offsetOf(Instance, "inst") + @offsetOf(D.Instance, "bound_step") else no_off,
            .instance_size = @sizeOf(Instance),
            .model_size = @sizeOf(Model),
            .access = &access,
            .setup_model = &setupModel,
            .setup_instance = &setupInstance,
            .eval = &eval,
            .load_noise = &loadNoise,
            .load_residual_resist = &loadResidualResist,
            .load_residual_react = &loadResidualReact,
            .load_limit_rhs_resist = &loadLimitRhsResist,
            .load_limit_rhs_react = &loadLimitRhsReact,
            .load_spice_rhs_dc = &loadSpiceRhsDc,
            .load_spice_rhs_tran = &loadSpiceRhsTran,
            .load_jacobian_resist = &loadJacobianResist,
            .load_jacobian_react = &loadJacobianReact,
            .load_jacobian_tran = &loadJacobianTran,
            .given_flag_model = &givenModel,
            .given_flag_instance = &givenInstance,
            .num_resistive_jacobian_entries = n_resist,
            .num_reactive_jacobian_entries = n_react,
            .write_jacobian_array_resist = &writeJacobianResist,
            .write_jacobian_array_react = &writeJacobianReact,
            .num_inputs = 0,
            .inputs = null,
            .load_jacobian_with_offset_resist = null,
            .load_jacobian_with_offset_react = null,
            .unknown_nature = null,
            .residual_nature = null,
            .noise_source_type = null,
            .load_noise_params = null,
            .absdelay_count = 0,
            .absdelay_info = null,
        }};
    };
}
