//! Device contract: the comptime interface every device (VA-generated or
//! hand-written) must satisfy. `validate(D)` structurally checks the surface
//! the engine calls — decls present, enum dense, param types, function arity —
//! so a mismatch fails at the device definition with a readable error.
//!
//! This contract is NORMATIVE, not descriptive: it specifies the device↔host
//! interface required to represent Verilog-AMS LRM 2.4 analog semantics, and a
//! member may be declared here before the engine consumes it. A member with no
//! LRM justification and no consumer is not a roadmap item — it is deleted.
//!
//! The register of what is declared-but-unconsumed, and of the rules this
//! interface does NOT yet carry, is `tests/lrm-rules/*.tsv` (`zig build ledger`):
//! bucket `B` is exactly "a .va can exercise this rule, it fits the artifact
//! model, and no member here carries it" — 45 rules across 13 proposed members
//! as of the audit. Earlier revisions of this header pointed at a `VerA/TODO.md`
//! that does not exist in the repo.
//!
//! This file only CHECKS the contract; it provides no scalar implementation.
//! Physics is written generic over an opaque scalar S:
//!
//!   pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) [n_u]S;
//!   pub fn q   (comptime S: type, x, m, i, t) [n_u]S;   // optional: charges
//!
//! The engine instantiates S — a plain-f64 value form for residuals, a
//! derivative-carrying dual for the Jacobian. The S primitive set devices may
//! use: con addC scale · add sub neg mul div · exp log expm1 log1p sqrt
//! pow(a,c) · sin cos tanh sinh cosh atan · abs minC maxC min max · val.
//! expm1/log1p are primitives and not exp(x)-1 / log(1+x): §4.3.1 Table 4-14
//! names the C library forms precisely because those two compositions cancel.
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions and minC/maxC/min/max for clamps.

const std = @import("std");

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

/// Accepted-state bookkeeping for FSM devices (switches). The transient
/// loop uses this to reject/retry a timestep whose converged solution flipped
/// a device state, so the discontinuity lands sharp at the crossing:
///   query  — does the working state differ from the last accepted state?
///   commit — step accepted: accepted := working
///   revert — step rejected: working := accepted
pub const StateCtlOp = enum(u8) { query, commit, revert };

/// §4.6.1 `analysis()`, Table 4-21. Host mirror of the `AnalysisKind` every
/// generated device declares for itself — the engine converts by ordinal
/// (`@enumFromInt(@intFromEnum(..))`), same trick as StateCtlOp, so the tag
/// ORDER here is load-bearing. `validateSimState` enforces the agreement
/// rather than leaving it to a comment.
pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

/// Host-owned per-pass simulation state (see `Hooks.set_sim_state`).
/// Everything here is a property of the ANALYSIS, not of the device, so the
/// host is the only writer:
///   t     — §9.10 `$abstime`, the time the solve is targeting
///   dt    — §9.10 timestep feeding `ddt`/`idt`; 0 in a static analysis, which
///           is what the generated zDdt/zIdt helpers test for
///   kind  — §4.6.1 `analysis()`
///   initial_step / final_step — §5.10.2 global events
pub const SimState = struct {
    t: f64 = 0,
    dt: f64 = 0,
    kind: AnalysisKind = .dc,
    initial_step: bool = false,
    final_step: bool = false,
};

pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

/// Host-written `Instance` fields. These are NOT decls — the host reaches them
/// by name (`@hasField`), so a typo used to be a silently-null hook rather than
/// an error; `temperature` was probed as `"temp"` for a while and was null for
/// every generated device. Presence stays optional (a hand-written resistor
/// needs none of them), but the NAME and TYPE are contract now.
///
/// `analysis_kind` additionally has to agree with `AnalysisKind` by ordinal,
/// because the host writes it with `@enumFromInt(@intFromEnum(..))`.
const SimStateField = struct { name: []const u8, T: type };
const sim_state_fields = [_]SimStateField{
    .{ .name = "temperature", .T = f64 }, // §9.15 $temperature, kelvin
    .{ .name = "abstime", .T = f64 }, // §9.10 $abstime
    .{ .name = "dt", .T = f64 }, // §9.10 timestep feeding ddt/idt
    .{ .name = "mfactor", .T = f64 }, // §9.15/E.4.1 $mfactor
    .{ .name = "is_initial_step", .T = bool }, // §5.10.2
    .{ .name = "is_final_step", .T = bool }, // §5.10.2
    .{ .name = "bound_step", .T = f64 }, // §9.17.2 $bound_step
};

/// §4.6.4 noise generator topology. Position k of `noise_gens` names one
/// INJECTION: generator `source`'s output enters the (row, col) branch scaled
/// by `coeff`. Several entries may share a `source` — that is exactly LRM
/// §4.6.4.6 correlated noise (one generator, several contributions), and it is
/// why correlation is expressed here rather than as a coefficient between two
/// independent generators.
pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker },
    };
}

/// One generator's PSD at a given state vector, returned by the optional
/// device `noisePsd` hook (position k = noise_gens[k]):
///   S(f) = white + flicker / f^ef   [A²/Hz]
/// white: thermal 4kT·g, shot 2q|I| — the DEVICE computes it from its own
/// currents/conductances. corr_with pairs correlated generators (BSIM4
/// tnoiMod, PSP igid); real coefficient until a reference demands complex.
///
/// NOTE (tests/lrm-rules, bucket B "+noisePsd"): this parametric form cannot express
/// §4.6.4.3 `noise_table` / §4.6.4.4 `noise_table_log`, which are piecewise
/// PSD-vs-frequency. It is superseded by `noisePsd(x, m, i, f) -> [k]f64`
/// once codegen emits it; the two changes land together.
pub const PsdTerm = struct {
    white: f64,
    flicker: f64 = 0,
    ef: f64 = 1,
    corr_with: ?u8 = null,
    corr: f64 = 0,
};

/// Operating-point output variable metadata. Mirrors `noise_gens`: an optional
/// comptime table a device may declare, describing internal quantities (gm,
/// gds, vth, currents, ...) it exposes for post-solve inspection. Position k
/// in `op_vars` corresponds to element k of the `opValues(...)` result. A
/// Verilog-A `(* desc=... *) real x;` module variable (§3.2.1 output
/// variables) becomes one entry.
pub const OpVar = struct {
    name: []const u8,
    units: []const u8 = "",
    desc: []const u8 = "",
};

/// Rectangular complex, for the small-signal stamp. Plain struct rather than
/// std.math.Complex so the layout is fixed across the `.so` ABI boundary.
pub const Complex = struct {
    re: f64 = 0,
    im: f64 = 0,
};

/// §4.6.3 / §4.5.11 / §4.5.12 small-signal stamp topology, sparse. Position k
/// of `ac_stamps` describes element k of the `acStamp(...)` result:
///   col == null — an independent complex SOURCE on `row` (`ac_stim`)
///   col != null — a complex Jacobian entry (row, col)
///
/// This exists for exactly the responses `G + jwC` cannot represent, i.e. the
/// ones transcendental in s: `absdelay`/`transition` (e^-s·td), `zi_*`
/// (e^sT), and `ac_stim`'s phase. A RATIONAL response (`laplace_*`) does NOT
/// belong here — it is realizable as internal unknowns with real G/C, which is
/// correct in tran/ac/noise/pss/pz alike; see tests/lrm-rules.
pub const AcStamp = struct {
    row: u8,
    col: ?u8 = null,
};

/// Result of a limiting pass. `converged` is the device's own verdict on
/// whether its clamp was significant enough to require another Newton
/// iteration — pnjlim says yes, a cosmetic fetlim/limvds clamp says no. It
/// replaces the old `limit_flag_unknowns` per-unknown table, which could only
/// answer that question positionally and could not distinguish a large clamp
/// from a small one on the same unknown.
pub fn LimitResult(comptime n: usize) type {
    return struct {
        x: [n]f64,
        converged: bool = false,
    };
}

/// Constant-Jacobian declaration. `g`/`c` assert that the device's dF/dx and
/// dQ/dx do not depend on x, so the engine can build the stamp once and memcpy
/// it every Newton iteration. A wrong value silently freezes the Jacobian.
pub const Constant = struct {
    g: bool = false,
    c: bool = false,
};

pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

// ============================================================================
// Validation
// ============================================================================

pub fn validate(comptime D: type) void {
    @setEvalBranchQuota(1_000_000);
    const name = @typeName(D);

    // Required decls first, so a missing one reads as a contract violation
    // rather than a raw "no member named ..." error.
    for (.{ "U", "num_ports", "Model", "Instance", "eval" }) |decl| {
        if (!@hasDecl(D, decl))
            @compileError(name ++ ": contract requires `pub " ++ decl ++ "`");
    }

    if (@typeInfo(D.U) != .@"enum" or !isDenseEnum(D.U))
        @compileError(name ++ ".U must be a dense enum(u8) with values 0..n-1");
    const n = nU(D);

    const np: usize = D.num_ports;
    if (np == 0 or np > n)
        @compileError(name ++ ".num_ports must be in 1..|U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");
    validateSimState(D);

    // Physics: generic over S, so only shape-checkable. eval/q take
    // (comptime S, [n]S, *const Model, *const Instance, f64).
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // Voltage limiting (pnjlim/fetlim) and cold-start seeding (SPICE
    // MODEINITJCT). seed returns absolute local voltages written into a
    // zeroed x before Newton iteration 1; null leaves an unknown untouched
    // (externally driven terminals). Any device with junction limiting
    // should also declare seed — limiting from x_old = 0 is what pins
    // cold-start Newton in the wrong basin.
    // NOTE: limit corrections are only APPLIED to internal unknowns
    // (u >= num_ports) — the batch masks external writes, since a limiter
    // writing a driven/shared node fights sources and other devices.
    // seed writes are unmasked: they happen once, pre-solve, and the first
    // linear solve re-imposes every source constraint.
    if (@hasDecl(D, "limit"))
        expectFn(D, "limit", fn (*const D.Model, *const D.Instance, [n]f64, [n]f64) LimitResult(n));
    if (@hasDecl(D, "seed"))
        expectFn(D, "seed", fn (*const D.Model, *const D.Instance) [n]?f64);
    // Node collapse (ngspice setup): for each internal unknown, return the
    // port index it collapses onto when its separating parasitic R is 0, or
    // null to keep a private node. Consulted once at build time.
    if (@hasDecl(D, "collapse"))
        expectFn(D, "collapse", fn (*const D.Model, *const D.Instance) [n]?u8);

    // State machine: eval reads Instance, so updateState gets a MUTABLE
    // Instance — switch position etc. must live in Instance fields.
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            @compileError(name ++ ": initState/updateState require pub const State");
        // initState takes a MUTABLE Instance for the §5.10 held variables: a
        // guarded variable with a parameter-dependent initializer cannot express
        // that value as a struct field default, because a default must be
        // comptime and a parameter is not. Those collapse to the parameter's
        // spec default today; this hook is the upgrade path.
        //
        // It is NOT for digital drivers. VerA compiles a flat analog device with
        // no digital drivers or receivers — codegen hardwires the §9.22
        // `$driver_*` family to 0 for exactly that reason — and no generated
        // device has ever written a logic output here. The comment that used to
        // claim otherwise was the only assertion of digital support in this file.
        expectFn(D, "initState", fn (*const D.Model, *D.Instance) D.State);
        expectFn(D, "updateState", fn (*const D.Model, *D.Instance, [n]f64, *D.State) UpdateResult);
        if (@hasDecl(D, "stateCtl"))
            expectFn(D, "stateCtl", fn (*const D.Model, *D.Instance, *D.State, StateCtlOp) bool);
    }

    // Convergence aids. Only the 2-arg attempt form exists — batch.zig:616
    // calls it unconditionally; a 3-arg variant would never be invoked.
    if (@hasDecl(D, "attempt"))
        expectFn(D, "attempt", fn (D.Model, f64) D.Model);

    // Optional metadata. Each is a comptime [k]T table paired with the hook
    // that fills position k — see `expectArray` / `requireWith`.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");

    // In-device noise PSDs: pure fn of ANY state vector (AC noise calls it
    // once at x_op, pnoise per PSS sample, tran-noise per step). Position k of
    // the result describes generator k. Devices without it keep the
    // thermal-off-the-Jacobian collectNoise fallback.
    expectArray(D, "noise_gens", NoiseGen(D));
    requireWith(D, "noisePsd", "noise_gens");
    if (@hasDecl(D, "noisePsd"))
        expectFn(D, "noisePsd", fn ([n]f64, *const D.Model, *const D.Instance) [D.noise_gens.len]PsdTerm);

    // Small-signal stamp: the complex contribution `G + jwC` cannot carry.
    // Sparse — `ac_stamps` is the comptime pattern, `acStamp` the values at a
    // frequency, same idiom as noise_gens/noisePsd.
    expectArray(D, "ac_stamps", AcStamp);
    requireWith(D, "ac_stamps", "acStamp");
    requireWith(D, "acStamp", "ac_stamps");
    if (@hasDecl(D, "ac_stamps")) {
        for (D.ac_stamps) |s| {
            if (s.row >= n or (s.col orelse 0) >= n)
                @compileError(name ++ ".ac_stamps: row/col out of range 0..|U|-1");
        }
        expectFn(D, "acStamp", fn ([n]f64, *const D.Model, *const D.Instance, f64) [D.ac_stamps.len]Complex);
    }

    // Operating-point output variables (§3.2.1). Position k in op_vars
    // describes element k of opValues's result.
    expectArray(D, "op_vars", OpVar);
    requireWith(D, "op_vars", "opValues");

    validateMcParam(D);

    // LRM 6.3.4 / 3.4.5: parameters whose value is an expression over OTHER
    // parameters, plus every localparam. The Model is a flat struct, so a host
    // write to a base parameter cannot reach what was declared over it; the
    // host closes that gap by calling `derive` once, after it finishes writing
    // the card and before it builds an Instance. Absent when the module has no
    // such parameter, which is the common case — a literal default is still
    // just a field initializer.
    if (@hasDecl(D, "derive"))
        expectFn(D, "derive", fn (*D.Model) void);

    // precompute: instance-mutating parameter prep before solve.
    if (@hasDecl(D, "precompute"))
        expectFn(D, "precompute", fn (*D.Instance, *const D.Model) void);

    // Constant-Jacobian declaration.
    if (@hasDecl(D, "constant") and @TypeOf(D.constant) != Constant)
        @compileError(name ++ ".constant must be contract.Constant");

    // Breakpoint scheduling for piecewise sources.
    if (@hasDecl(D, "nextBreakpoint"))
        expectFn(D, "nextBreakpoint", fn (*const D.Model, f64) ?f64);

    // Pub-decl allowlist: only contract-recognized names may be pub.
    rejectStrayPubDecls(D);
}

const allowed_pub_decls = std.StaticStringMap(void).initComptime(.{
    .{ "U", {} },
    .{ "num_ports", {} },
    .{ "Model", {} },
    .{ "Instance", {} },
    .{ "eval", {} },
    .{ "q", {} },
    .{ "limit", {} },
    .{ "seed", {} },
    .{ "collapse", {} },
    .{ "initState", {} },
    .{ "updateState", {} },
    .{ "stateCtl", {} },
    .{ "State", {} },
    // Runtime analysis kind exported by generated devices for the analysis()
    // builtin; the host engine sets Instance.analysis_kind per pass. Its
    // ordinals are checked against `AnalysisKind` by `validateSimState`.
    .{ "AnalysisKind", {} },
    // LRM 9.4 display tasks. Present ONLY in a device built with
    // `--display=emit` (FastVAF's testbench artifact); the engine never calls
    // it, and a device compiled for the solver does not have it at all.
    .{ "display", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "ac_stamps", {} },
    .{ "acStamp", {} },
    .{ "op_vars", {} },
    .{ "opValues", {} },
    .{ "mc_param", {} },
    .{ "derive", {} },
    .{ "precompute", {} },
    .{ "constant", {} },
    .{ "nextBreakpoint", {} },
});

fn rejectStrayPubDecls(comptime D: type) void {
    const decls = @typeInfo(D).@"struct".decls;
    for (decls) |d| {
        if (allowed_pub_decls.has(d.name)) continue;
        // <module>__analog_op__{laplace,zi}_*__sec — the cascade coefficients of
        // an LRM 4.5.11/4.5.12 filter. Public on purpose: they ARE the transfer
        // function, and a host running .ac/.noise would have to build H(jw)
        // from them because the real-valued residual cannot carry it. The name
        // embeds the module, so it cannot be in the list above.
        //
        // NOTE (tests/lrm-rules, §4.5.11/12): this exemption is
        // scheduled for removal. `laplace_*` is rational and belongs in the
        // matrix as internal unknowns; `zi_*` is transcendental and belongs in
        // `acStamp`. Neither needs a public coefficient table. The exemption
        // stays only until codegen stops emitting it — VerA's own fixtures
        // (066_laplace_dc_gain, 067_zi_sample_hold, 23_laplace_filters,
        // 24_z_transform_filters) depend on it today.
        if (d.name.len >= 5 and std.mem.eql(u8, d.name[d.name.len - 5 ..], "__sec")) continue;
        @compileError(@typeName(D) ++ ": stray pub decl `" ++ d.name ++
            "` — only contract-recognized names may be pub");
    }
}

/// eval/q: fn (comptime S: type, [n]S, *const Model, *const Instance, f64) [n]S.
/// Generic over S, so the concrete signature is checked by instantiation:
/// here only arity + comptime-type first param.
fn validatePhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
        @compileError(@typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, [n_u]S, *const Model, *const Instance, f64) [n_u]S");
}

fn expectFn(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(D, fn_name))
        @compileError(@typeName(D) ++ ": missing " ++ fn_name);
    if (@TypeOf(@field(D, fn_name)) != Expected)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected));
}

/// Optional comptime `[k]Child` metadata table. No-op when absent — every
/// caller is "if you declare it, it must be this shape".
fn expectArray(comptime D: type, comptime decl: []const u8, comptime Child: type) void {
    if (!@hasDecl(D, decl)) return;
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Child)
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be [k]" ++ @typeName(Child));
}

/// `decl` is meaningless without `needs` — a table with no hook to fill it, or
/// a hook with no table to describe it. Declare it both ways for a pair that
/// is mutually required (ac_stamps/acStamp).
fn requireWith(comptime D: type, comptime decl: []const u8, comptime needs: []const u8) void {
    if (@hasDecl(D, decl) and !@hasDecl(D, needs))
        @compileError(@typeName(D) ++ ": `" ++ decl ++ "` requires `" ++ needs ++ "`");
}

fn hasF32Field(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and f.type == f32) return true;
    }
    return false;
}

/// The host-written `Instance` fields (see `sim_state_fields`). Presence is
/// optional; the name and type are not. Without this check a renamed or
/// retyped field is a silently-null hook — `$abstime` pins to 0 and every
/// waveform in the circuit collapses to its t=0 value with no diagnostic.
fn validateSimState(comptime D: type) void {
    const name = @typeName(D);
    for (sim_state_fields) |f| {
        if (!@hasField(D.Instance, f.name)) continue;
        if (@FieldType(D.Instance, f.name) != f.T)
            @compileError(name ++ ".Instance." ++ f.name ++ ": host-written field must be " ++
                @typeName(f.T));
    }

    if (!@hasField(D.Instance, "analysis_kind")) return;
    const K = @FieldType(D.Instance, "analysis_kind");
    if (@typeInfo(K) != .@"enum")
        @compileError(name ++ ".Instance.analysis_kind must be an enum");
    // The host writes this field with @enumFromInt(@intFromEnum(host_kind)),
    // so the device's tag ORDER is load-bearing, not just its tag set.
    const want = @typeInfo(AnalysisKind).@"enum".fields;
    const got = @typeInfo(K).@"enum".fields;
    if (got.len != want.len)
        @compileError(name ++ ".Instance.analysis_kind: enum must have exactly " ++
            std.fmt.comptimePrint("{d}", .{want.len}) ++ " tags, matching contract.AnalysisKind");
    for (want, got) |w, g| {
        if (!std.mem.eql(u8, w.name, g.name) or w.value != g.value)
            @compileError(name ++ ".Instance.analysis_kind: tag `" ++ g.name ++
                "` must be `" ++ w.name ++ "` at the same ordinal — the host converts by ordinal");
    }
}

fn validateDefaultedStruct(comptime D: type, comptime decl: []const u8) void {
    const T = @field(D, decl);
    if (@typeInfo(T) != .@"struct")
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be a struct");
    for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null)
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++ " must have a default value");
        if (!isValueType(f.type))
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++
                ": field type must be numeric/bool/enum, []const u8, or a fixed-size array of these");
    }
}

fn isValueType(comptime T: type) bool {
    // Generated string parameters point at immutable literals in the device
    // image. The loader keeps that .so open for the lifetime of every opaque
    // Model blob, so copying the slice through init_model/ProtoStore is safe;
    // numeric setParam/collectParams intentionally ignore it.
    if (T == []const u8) return true;
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        // Integer-backed enums are fixed-size POD (e.g. Instance.analysis_kind).
        .@"enum" => |e| isValueType(e.tag_type),
        .array => |a| isValueType(a.child),
        else => false,
    };
}

fn isDenseEnum(comptime E: type) bool {
    const info = @typeInfo(E).@"enum";
    if (info.tag_type != u8) return false;
    for (info.fields, 0..) |f, idx| {
        if (f.value != idx) return false;
    }
    return true;
}

/// Optional per-device declaration: `pub const mc_param = "resist";`
/// Names the principal value parameter (Instance or Model f32 field) that
/// Monte Carlo varies. Validated here so a typo fails at compile time.
fn validateMcParam(comptime D: type) void {
    if (!@hasDecl(D, "mc_param")) return;
    if (!hasF32Field(D.Instance, D.mc_param) and !hasF32Field(D.Model, D.mc_param))
        @compileError(@typeName(D) ++ ".mc_param '" ++ D.mc_param ++
            "' is not an f32 field of Model or Instance");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const MockR = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        g: f64 = 1e-3,
    };

    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const ir = x[0].sub(x[1]).scale(model.g);
        return .{ ir, ir.neg() };
    }
};

const MockSw = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // Switch position lives in Instance so eval can read it.
    pub const State = struct { flips: u32 = 0 };

    pub const Model = struct {
        gon: f64 = 1.0,
        goff: f64 = 1e-12,
    };

    pub const Instance = struct {
        closed: bool = false,
    };

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) [n_u]S {
        const g = if (inst.closed) model.gon else model.goff;
        const ir = x[0].sub(x[1]).scale(g);
        return .{ ir, ir.neg() };
    }

    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }

    pub fn updateState(_: *const Model, inst: *Instance, x: [n_u]f64, s: *State) UpdateResult {
        const want = (x[0] - x[1]) > 0.5;
        if (want != inst.closed) {
            inst.closed = want;
            s.flips += 1;
        }
        return .ok;
    }

    pub fn attempt(model: Model, lambda: f64) Model {
        var m = model;
        m.gon *= lambda;
        return m;
    }

    pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, _: [n_u]f64) LimitResult(n_u) {
        return .{ .x = x_new, .converged = true };
    }
};

const MockTline = struct {
    const Self = @This();

    pub const U = enum(u8) { p1, p2 };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // A generated device declares its own mirror of contract.AnalysisKind; the
    // host converts by ordinal, so the order must match exactly.
    pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };

    pub const Model = struct {
        z0: f32 = 50,
        td: f32 = 1e-9,
    };

    pub const Instance = struct {
        // Host-written; name and type are contract (see sim_state_fields).
        abstime: f64 = 0,
        dt: f64 = 0,
        bound_step: f64 = std.math.inf(f64),
        analysis_kind: Self.AnalysisKind = .dc,
    };

    pub const mc_param = "z0";
    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const noise_gens = [_]NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal }};

    // e^-s·td is transcendental: G + jwC cannot carry it, so the delay's
    // small-signal response comes through the stamp.
    pub const ac_stamps = [_]AcStamp{
        .{ .row = 0, .col = 1 },
        .{ .row = 1, .col = 0 },
    };

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ x[0].scale(y0), x[1].scale(y0) };
    }

    pub fn acStamp(_: [n_u]f64, model: *const Model, _: *const Instance, f: f64) [ac_stamps.len]Complex {
        const w = 2.0 * std.math.pi * f;
        const th = -w * @as(f64, model.td);
        const y0 = 1.0 / @as(f64, model.z0);
        const e: Complex = .{ .re = @cos(th) * y0, .im = @sin(th) * y0 };
        return .{ e, e };
    }
};

/// Declares EVERY contract member. Exists so `allowed_pub_decls` cannot drift
/// out of sync with `validate` — a member validate knows about but the
/// allowlist does not is a `stray pub decl` compile error right here, and a
/// member in neither is one this device fails to declare. It is the only place
/// the full surface is exercised at once.
const MockAll = struct {
    const Self = @This();
    const n_u = nU(@This());

    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const AnalysisKind = enum(u8) { static, ic, nodeset, dc, tran, ac, noise };
    pub const State = struct { flips: u32 = 0 };

    pub const Model = struct { g: f32 = 1e-3 };
    pub const Instance = struct {
        temperature: f64 = 300.15,
        abstime: f64 = 0,
        dt: f64 = 0,
        mfactor: f64 = 1,
        analysis_kind: Self.AnalysisKind = .dc,
        is_initial_step: bool = false,
        is_final_step: bool = false,
        bound_step: f64 = std.math.inf(f64),
    };

    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const mc_param = "g";
    pub const constant: Constant = .{ .g = true };
    pub const noise_gens = [_]NoiseGen(Self){.{ .row = 0, .col = 1, .kind = .thermal }};
    pub const ac_stamps = [_]AcStamp{ .{ .row = 0, .col = 1 }, .{ .row = 1 } };
    pub const op_vars = [_]OpVar{.{ .name = "gd", .units = "S" }};

    pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, _: *const Instance, _: f64) [n_u]S {
        const i = x[0].sub(x[1]).scale(@as(f64, m.g));
        return .{ i, i.neg() };
    }
    pub fn q(comptime S: type, x: [n_u]S, _: *const Model, _: *const Instance, _: f64) [n_u]S {
        return .{ x[0].scale(1e-12), x[1].scale(-1e-12) };
    }
    pub fn opValues(comptime S: type, _: [n_u]S, m: *const Model, _: *const Instance, _: f64) [op_vars.len]S {
        return .{S.con(@as(f64, m.g))};
    }
    pub fn limit(_: *const Model, _: *const Instance, cur: [n_u]f64, _: [n_u]f64) LimitResult(n_u) {
        return .{ .x = cur, .converged = true };
    }
    pub fn seed(_: *const Model, _: *const Instance) [n_u]?f64 {
        return .{ 0.6, null };
    }
    pub fn collapse(_: *const Model, _: *const Instance) [n_u]?u8 {
        return .{ null, null };
    }
    pub fn initState(_: *const Model, _: *Instance) State {
        return .{};
    }
    pub fn updateState(_: *const Model, _: *Instance, _: [n_u]f64, s: *State) UpdateResult {
        s.flips += 1;
        return .ok;
    }
    pub fn stateCtl(_: *const Model, _: *Instance, _: *State, _: StateCtlOp) bool {
        return false;
    }
    pub fn attempt(m: Model, lambda: f64) Model {
        var out = m;
        out.g *= @floatCast(lambda);
        return out;
    }
    pub fn noisePsd(_: [n_u]f64, m: *const Model, _: *const Instance) [noise_gens.len]PsdTerm {
        return .{.{ .white = 4 * 1.38e-23 * 300.15 * @as(f64, m.g) }};
    }
    pub fn acStamp(_: [n_u]f64, _: *const Model, _: *const Instance, _: f64) [ac_stamps.len]Complex {
        return .{ .{}, .{} };
    }
    pub fn derive(_: *Model) void {}
    pub fn precompute(_: *Instance, _: *const Model) void {}
    pub fn nextBreakpoint(_: *const Model, _: f64) ?f64 {
        return null;
    }
    pub fn display(_: *const Model, _: *const Instance) void {}
};

test "validate: minimal resistor" {
    comptime validate(MockR);
}

test "validate: every contract member at once (allowlist cannot drift)" {
    comptime validate(MockAll);
    // Every allowlisted name is either declared above or is a required decl
    // MockAll already has — so an entry added to one and not the other fails.
    comptime for (allowed_pub_decls.keys()) |k| {
        if (!@hasDecl(MockAll, k))
            @compileError("allowed_pub_decls has `" ++ k ++ "` but MockAll does not declare it");
    };
}

test "validate: switch (state in Instance + attempt + limit)" {
    comptime validate(MockSw);
}

test "validate: tline (ac stamp + sim-state fields + metadata)" {
    comptime validate(MockTline);
}

test "updateState mutates Instance" {
    var inst: MockSw.Instance = .{};
    var s: MockSw.State = .{};
    const m: MockSw.Model = .{};
    _ = MockSw.updateState(&m, &inst, .{ 1.0, 0.0 }, &s);
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "limit reports its own convergence verdict" {
    const m: MockSw.Model = .{};
    const i: MockSw.Instance = .{};
    const r = MockSw.limit(&m, &i, .{ 1.0, 0.0 }, .{ 0.0, 0.0 });
    try testing.expect(r.converged);
    try testing.expectEqual(@as(f64, 1.0), r.x[0]);
}

test "acStamp carries the delay phase G+jwC cannot" {
    const m: MockTline.Model = .{};
    const i: MockTline.Instance = .{};
    // At f = 1/(4*td) the delay is a quarter period: e^-j(pi/2) -> -j.
    const s = MockTline.acStamp(.{ 0, 0 }, &m, &i, 0.25 / @as(f64, m.td));
    try testing.expectApproxEqAbs(@as(f64, 0), s[0].re, 1e-12);
    try testing.expectApproxEqAbs(-1.0 / @as(f64, m.z0), s[0].im, 1e-12);
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(MockR));
}
