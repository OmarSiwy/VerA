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
//! What is tracked, and where:
//!   - a member declared here and not yet consumed says so in ITS OWN comment,
//!     at the declaration, naming the clause that requires it. That is the only
//!     place the fact cannot drift away from;
//!   - the rules the COMPILER does not carry are the `//! xfail` lines in
//!     tests/fixtures/**.va, which the torture run prints and which FAIL the run
//!     the day they come true — a ledger that cannot go stale, unlike a table;
//!   - the ceilings the waves shipped DELIBERATELY, which no xfail line can
//!     state because no fixture fails on them, are /TODO.md;
//!   - the wave/epic history those xfails were worked off in is `git log`.
//!
//! Three earlier revisions of this header each cited a register that did not
//! exist — first a `VerA/TODO.md`, then a `tests/lrm-rules/*.tsv` with a `zig
//! build ledger` step, then a `docs/conformance-plan.md` — and a fourth claimed
//! no register existed at all, which had stopped being true: /TODO.md was
//! committed in wave 1 and is the file the first of those was reaching for.
//! Check the path before you cite it; a pointer to a file nobody can open reads
//! as evidence that the gap is tracked somewhere.
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
//! pow(a,c) · sin cos tanh sinh cosh atan · abs minC maxC min max ·
//! lt le eq sel · val.
//! expm1/log1p are primitives and not exp(x)-1 / log(1+x): §4.3.1 Table 4-14
//! names the C library forms precisely because those two compositions cancel.
//!
//! lt/le/eq (§4.2.5/§4.2.7) return an S MASK — 1.0 where the relation holds,
//! 0.0 elsewhere, PER LANE, derivative zero: a comparison is piecewise
//! constant. `sel(c, a, b)` (§4.2.12) is `a` where the mask is nonzero and
//! `b` elsewhere, carrying the winner's derivative — the same selection
//! semantics §4.3.1 gives min/max. gt/ge are operand swaps and ne swaps
//! sel's arms, so four primitives close the set. Codegen emits them ONLY for
//! a conditional that may run BOTH arms: a `.strict` unit whose arms contain
//! no call and no domain-restricted op, where a dead arm's NaN/inf is
//! IEEE-defined and the pick discards it. That buys two things — the host's
//! predictor stops eating a data-dependent branch per Newton iteration, and
//! a lane-parallel S (one operating point per lane) gets a true per-lane
//! decision where a `.val()` steer has no single answer. A conditional the
//! finiteness proof accepted only UNDER its guard (`x > 0 ? ln(x) : 0`)
//! keeps the lazy Zig `if` instead.
//!
//! THE WIDTHS INSIDE S ARE THE HOST'S, NOT THE DEVICE'S. Every member of that
//! primitive set takes and returns `f64` at the boundary — `con(f64)`,
//! `scale(f64)`, `addC(f64)`, `val() f64`, `ddxAt(usize) f64` — and physics code
//! may not open S up, so a host is free to carry the derivative half of a dual
//! in `f32` while the value half stays `f64`. That is the inexact-Newton
//! construction: the converged answer is fixed by the accuracy of the RESIDUAL,
//! and an approximate Jacobian costs iterations rather than correctness. On a
//! consumer GPU it is the whole game — sm_89 runs f32 at 69x its f64 rate.
//!
//! A device opts in with `pub const jac_f32 = true` (VerA's `--jac-f32`).
//! Absent, the host must assume f64: a model whose unknowns span more than
//! f32's ~7 digits can lose a Newton direction outright, and only the physics
//! knows that. The permission is per DEVICE for exactly that reason.
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions, minC/maxC/min/max for clamps, and lt/le/eq + sel for
//!     value-form conditionals.

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
/// generator of `kind` on the (row, col) branch. That is the whole of it, and
/// what it CANNOT say is worth as much to a host as what it can.
///
/// **§4.6.4.6 correlated noise is not expressible.** The clause's mechanism is
/// "using the output of one noise function for more than one noise source", so
/// expressing it needs entries that can SHARE a generator — a `source` field,
/// and a `coeff` for the scaling each contribution applies. Neither exists.
/// Two `.thermal` rows on two branches are today indistinguishable from two
/// independent generators, and a host reading this table has no way to know
/// which it has.
///
/// This docstring described `source` and `coeff` as if they were fields for
/// several revisions. They never were. If they are added, the fixture that
/// grades them is
/// `tests/fixtures/ch04_expressions/150_noise_source_through_variable.va`,
/// which is XFAIL on the lowering half of the same gap — a noise source reached
/// through a variable exports nothing at all — and those two halves land
/// together: tracking the source as a value through lowering is what produces
/// the identity a `source` field would name.
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
/// NOTE: this parametric form cannot express
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

/// §2.8.3 + §12.32: one `$name` the compiler could not resolve, which §2.8.3
/// says may be "defined using the VPI as described in Clause 11 and Clause 12".
/// Position k of `systf_calls` is what position k of `SystfHost.call` answers.
///
/// Keyed by NAME and not by call site, because that is what
/// `vpi_register_analog_systf()` registers: "the task or function name shall be
/// unique in the domain in which it is registered". Two calls to one `$name`
/// are one entry and one binding.
///
/// The name is the whole entry, and §12.32's own structure is why. Its other
/// fields — `type` (vpiAnalogSysTask/SysFunc), `sysfunctype`
/// (vpiIntFunc/vpiRealFunc), `sizetf` — are the APPLICATION's declaration of
/// what it registered, not facts a compiler that has never seen the
/// registration can report. A struct rather than a bare `[]const u8` so they
/// have somewhere to land if a host ever needs them; per this file's own rule,
/// none is added before a consumer asks.
pub const Systf = struct {
    /// `$sampnhold`, with the `$`. §12.32: "first character shall be `$`".
    name: []const u8,
};

/// The VPI application, as the device sees it. Written into `Instance.systf` by
/// the host; `validateHost` is what makes it non-optional for a device that
/// declares any `systf_calls`.
///
/// WHY VALUE-PLUS-PARTIALS AND NOT `fn (k, args: []S) S`. `eval` is generic
/// over S and gets instantiated at least twice — a plain f64 for the residual,
/// a derivative-carrying dual for the Jacobian — and a function POINTER cannot
/// be generic over S. So the boundary has to be concrete, which means the host
/// returns the value and its partials separately and the device rebuilds the
/// dual from them.
///
/// That is not a workaround: it is §12.22.1 "Derivatives for analog system
/// task/functions" and §12.32's `derivtf` / `p_vpi_stf_partials`, arrived at
/// from the opposite direction. A systf inside a contribution is inside the
/// residual, and the residual must stay a pure function of `x` or the host's
/// own Newton iteration cannot converge — which is the same invariant that
/// keeps §9.5 file I/O and `$random` out of `eval`. A value with no derivative
/// would break it; a value WITH its derivative does not.
pub const SystfHost = struct {
    /// The application's own state — `s_vpi_analog_systf_data.user_data`.
    ctx: *anyopaque,
    /// §12.32 `calltf` and §12.22.1 `derivtf` in one call. Returns the value at
    /// `args` and writes d(value)/d(args[j]) into `partials[j]`.
    ///
    /// `partials` is exactly `args.len` long and is NOT zeroed on entry: an
    /// application that leaves an entry alone is claiming a derivative it did
    /// not compute. Write every slot, zero included.
    call: *const fn (ctx: *anyopaque, k: usize, args: []const f64, partials: []f64) f64,
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
/// correct in tran/ac/noise/pss/pz alike.
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

    // Ports come first in `U` (codegen orders them that way), so num_ports is a
    // prefix length and the only real bound is `np <= n`. ZERO is legal: §6.2
    // makes the port list OPTIONAL and Annex A.1.2 admits `module identifier ;`,
    // so a device with no terminals and only internal unknowns is a well-formed
    // compilation unit. Its residual is solvable — every equation it contributes
    // is over its own private nodes — and elaboration can instantiate it as a
    // child that contributes those equations to the parent. Nothing downstream
    // needs np >= 1: the limiter mask (`u >= num_ports`) and the port/internal
    // split in codegen both degenerate correctly at 0.
    const np: usize = D.num_ports;
    if (np > n)
        @compileError(name ++ ".num_ports must be <= |U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");
    validateSimState(D);

    // Physics: generic over S, so only shape-checkable. eval/q take
    // (comptime S, [n]S, *const Model, *const Instance, f64).
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // Optional permission, not a shape: the WIDTH of S is the host's, and this
    // only says which widths this device's physics tolerates.
    if (@hasDecl(D, "jac_f32") and @TypeOf(D.jac_f32) != bool)
        @compileError(@typeName(D) ++ ".jac_f32 must be a bool");

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
        // It is NOT for digital drivers, and there is no driver state anywhere in
        // this contract: no generated device has ever written a logic output
        // here. The §9.22 `$driver_*` family does not reach a device at all —
        // §9.22 confines those calls to connect modules, so lowering refuses
        // every one of them (E0818). This comment used to cite codegen's
        // hardwire-to-0 for the family as the reason, i.e. it recorded a wrong
        // answer as a design decision; the answer is gone.
        //
        // If driver access is ever supported it arrives as an OPTIONAL DECL on
        // this contract, the shape `display`, `u_abstol` and the §9.5 I/O
        // interface already use, with the HOST supplying the per-net driver list
        // — a compiler does not need a digital scheduler to ask its simulator a
        // question. Not a State field, and not this hook.
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

    // §3.6.1.2 `abstol`, per unknown: "the largest signal value that can be
    // safely ignored", declared on the NATURE bound to that net (and
    // overridable per discipline, §3.6.2.3). OPTIONAL, because it is a
    // convergence aid and not part of the residual: a host without it has to
    // invent one tolerance for every unknown, which is what a host that only
    // knows `u_kinds` does. A host that runs Newton on `eval` reads it — the
    // absolute half of the iteration's stopping test is exactly this number,
    // and it is per-unknown because a thermal net and a voltage net do not
    // agree on what "negligible" means.
    if (@hasDecl(D, "u_abstol") and @TypeOf(D.u_abstol) != [n]f64)
        @compileError(name ++ ".u_abstol must be [|U|]f64");

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

    // §2.8.3/§12.32 unresolved `$name`s. There is no device-side hook to pair
    // this table with — the implementation is the HOST's, which is the whole
    // point — so what is checked here is only that the device can be reached:
    // `eval` reads the binding off `Instance`, so a device that names a systf
    // and has nowhere to read it from could not be built at all. `validateHost`
    // is the other half, and the host is what calls it.
    expectArray(D, "systf_calls", Systf);
    if (@hasDecl(D, "systf_calls") and D.systf_calls.len != 0) {
        if (!@hasField(D.Instance, "systf"))
            @compileError(name ++ ": declares systf_calls but Instance has no `systf` field " ++
                "for the host to bind — see contract.SystfHost");
        if (@FieldType(D.Instance, "systf") != ?*const SystfHost)
            @compileError(name ++ ".Instance.systf must be `?*const contract.SystfHost`");
    }

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

/// The other half of `validate`, and the only check aimed at the HOST rather
/// than the device. A simulator embedding VerA calls it once per device it
/// links, beside `validate(D)`.
///
/// `validate(D)` cannot ask this. It runs where the DEVICE is defined, and at
/// that point the host does not exist yet — a `.va` compiled to a `.so` does
/// not know which simulator will load it. So the requirement "somebody must
/// implement this" can only be enforced where the two meet, which is here.
///
/// WHAT IT REFUSES, and why that is the right severity. A device declaring
/// `systf_calls` contains a `$name` whose value is the application's to supply.
/// With no binding there is no value — not a wrong one, an absent one — and the
/// residual would read a number nothing computed. §12.32.3's own sampnhold
/// listing never initializes `sampler->value` before its first update callback,
/// so the language fixes no default to fall back to. Failing the host's build
/// is the only outcome that cannot be mistaken for a working device.
///
/// `vera`'s own testbench binds a stub rather than being exempt from this — see
/// `src/backend/tb.zig`. An exemption for the tool's own host is how a seam
/// stops being tested.
pub fn validateHost(comptime H: type, comptime D: type) void {
    if (!@hasDecl(D, "systf_calls") or D.systf_calls.len == 0) return;
    const d = @typeName(D);
    const h = @typeName(H);
    if (!@hasDecl(H, "systf")) @compileError(h ++ " must declare `systf` — " ++ d ++
        " calls " ++ D.systf_calls[0].name ++ ", which §2.8.3 leaves to a VPI application, " ++
        "and this host binds none. See contract.SystfHost.");
    if (@TypeOf(@field(H, "systf")) != fn (*const D.Model) ?*const SystfHost and
        @TypeOf(@field(H, "systf")) != *const fn (*const D.Model) ?*const SystfHost)
        @compileError(h ++ ".systf must be `fn (*const Model) ?*const contract.SystfHost`");
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
    // Single-precision-Jacobian permission — see `validateJacF32` and the S
    // note in the header. Optional; absent means f64, which is the default a
    // host must assume.
    .{ "jac_f32", {} },
    // Lane-parallel permission: eval/q instantiated with a vector S (one
    // operating point per lane) is exact per lane — no `.val()` steering, no
    // per-call scalar draw, no value-collapsing helper on an x-dependent
    // chain. Emitted by codegen only when nothing in the device pinned lanes;
    // the generated testbench's batch differential check asserts the claim on
    // every fixture that carries it. Absent means batching is NOT sound.
    .{ "lane_clean", {} },
    // Runtime analysis kind exported by generated devices for the analysis()
    // builtin; the host engine sets Instance.analysis_kind per pass. Its
    // ordinals are checked against `AnalysisKind` by `validateSimState`.
    .{ "AnalysisKind", {} },
    // LRM 9.4 display tasks AND LRM 9.5 file I/O: the device's per-accepted-point
    // SIDE-EFFECT phase, and the whole of the optional I/O interface a host may
    // provide. Present ONLY in a device built with `--display=emit` (FastVAF's
    // testbench artifact); the engine never calls it, and a device compiled for
    // the solver does not have it at all.
    //
    // One decl for both clauses, because they are one phase. §9.5.2 defines its
    // output tasks as §9.4.1's "with one additional argument, which is either a
    // multichannel descriptor or a file descriptor", and §9.5.9 puts every file
    // write at the ACCEPTED point — "if a file is being written to during an
    // iterative solve, then the file write operations shall not be performed
    // unless the iteration is accepted. The exception to this is the $fdebug". So
    // the descriptor operations are sequenced here, in source order, with the
    // prints, and NOT in `eval`: a residual has to stay a pure function of x or
    // the host's Newton iteration cannot converge, and an open, a read position
    // and an appended line are none of them.
    //
    // A host that declines to call this gets the DEGRADED path, and that path is
    // conformant rather than a fudge. §9.5.1 reserves 0 as $fopen's failure
    // return; a device whose host offers no file table genuinely cannot open a
    // file, so 0 is the correct answer and every later operation on it is a
    // no-op with a defined result (§9.5.4.1's "code is set to zero", §9.5.7's
    // zero errno with an empty description, §9.5.8's zero).
    //
    // This is NOT part of the Kernel ABI and must not become part of it: nothing
    // in `Instance` holds a descriptor, and `eval`/`q` cannot reach a file at all.
    .{ "display", {} },
    .{ "attempt", {} },
    .{ "u_kinds", {} },
    .{ "u_abstol", {} },
    .{ "noise_gens", {} },
    .{ "noisePsd", {} },
    .{ "ac_stamps", {} },
    .{ "acStamp", {} },
    .{ "op_vars", {} },
    .{ "opValues", {} },
    // §2.8.3/§12.32 the `$name`s left to a VPI application. Pub because the
    // HOST reads it — to know what it has to bind, and `validateHost` to refuse
    // when it has not.
    .{ "systf_calls", {} },
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
        // NOTE (§4.5.11/12): this exemption is
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

/// A numeric parameter field of either width. BOTH are live: this generator
/// emits `f64` parameters, while a device written by hand straight against this
/// contract may still declare `f32`. The host reaches them through a tagged
/// `ParamRef`, so neither width is privileged here either.
fn hasFloatField(comptime T: type, comptime name: []const u8) bool {
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and (f.type == f32 or f.type == f64)) return true;
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
    // The VPI binding (§2.8.3/§12.32), and the only pointer INTO THE HOST this
    // rule admits. It is not POD and is deliberately not treated as such: the
    // host writes it, the host owns what it points at, and the device only ever
    // calls through it. Nothing copies an `Instance` across a process boundary —
    // the `.so` seam copies `Model` blobs, which is what the rule above is
    // about — so a host-lifetime pointer here outlives every use of it.
    //
    // Named rather than admitted by shape: `isValueType` returning true for
    // pointers in general would let a device hold one in `Model`, which the
    // loader DOES copy, and that is the bug this whole check exists to stop.
    if (T == ?*const SystfHost) return true;
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
/// Names the principal value parameter (Instance or Model float field) that
/// Monte Carlo varies. Validated here so a typo fails at compile time.
fn validateMcParam(comptime D: type) void {
    if (!@hasDecl(D, "mc_param")) return;
    if (!hasFloatField(D.Instance, D.mc_param) and !hasFloatField(D.Model, D.mc_param))
        @compileError(@typeName(D) ++ ".mc_param '" ++ D.mc_param ++
            "' is not a float field of Model or Instance");
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
    pub const jac_f32 = true;

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
        systf: ?*const SystfHost = null,
    };

    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    // §3.6.1.2 electrical potential's abstol, both unknowns being voltages.
    pub const u_abstol = [n_u]f64{ 1e-6, 1e-6 };
    pub const mc_param = "g";
    pub const constant: Constant = .{ .g = true };
    pub const noise_gens = [_]NoiseGen(Self){.{ .row = 0, .col = 1, .kind = .thermal }};
    pub const ac_stamps = [_]AcStamp{ .{ .row = 0, .col = 1 }, .{ .row = 1 } };
    pub const op_vars = [_]OpVar{.{ .name = "gd", .units = "S" }};
    pub const systf_calls = [_]Systf{.{ .name = "$sampnhold" }};

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

test "validateHost: a systf is the host's to bind, and only when there is one" {
    // MockR names no `$name`, so any host will do — including one that has
    // never heard of VPI. That is the common case and it must stay free.
    comptime validateHost(struct {}, MockR);

    // MockAll calls `$sampnhold`, so a host linking it must answer for it.
    const Sim = struct {
        var app: SystfHost = .{ .ctx = undefined, .call = zero };
        fn zero(_: *anyopaque, _: usize, _: []const f64, partials: []f64) f64 {
            @memset(partials, 0);
            return 0;
        }
        pub fn systf(_: *const MockAll.Model) ?*const SystfHost {
            return &app;
        }
    };
    comptime validateHost(Sim, MockAll);

    // The value-plus-partials boundary reassembles into a dual: a term is
    // `p_j * (arg_j - arg_j.val())`, whose VALUE is zero and whose DERIVATIVE
    // is p_j·d(arg_j), so adding it to `S.con(v)` grafts the host's partial on
    // without disturbing the value. Checked here on the plain-f64 side, where
    // every such term must vanish exactly.
    var partials: [1]f64 = .{7.5};
    const v = Sim.app.call(Sim.app.ctx, 0, &.{0.25}, &partials);
    try std.testing.expectEqual(@as(f64, 0), v);
    try std.testing.expectEqual(@as(f64, 0), partials[0]); // written, not left at 7.5
}

/// §6.2's optional port list, in device form: no terminals, one internal
/// unknown. This is what tests/fixtures/ch06_hierarchy/module_definition.va
/// lowers to (`module m; electrical p; analog I(p) <+ V(p); endmodule`), and it
/// used to be a `num_ports must be in 1..|U|` compile error — a stale guard that
/// predated the host being able to Newton-solve a device's private nodes.
const MockNoPorts = struct {
    pub const U = enum(u8) { p };
    pub const num_ports: usize = 0;
    const n_u = nU(@This());

    pub const Model = struct { g: f64 = 1.0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        return .{x[0].scale(model.g)};
    }
};

test "validate: a module with no port list (§6.2 optional, A.1.2)" {
    comptime validate(MockNoPorts);
    try testing.expectEqual(@as(usize, 0), MockNoPorts.num_ports);
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
