//! Classes 4,5,8,10 — MIR → device.zig. Emits contract-shaped Zig.
//! LRM: §5 behavior (eval/q), §4.5 analog operators (state machine), ch9 system
//! functions, §8.3 device-side simulation contract.
//!
//! Transformation: Mir + Lower + proof.Verdict → device.zig source string.
//!
//! THE INCREMENTAL RULE: emit ONE Zig
//! function per source unit, each with a STABLE name (naming.zig) and the SAME
//! signature, plus a thin dispatcher eval/q. Do NOT emit a monolithic eval and
//! do NOT name values `v{d}` by MIR index — both defeat `zig -fincremental`.
//!
//! DOD: write into one growing output buffer (gpa-owned; every scratch table is
//! on the compilation arena — see `generate`). Determinism is mandatory:
//! identical MIR ⇒ byte-identical output (a no-op edit must reproduce the file).
//!
//! SHAPE OF THE OUTPUT (top-down, so it reads like it is generated):
//!   1. imports + S-generic value-form math helpers                      (§4.3)
//!   2. `U` enum from Lowered.nodes (ports first) + `num_ports`  (§1.3.1/§6.5)
//!   3. `Model`  — one field per parameter, spec default                  (§3.4)
//!   4. `Instance` — temperature/abstime/analysis kind + per-operator state (§4.5)
//!   5. one fn per source unit, uniform signature, per-unit @setFloatMode
//!   6. dispatchers `eval` (resistive) and `q` (reactive)                 (§5.6)
//!   7. `initState`/`updateState` advancing stateful operators          (§4.5.2)
//!   8. `comptime { contract.validate(Self); }`
//!
//! CONTROL FLOW. MIR is a CFG; Zig is structured. The reconstruction is the
//! dominator-tree + labelled-block scheme (Ramsey, "Beyond Relooper"): a merge
//! block Y (>1 predecessor) that is an immediate dominator child of X becomes a
//! labelled block opened inside X's emission and closed just before Y's own
//! code, so every edge into Y is `break :B<Y>`; a back edge is `continue :L<X>`
//! on the loop header's `while (true)`. That is exact for every reducible CFG,
//! which is what lowering (structured source) can produce — including `break` /
//! `continue` / inlined-function `return`, which a diamond-matcher would miss.
//! Phis are materialised as function-scope `var`s assigned on each incoming
//! edge (the standard SSA-out-of-form move); an ALIASED phi (ssa.zig's
//! trivial-phi removal) never gets one — every Value is `resolveAlias`d first.

const std = @import("std");
const Mir = @import("ir").Mir;
/// §4.5 / §5.10.3 / §9.17 operator facts. Spelled `opdb` and not `op` because
/// eleven locals in this file are already called `op` (a `Mir.Opcode`).
const opdb = @import("ir").op;
const Analysis = @import("ir").Analysis;
const UnitPlan = @import("codegen/plan/unit.zig");
const cg_display = @import("cg_display.zig");
const cg_filters = @import("cg_filters.zig");
const cg_limit = @import("cg_limit.zig");
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("ir").proof;
const diag = @import("diag");
const naming = @import("naming.zig");
/// The pure planners: inputs in, a plan value out, no writer — codegen/plan/.
const plan_input = @import("codegen/plan/input.zig");
/// The float/lane concern of the EMITTED device (AGENTS.md §5) — codegen/float/.
const float_mode = @import("codegen/float/mode.zig");
const float_lanes = @import("codegen/float/lanes.zig");
const plan_names = @import("codegen/plan/names.zig");
const plan_topo = @import("codegen/plan/topology.zig");
const plan_limit = @import("codegen/plan/limit.zig");
const plan_noise = @import("codegen/plan/noise.zig");
const plan_jobs = @import("codegen/plan/jobs.zig");
const plan_core = @import("codegen/plan/core.zig");
const plan_args = @import("codegen/plan/args.zig");
const plan_setup = @import("codegen/plan/setup.zig");
const plan_qsite = @import("codegen/plan/qsite.zig");
/// §3.2: root.zig runs it between lowering and if-conversion.
pub const pruneHeld = plan_setup.pruneHeld;
const plan_jac = @import("codegen/plan/jac.zig");
/// The backend half of the Opcode table: how each opcode is spelled in Zig.
pub const opcode_zig = @import("codegen/opcode_zig.zig");
pub const assert = std.debug.assert;

pub const Error = std.mem.Allocator.Error || error{
    /// proof.zig rejected the model; codegen is gated on it — `generate`
    /// returns this before emitting a byte. See proof.zig's CONTRACT header.
    DomainErrors,
    /// A source identifier whose structural key exceeds `naming.max_name_len`.
    /// Never truncated: truncation would break the injectivity two distinct
    /// units rely on.
    NameTooLong,
    /// More than 256 solver unknowns, which `U`'s `enum(u8)` tag cannot spell.
    /// Reported as E1003 by `emitTopology`; see the ceiling argued there.
    TooManyUnknowns,
    /// A numeric parameter default cannot follow host-written dependencies.
    UnsupportedParameterDefault,
};

pub const none_u32 = std.math.maxInt(u32);

/// The generated device, plus the map that lets the orchestrator write it out
/// as ONE FILE PER UNIT DECLARATION.
///
/// Why a map rather than N buffers: `zig` keys its per-file ZIR cache on
/// `stat_inode`/`stat_size`/`stat_mtime` (`std/zig/Zir.zig`'s `Zir.Header`), so
/// leaving a file untouched is exactly what makes `zig` skip AstGen for it.
/// `orchestrator.writeIfChanged` already had the right rationale in its doc
/// comment, but it was applied at whole-device granularity — 182 MB rewritten
/// for a one-line edit, and every declaration re-hashed. Splitting the WRITE
/// fixes that without splitting the codegen buffer: `text` stays the single
/// contiguous emission (`--emit-zig` still writes it verbatim, which is what
/// keeps `--emit-zig` a byte oracle), and the split is a view over it —
/// two `u32` appends per unit, no second buffer, the same reserve-and-record
/// trick as the signature back-patch.
///
/// INVARIANT: the ranges TILE. `unit_lo[i] == unit_hi[i-1]`, so
/// `text[0..unit_lo[0]]` is the prologue and `text[unit_hi[n-1]..]` is the
/// dispatcher tail, with nothing in between that is not a unit.
pub const Output = struct {
    /// Whole device as one text — gpa-owned (see `generate`).
    text: []const u8,
    /// One entry per emitted top-level unit declaration, in emission order.
    /// `names[i]` is BOTH the declaration name and the file stem, which is what
    /// makes the file set churn exactly as `naming.zig`'s keys do. Arena-owned.
    names: []const []const u8 = &.{},
    unit_lo: []const u32 = &.{},
    /// Offset of the declaration keyword inside `text`. The writer splices
    /// `pub ` here; see `Gen.emitUnit` for why `text` cannot carry it itself.
    unit_fn: []const u32 = &.{},
    unit_hi: []const u32 = &.{},
    /// File-scope prologue every `u/<key>.zig` needs: a unit file is a separate
    /// Zig FILE, and Zig has no textual include, so nothing `device.zig`
    /// declares is in its scope. Arena-owned; empty when `names` is.
    prelude: []const u8 = "",
    /// `h.zig`: the §4.3/§4.5 helper kernels, PUBLIC, for the unit files to
    /// alias. device.zig keeps its own private copy inline — `text` has to
    /// stay a valid stand-alone device, and `contract.rejectStrayPubDecls`
    /// forbids publishing them there — so this duplicates ~30 tiny generic
    /// functions that `zig` analyses lazily and only where used. Arena-owned;
    /// empty when `names` is.
    helpers: []const u8 = "",

    /// The un-split form: one `device.zig`, no `u/` directory. Used by
    /// `--emit-zig`, by the conformance runner, and by the orchestrator tests.
    pub fn single(text: []const u8) Output {
        return .{ .text = text };
    }
};

/// §9.4 drop or emit — the type lives with the planners that read it.
pub const Display = plan_args.Display;

/// Knobs that change WHAT is generated (not how fast). One field today; it is a
/// struct so the next one does not churn `generate`'s signature again.
pub const Options = struct {
    display: Display = .drop,
    /// Emit `pub const jac_f32 = true`: this device permits a host to carry the
    /// DERIVATIVE half of its scalar S in single precision.
    ///
    /// It changes no emitted arithmetic, and there is nothing here it could
    /// change. `eval` is generic over S and reaches it only through the
    /// contract's primitive set, every member of which takes and returns `f64`
    /// at the boundary (`con`, `scale`, `addC`, `val`), so which float S carries
    /// INSIDE is already the host's to choose. This decl is how a device says
    /// which choice it tolerates.
    ///
    /// Why the device says it and not the host: the RESIDUAL is unaffected —
    /// inexact Newton converges to the accuracy of the residual, and an
    /// approximate Jacobian costs iterations, not the answer — but a model whose
    /// unknowns span more than f32's ~7 digits can lose a Newton direction
    /// outright. That is a fact about the physics, so it belongs at the physics.
    ///
    /// PERMISSION, NOT ORDER. A host may instantiate the same device at two
    /// widths off this one decl — ESPice runs f32 in its GPU kernel and f64 on
    /// its CPU path (`docs/perf/jac-width-2026-09-10.md`).
    jac_f32: bool = false,
    /// Emit `pub const jac_f32_host = true` as well: the host should take the
    /// permission on its CPU instantiation too, not only where f32 is free.
    ///
    /// Implies `jac_f32` (this emits both, and `tools/contract.zig` rejects the
    /// pair with the permission missing). Separate from it because the two
    /// questions are different: `jac_f32` asks whether the physics survives 7
    /// digits, `jac_f32_host` asks whether a given host's Newton loop should
    /// pay for it. Only the second is an economic choice, which is the only
    /// reason it is a knob.
    jac_f32_host: bool = false,
    /// Split the solve-invariant slice into `setup` (codegen/setup.zig).
    /// `false` computes every value in `eval`, which is the bit-for-bit
    /// oracle the split is checked against; nothing else should want it.
    setup: bool = true,
    /// Where a codegen-stage diagnostic goes (E0515). Optional: the unit tests
    /// and any caller that only wants text pass none, and codegen then reports
    /// a refusal through `fatal_out` alone.
    ///
    /// NOT `lower.bag`: that pointer names the COMPILATION's bag, which
    /// `root.finish` has already detached into the caller's by the time codegen
    /// runs. This is the caller's bag, and it is alive for as long as the
    /// `CompileResult` is.
    diags: ?*diag.Bag = null,
};

/// Emit the whole device.zig. LRM §5/§8.3.
///
/// `arena` MUST be an arena (the per-compilation one): every scratch table is
/// allocated from it and freed with it — this pass has no deinit.
///
/// `gpa` owns the RETURNED SLICE and nothing else. The output buffer is the one
/// allocation here that grows unboundedly (182 MB on `hisimhv_va`), and
/// `ArenaAllocator.resize` refuses in-place growth for anything but the most
/// recent allocation — which `out` never is, since `fmtF64` allocates in
/// between. In an arena every regrow is therefore a full copy whose old buffer
/// is never reclaimed. Zig makes the same split: `Ast.renderAlloc` takes a gpa,
/// and `zig fmt`'s `out_buffer` is a gpa-backed `Allocating` reused across
/// files. Caller frees (see `CompileResult.deinit`).
///
/// Determinism: nothing on this path iterates a hash map.
pub fn generate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    verdict: proof.Verdict,
    /// Set for any fatal generation failure, including metadata outside units.
    fatal_out: *bool,
    opts: Options,
) Error!Output {
    if (!verdict.ok()) return error.DomainErrors;
    // §6.2: the port list is OPTIONAL, so a module with no ports (and even a
    // module with no nets at all — §3.4 parameter-only modules are legal
    // Verilog-A) is a valid compilation unit. It yields a degenerate device
    // with `num_ports == 0` and an empty `U`, which the host simply never
    // stamps; that is a host-side triviality, not a source-language error.

    const an = try Analysis.build(arena, mir, lowered);
    var g: Gen = .{
        .gpa = gpa,
        .an = &an,
        .arena = arena,
        .mir = mir,
        .lowered = lowered,
        .verdict = verdict,
        .display = opts.display,
        .float = .{ .jac = .of(opts.jac_f32, opts.jac_f32_host) },
        .diags = opts.diags,
        .su = .{ .on = opts.setup },
    };
    errdefer g.out.deinit(gpa);
    try g.prepare();
    try g.emitFile();
    fatal_out.* = g.any_fatal or (if (opts.diags) |bag| bag.failed() else false);
    return .{
        .text = try g.out.toOwnedSlice(gpa),
        .names = g.file_names.items,
        .unit_lo = g.file_lo.items,
        .unit_fn = g.file_fn.items,
        .unit_hi = g.file_hi.items,
        .prelude = g.prelude,
        .helpers = g.helpers,
    };
}

// ===========================================================================
// Value typing — every MIR Value is emitted either as an `S` (real) or as a
// plain `i64` (LRM §3.2 integer). §4.2.1.1/§4.2.1.2 conversions are inserted at
// the use site, so a typing miss degrades to a redundant cast, never to code
// that does not compile.
// ===========================================================================

/// The value-type lattice lives with the analysis that computes it.
pub const VTy = Analysis.VTy;

/// Zero-sized context for `Gen.f64_cache`. The key is an f64's bit pattern,
/// which is already in a register; `AutoContext` would run
/// `Wyhash.hash(0, asBytes(&key))` over it. Being zero-sized means no call site
/// changes shape.
const F64Context = struct {
    pub fn hash(_: F64Context, k: u64) u64 {
        return std.hash.int(k);
    }
    pub fn eql(_: F64Context, a: u64, b: u64) bool {
        return a == b;
    }
};

// ===========================================================================
// The generator
// ===========================================================================

pub const Gen = struct {
    /// Owns `out` and nothing else — see `generate`.
    gpa: std.mem.Allocator,
    /// Per-unit state: the slice, use counts, inline decisions and slots for the
    /// declaration being written. Reset in full by every `analyze`.
    plan: UnitPlan = undefined,
    /// The derived facts this emitter reads and never writes: CFG, dominators,
    /// loops, block pools, instruction columns, value types, aliases
    /// (ir/analysis.zig). Everything policy-shaped — what to name a unit, what
    /// to hoist into the core, what to inline — stays in the fields below.
    an: *const Analysis,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
    verdict: proof.Verdict,
    out: std.ArrayList(u8) = .empty,
    /// Rendered text of every float constant seen, keyed on its bit pattern.
    /// See `fmtF64`.
    f64_cache: std.HashMapUnmanaged(u64, []const u8, F64Context, std.hash_map.default_max_load_percentage) = .empty,

    /// Whether the unit body being rendered read each parameter. Zig treats an
    /// unused parameter as a hard error, so the signature has to say `_` — see
    /// `emitUnit` for how that is resolved without a second buffer.
    uses_x: bool = false,
    uses_model: bool = false,
    uses_inst: bool = false,
    /// The core read its `held` flag (`plan_core.heldOnly`): a skippable
    /// store was emitted. Patched to `_` otherwise, as the three above.
    uses_held: bool = false,
    /// §2.8.3/§12.32: the `$name`s nothing in this backend resolved, in first-
    /// call order, which becomes `systf_calls` and therefore the host's binding
    /// indices. Deduplicated by NAME because that is what
    /// `vpi_register_analog_systf()` registers — "the task or function name
    /// shall be unique in the domain in which it is registered" — so two calls
    /// to one `$name` are one entry and one binding. Linear scan: the list is
    /// empty for every device in the tree and single-digit for one that has any.
    systf_names: std.ArrayList([]const u8) = .empty,
    /// Distinguishes one emitted systf block's `break` label from another's.
    /// Blocks nest, so the label has to be unique within a unit and a counter
    /// is the cheapest thing that is.
    systf_sites: u32 = 0,
    /// Set when the unit asks for something whose value the LRM FIXES and this
    /// backend cannot produce (§4.5's non-constant control argument, E0515; a
    /// §3.6.2.2 signal-flow contribution). The whole body collapses to one
    /// `@compileError` — a substitute would contradict a number the clause
    /// writes down, and a per-statement error would bury the reason in a
    /// cascade. §4.5.11's filters and §9.13's `$random` used to be on this list
    /// and are implemented now.
    ///
    /// The one case that deliberately does NOT come here is an unregistered
    /// system function (W0852): the language defines no value for it, so there
    /// is nothing for 0.0 to contradict — only a host to name out loud.
    fatal: ?[]const u8 = null,
    /// Sticky: generation failed, even outside a unit body. Reported out so
    /// callers do not have to substring-search generated text for a refusal.
    any_fatal: bool = false,
    /// Seeds `fatal` for the NEXT unit, for a gap visible from the unit's
    /// DECLARATION rather than from an instruction in its body (§3.6.2.2
    /// signal-flow contributions). `emitUnit` consumes it.
    pre_fatal: ?[]const u8 = null,
    /// Token of the §4.5 operator call whose arguments are being rendered — the
    /// fallback span for E0515 when the offending argument is a leaf with no
    /// instruction of its own (a node probe has no token).
    // ponytail: one field set at the two places that render operator arguments,
    // rather than threading a token through `argF64`'s fifteen call sites.
    // Ceiling: it is only ever read on the E0515 path, which refuses the unit.
    ctrl_tok: u32 = Mir.no_tok,

    /// The float mode and lane state of the body being written — `codegen/float/`.
    float: float_mode.Float = .{},
    /// Every declared identifier and the unknowns behind them — `plan/names.zig`.
    names: plan_names.Names = .{},
    /// One entry per emitted top-level unit declaration — see `Output`. Arena
    /// lists, appended by `recordUnitFile`; two `u32`s per unit is the whole
    /// cost of the per-file split on this side.
    file_names: std.ArrayList([]const u8) = .empty,
    file_lo: std.ArrayList(u32) = .empty,
    file_fn: std.ArrayList(u32) = .empty,
    file_hi: std.ArrayList(u32) = .empty,
    /// See `Output.prelude` / `Output.helpers`. Built by `emitFile`, which is
    /// where the conditionally-emitted helper blocks are already decided.
    prelude: []const u8 = "",
    helpers: []const u8 = "",

    // ---- the shared core ("WHY THIS EXISTS", further down this struct) ----
    /// §4.6.3/§4.6.4 the small-signal source rows and tables — `plan/noise.zig`.
    noise: plan_noise.Noise = .{},
    /// Every unit target the core returns, in insert-tolerant order — `plan/jobs.zig`.
    jobs: plan_jobs.Jobs = .{},
    /// The shared core's live-outs, latches, name and float mode — `plan/core.zig`.
    core: plan_core.Core = .{},
    /// Solve invariance, per value, block and loop — `plan/setup.zig`.
    sinv: plan_setup.Sinv = .{},
    /// §5.6.1.2 the charge sites `q` returns and the rows they stamp —
    /// `plan/qsite.zig`.
    qs: plan_qsite.QSites = .{},
    /// The setup roots and `setup`'s emission state — `codegen/setup.zig`.
    su: gen_setup.Setup = .{},
    /// Set while the core is being emitted. It slices from every target at once
    /// and returns all of them, computing each value rather than reading it out
    /// of a struct that does not exist yet; the §9.4 display unit — the only
    /// other body — slices from one target and reads the rest.
    emitting_common: bool = false,
    /// Set while the §9.4/§9.5 display unit is being emitted, and read by exactly
    /// one thing: `emitSysCall`'s §9.5 dispatch.
    ///
    /// This is the whole boundary Ruling B asks for. A §9.5 call OPENS a file,
    /// MOVES a read position or APPENDS bytes, and `eval` has to stay a pure
    /// function of x or the host's Newton iteration cannot converge — so the
    /// kernels run in the one unit `plan_core.plan` deliberately keeps out of the
    /// shared core, and in every other unit the family keeps the constant it has
    /// always had. §9.5.9 states the same rule normatively: "if a file is being
    /// written to during an iterative solve, then the file write operations shall
    /// not be performed unless the iteration is accepted."
    emitting_display: bool = false,
    /// Does the core read a host-published sim-state `Instance` field? Set by
    /// `emitCommon` from the core's slice (`gen_call.readsSimState`), emitted
    /// as `core_reads_simstate`.
    core_reads_simstate: bool = false,
    /// Set while `emitFused` is emitting: the `core` call belongs to the whole
    /// function, above both halves, so `emitStamps` must not open its own.
    core_hoisted: bool = false,
    /// Set by `emitStamps` when it wanted a core call. Under `core_hoisted` it
    /// is the only record that one is needed, and `emitFused` reads it to
    /// decide whether to insert the hoisted line.
    core_wanted: bool = false,
    /// Extra indent levels for body emission, so the residual stamps can be
    /// emitted verbatim inside `evalQ`'s two nested blocks. Only `ind` reads it.
    ind_base: u32 = 0,
    /// §9.4. `.drop` ⇒ nothing below ever looks at `lower.display_root`.
    display: Display = .drop,
    /// `Options.diags` — where E0515 goes, when the caller kept a bag.
    diags: ?*diag.Bag = null,
    /// Free branch flows and collapsible switch branches — `plan/topology.zig`.
    topo: plan_topo.Topology = .{},
    /// Structural Jacobian columns per residual ROW: `pat[react][ru]` has bit
    /// `cu` set when `∂res[ru]/∂x[cu]` can be nonzero. `emitStamps` fills it as
    /// it writes each row, so a row shape cannot be added without stating its
    /// pattern. Empty until `emitResidual`/`emitFused` allocates it.
    ///
    /// The host reads the emitted constant to drop structurally-zero stamps at
    /// COMPILE time; every bit here is a per-instance-per-iteration `+= 0.0`
    /// into a matrix slot that the device knows can never be anything else.
    pat: [2][]u64 = .{ &.{}, &.{} },
    /// Which residual ROWS each half ever WRITES: bit `ru` of `rows[react]` is
    /// set when the emitted `eval` (resp. `q`) contains any `res[ru] = ...`.
    ///
    /// NOT `pat[react][ru] != 0`, and the difference is the whole point. `pat`
    /// answers for the DERIVATIVE: a term whose value depends on no unknown
    /// ORs zero into the column mask while still writing the row. `isource` is
    /// exactly that shape — both rows clear in `pat[0]`, both rows written with
    /// the DC current — so a host that read a clear pattern row as "identically
    /// zero" would delete every independent current source in the netlist. The
    /// reactive version is quieter: a `ddt()` of something varying in `t` and
    /// not in `x` leaves the host's per-state charge tape frozen at zero for a
    /// live state, and its LTE bound silently disappears.
    ///
    /// Set beside `pat` in `patRow`, the single choke point every `res[...]`
    /// writer already goes through — so a row shape cannot be added without
    /// declaring itself here either.
    rows: [2]u64 = .{ 0, 0 },
    /// Which half of `pat` the current `emitStamps` writes.
    pat_react: bool = false,
    /// Unknowns whose derivative LANE `eval`/`q` may read: the mask behind the
    /// emitted `deriv_reads`. Syntactic and therefore a superset — every
    /// `x[u]` `renderValueRef` writes (any unit, any control flow, whatever
    /// the op around it), every `.ddxAt(u)`, and every dispatcher term whose
    /// coefficient is not a constant. See `emitDerivReads`.
    deriv_reads: u64 = 0,
    /// §3.2.2 per `Lowered.mem_arrays` row: does some load read a version a
    /// derivative-carrying store reached (`Analysis.dFree` of the version)?
    /// Then the storage is `S`; otherwise plain `f64`, and a store keeps the
    /// value alone — no load could see what it dropped. See `prepare`.
    arr_s: []bool = &.{},
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
    /// guard (`dispatch.emitSwitchRow`), eval half — `plan/jac.zig` merges
    /// them into `jac_const` with a `.when`.
    guarded: std.ArrayList(plan_jac.Entry) = .empty,
    /// §4.5.15 the honoured and declined `$limit` sites — `plan/limit.zig`.
    limits: plan_limit.Limits = .{},
    /// §4.5.11/§4.5.12 each filter operator's plan, by unit index (`null` for
    /// every other unit). Filled once by `cg_filters.planAll`.
    filters: []?cg_filters.FilterPlan = &.{},

    /// Where each slot's declaration goes — `probeBody` fills this, and it is
    /// only meaningful for the out-of-SSA path (`straight` declares everything
    /// at its definition by construction).
    place: std.ArrayList(gen_unit.Place) = .empty,
    /// Index of a slot inside its type's hoist ARRAY, or `none_u32` for a slot
    /// that keeps a name of its own. See `emitUnitBody`: the surviving hoists
    /// are one `var h: [n]S` (plus `hi`/`hs` when those types occur) rather than
    /// one `var tN` apiece, which is ~4 k declarations on `hisimhv_va`.
    ///
    /// All-`none_u32` while `probing`, so the dry run names every slot `tN`.
    /// That is fine and deliberate: `probeBody` only compares offsets against
    /// each other, so it needs its own text to be self-consistent, not to match
    /// the final text byte for byte.
    hoist_idx: std.ArrayList(u32) = .empty,
    /// Emitted lexical scopes, as half-open output offsets. `sc_open` is the
    /// stack of scopes still being written; `sc_end` their closing offset once
    /// written. Only live during `probing`.
    sc_end: std.ArrayList(u32) = .empty,
    sc_open: std.ArrayList(u32) = .empty,
    probing: bool = false,

    /// The one fact `plan_jobs` needs from the renderer: does a §4.5 control
    /// argument (or §4.6.3 stimulus) render host-side, or only off the core?
    const DynCtrl = struct {
        g: *Gen,
        pub fn isDynamic(d: DynCtrl, v: Mir.Value) Error!bool {
            return gen_call.ctrlIsDynamic(d.g, v);
        }
    };

    /// What a `plan/` function reads — see `plan/input.zig`.
    pub fn input(self: *const Gen) plan_input.Input {
        return .{ .arena = self.arena, .mir = self.mir, .an = self.an, .lowered = self.lowered };
    }

    // ---- the writer: every emitted byte goes through these three ----

    pub fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// Body text. Same destination as `w` since the signature is back-patched
    /// (see `emitUnit`); kept as a separate name because the call sites read as
    /// "body" vs "file scaffolding".
    pub fn b(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// One `appendNTimes` rather than a loop of `appendSlice`: the value is
    /// comptime-known, so this lowers to a memset (see `ArrayList.appendNTimes`,
    /// which is `inline` for exactly that reason).
    /// §5.10 the trailing argument of a core call: nothing for a core without
    /// held-only stores, else whether this caller keeps the held arrays'
    /// end-of-block values (`updateState`, `acceptQ`) or not (`eval`/`q`).
    pub fn heldArg(self: *const Gen, held: bool) []const u8 {
        if (self.core.held_only.len == 0) return "";
        return if (held) ", true" else ", false";
    }

    pub fn ind(self: *Gen, n: u32) Error!void {
        try self.out.appendNTimes(self.gpa, ' ', (n + self.ind_base) * 4);
    }

    // ------------------------------------------------------------------ setup

    fn prepare(self: *Gen) Error!void {
        // Empirically the emitted Zig runs ~24 bytes per MIR instruction. One
        // guess up front beats a dozen doublings even on a gpa, where a regrow
        // can at least remap in place.
        try self.out.ensureTotalCapacity(self.gpa, self.mir.insts.len * 24 + 4096);
        // Per-unit scratch, owned by unit_plan.zig. `buildValueTypes` and
        // `buildCfg` used to allocate these on the side purely because they knew
        // `nv` and `nb` — a typing pass allocating eight scheduling tables was
        // the kind of side job the split exists to make visible.
        self.plan = try UnitPlan.init(self.arena, self.mir, self.an, self.display);
        self.arr_s = try self.arena.alloc(bool, self.lowered.mem_arrays.items.len);
        @memset(self.arr_s, false);
        if (self.arr_s.len != 0) for (self.an.i_op, 0..) |op, ii| {
            if (op != .fload) continue;
            const arr: Mir.Value = @enumFromInt(self.mir.insts.items(.a)[ii]);
            if (!self.an.dFree(arr)) self.arr_s[self.an.arrOf(arr).?] = true;
        };
        self.names = try plan_names.plan(self.input(), self.verdict.unit_modes.len);
        // After `plan_names.plan`, which fills `branch_u` — the claim `freeFlows`
        // subtracts.
        self.topo = try plan_topo.plan(self.input(), self.names.branch_u);
        try cg_filters.planAll(self);
        // Before `buildJobs`: §4.5.15 the algorithm arguments of every honoured
        // `$limit` become core live-outs, and `buildJobs` is what queues them.
        self.limits = try plan_limit.plan(self.input(), self.names.u_names);
        // Before `buildJobs`: §4.6.4 the PSD arguments become core live-outs
        // too, and `buildJobs` is what queues them.
        self.noise = try plan_noise.plan(self.input());
        for (self.noise.refusals.items) |r| {
            if (self.diags) |bag| try bag.add(.codegen, r.code, self.lowered.tokenSpan(r.tok), "{s}", .{r.msg});
            self.any_fatal = true;
        }
        // Solve invariance first: the charge-site plan reads it to leave the
        // time-constant charges out of `q`, and the jobs queue what it keeps.
        self.sinv = try plan_setup.plan(self.input());
        self.qs = try plan_qsite.plan(self.input(), self.names.branch_u, self.topo, self.sinv.val);
        self.jobs = try plan_jobs.plan(self.input(), .{
            .names = &self.names,
            .unit_modes = self.verdict.unit_modes,
            .limits = self.limits.calls,
            .noise = &self.noise,
            .emit_display = self.display == .emit,
            .q_sites = self.qs.sites,
        }, DynCtrl{ .g = self });
        self.core = try plan_core.plan(self.input(), self.jobs.list);
        // §5.10 a held array's storage carries a derivative only for a load
        // `eval`/`q` returns something from: the rest are read by the value-
        // only consumers (`updateState` is `R`; `acceptQ` keeps `.val()`), so
        // the lanes such a load would carry are never observed.
        if (self.core.eval_need.len != 0) for (self.arr_s, 0..) |*s, id| {
            if (!s.* or self.lowered.mem_arrays.items[id].held == none_u32) continue;
            s.* = for (self.an.i_op, 0..) |op, ii| {
                if (op != .fload) continue;
                const arr: Mir.Value = @enumFromInt(self.mir.insts.items(.a)[ii]);
                if (self.an.arrOf(arr).? != id or self.an.dFree(arr)) continue;
                if (self.core.eval_need[@intFromEnum(self.an.rv(self.an.i_res[ii]))]) break true;
            } else false;
        };
        // After the core planner, which is what fills them. Stable for the
        // rest of the compilation; `cached` reads them per unit.
        self.plan.lo_idx = self.core.lo_idx;
        self.plan.lo_vals = self.core.lo_vals;
        // LAST, and before ANY emission: the roots are what the core's slice
        // reaches, and `emitInstance` sizes `Setup` from them.
        try gen_setup.planSetup(self);
    }

    // Setup: the solve-invariant slice, computed once per card — codegen/setup.zig
    const gen_setup = @import("codegen/setup.zig");
    pub const probeInstance = gen_setup.probeInstance;

    // --------------------------------------------------------------- units ----

    // File assembly: the device.zig skeleton (§1.3.1 `U`, §3.4 `Model`, §4.5 `Instance`) — codegen/file.zig
    const gen_file = @import("codegen/file.zig");
    pub const emitFile = gen_file.emitFile;
    pub const fmtF64 = gen_file.fmtF64;

    // Units: one function per source unit, and the body each one computes — codegen/unit.zig
    const gen_unit = @import("codegen/unit.zig");

    // Control-flow reconstruction: MIR CFG -> structured Zig (the relooper) — codegen/cfg.zig
    const gen_cfg = @import("codegen/cfg.zig");

    // Value and instruction rendering: MIR value → Zig expression text (§4.2.1 conversions) — codegen/render.zig
    const gen_render = @import("codegen/render.zig");
    pub const renderVal = gen_render.renderVal;

    // Calls: §4.5 analog operators, §4.6 noise, Clause 9 system functions — codegen/call.zig
    const gen_call = @import("codegen/call.zig");
    pub const f64Const = gen_call.f64Const;
    pub const f64Expr = gen_call.f64Expr;
    pub const abort = gen_call.abort;
    pub const strArg = gen_call.strArg;

    // Dispatchers: §5.6 residual assembly, §1.3.1.2 reference directions — codegen/dispatch.zig
    const gen_dispatch = @import("codegen/dispatch.zig");

    // §4.5.2 the analog-operator state machine, and §5.6.5 zero-parasitic collapse — codegen/state.zig
    const gen_state = @import("codegen/state.zig");
};

/// LRM Table 4-14/4-15 by name, including the `log10` spelling that the `$`
/// (IEEE 1364 §17.11) form uses. Reuses lowering's tables — one source of truth.
pub fn mathOpByName(name: []const u8) ?Mir.Opcode {
    if (Lower.unaryMathOp(name)) |op| return op;
    if (Lower.binaryMathOp(name)) |op| return op;
    if (std.mem.eql(u8, name, "log10")) return .log10;
    return null;
}

pub const callArgIsValue = plan_args.callArgIsValue;

pub const isFileCall = plan_args.isFileCall;

pub fn isAnalysisName(s: []const u8) bool {
    const names = [_][]const u8{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" };
    for (names) |n| {
        if (std.mem.eql(u8, s, n)) return true;
    }
    return false;
}

/// Length of the §4.5.7 absdelay history ring.
// ponytail: a fixed 1024 samples with linear interpolation. The floor is set by
// SPICE canon, not by the model: maxstep = min(tstep, span/50), so a fixture
// like `T TD=2n` under `.tran 20p` legitimately runs td/dt = 100 accepted
// steps per delay, and edge-resolving LTE shrinkage pushes the worst case a
// few times higher; 1024 also covers a delay of 515 steps on a uniform grid
// (ch04_expressions/a04_05), which 512 did not. THE CEILING IS NOW LOUD: a
// query older than the whole ring @panics out of `zHistAt` instead of clamping
// to the oldest retained sample and reporting a shorter delay as this one.
// §4.5.7 bounds no lookback, so a silent clamp is a different operator, not an
// implementation-defined limit.
// Upgrade path: host-owned growable history (the engine's dormant
// HistoryBuffer channel), which is what ngspice does.
pub const hist_len: usize = 1024;

// ===========================================================================
// §4.5 analog operators — which ones own per-instance state
// ===========================================================================

/// Stateful analog operators (§4.5) and monitored events (§5.10.3). MUST agree
/// Does this opcode have a plain-f64 spelling a GPU can execute?
///
/// A unit body compiles for nvptx as well as for the host, and that target has
/// no libm — `@exp`, `@log` and every `std.math` call on an f64 fail PTX
/// assembly with "no libcall available for fexp". What is left is the
/// arithmetic LLVM lowers to a single PTX instruction. Everything else keeps
/// its S form, where the host's own math answers for it.
///
/// Only `f64Const`'s `in_unit` path consults this; a host-side `derive` line
/// still gets the whole of Table 4-14 and Table 4-15.
/// It is also REAL-ONLY, and that half is a correctness rule rather than a
/// target one. `f64Const` renders the integer opcodes in the f64 domain the way
/// `foldConst` folds them there, which drops §3.2's 32-bit wraparound —
/// `2147483647 + 1` is -2147483648 in a device and 2147483648.0 in an f64 — and
/// takes the low bits of a §2.6.1 64-bit literal with it. A control argument can
/// afford that (it is a constant expression the host evaluates once); a residual
/// cannot, and `intBin32` is the code that gets it right.
pub fn devSafe(op: Mir.Opcode) bool {
    // The `dev_safe` column: sqrt/floor/ceil are there because they are
    // sqrt.rn.f64 and cvt.rmi/rpi.f64.f64 — instructions.
    return opcode_zig.get(op).dev_safe;
}

// The operator set, and every fact about it, now lives in ONE place:
// `lib/ir/op.zig`. These declarations used to be the set's definition and
// four independent switches over it; they are now a name each file already
// spells, forwarding to a column. See that file's header for why.
//
// `naming.enumerateUnits` gives a unit to exactly the calls `Mir.callee.opKind`
// names (recorded as `Unit.op`), and `opHasState` decides which get Instance
// state — one table, one set.

pub const OpKind = opdb.OpKind;
pub const opHasState = opdb.hasState;

pub const opNeedsInput = plan_args.opNeedsInput;
pub const enableArgIdx = plan_args.enableArgIdx;

// Fixed emitted text: the runtime kernels every device carries (§4.3 math, §4.5 operators, Clause 9) — codegen/kernel_text.zig
const gen_kernel_text = @import("codegen/kernel_text.zig");

// Codegen self-checks: MIR in, device.zig text out, asserted by shape — codegen/test.zig
const gen_test = @import("codegen/test.zig");

test {
    _ = plan_names;
    _ = plan_topo;
    _ = plan_limit;
    _ = plan_noise;
    _ = plan_jobs;
    _ = plan_core;
    _ = plan_args;
    _ = plan_setup;
    _ = plan_qsite;
    _ = plan_jac;
    _ = UnitPlan;
    _ = float_mode;
    _ = float_lanes;
    _ = Gen.gen_setup;
    _ = Gen.gen_file;
    _ = Gen.gen_unit;
    _ = Gen.gen_cfg;
    _ = Gen.gen_render;
    _ = Gen.gen_call;
    _ = Gen.gen_dispatch;
    _ = Gen.gen_state;
    _ = gen_kernel_text;
    _ = gen_test;
    _ = opcode_zig;
}
