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
//!   2. `U` enum from Lower.node_order (ports first) + `num_ports`  (§1.3.1/§6.5)
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
const UnitPlan = @import("unit_plan.zig");
const cg_display = @import("cg_display.zig");
const cg_filters = @import("cg_filters.zig");
const cg_limit = @import("cg_limit.zig");
const Lower = @import("ir").Lower;
const proof = @import("ir").proof;
const diag = @import("diag");
const naming = @import("naming.zig");
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

/// What to do with the §9.4 display tasks a model contains.
///
/// The default is `.drop`, and it is not a shrug: a device is compiled once and
/// evaluated in the solver's inner loop, on a batch, sometimes on a GPU. A
/// `std.debug.print` in there is a per-Newton-iteration syscall on the CPU and
/// does not compile at all for SPIR-V/PTX. So a device NEVER prints, and a
/// source that asked to is told so (W0850) rather than silently obeyed.
///
/// `.emit` is the other product VerA makes out of the same .va: a runnable
/// testbench, where the whole point is the text. See `--emit-exe` and tb.zig.
pub const Display = enum { drop, emit };

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
    lower: *const Lower,
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

    const an = try Analysis.build(arena, mir, lower);
    var g: Gen = .{
        .gpa = gpa,
        .an = &an,
        .arena = arena,
        .mir = mir,
        .lower = lower,
        .verdict = verdict,
        .display = opts.display,
        .jac_f32 = opts.jac_f32 or opts.jac_f32_host,
        .jac_f32_host = opts.jac_f32_host,
        .diags = opts.diags,
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
pub const array_index_types = std.StaticStringMap(VTy).initComptime(.{
    .{ "$idx", .real },
    .{ "$idx$int", .int },
    .{ "$idx$str", .str },
});

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
    lower: *const Lower,
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

    units: []naming.Unit = &.{},
    unit_names: [][]const u8 = &.{},
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
    /// §4.6.4 `noise_gens` and `noisePsd`, one row each, built by `planNoise`.
    noise_rows: []gen_unit.NoiseRow = &.{},
    /// §4.6.4.3/.4 `noise_tables`, one entry per tabulated generator, folded
    /// and sorted by `planNoise`. Position k is `noise_rows[j].table == k`.
    noise_tabs: []const []const [2]f64 = &.{},
    /// The same knots as `noise_tabs`, in the same order, still as MIR values —
    /// and only for a table A.8.2's `parameter_identifier` spelling made
    /// MODEL-DEPENDENT, so `noise_tabs` holds its declared defaults and only
    /// this can state the card's. An empty slice is a table of literals, which
    /// needs nothing beyond the comptime export. See `emitNoiseTablePoints`.
    noise_tab_vals: []const []const [2]Mir.Value = &.{},
    /// §4.6.3 `ac_gens` and `acStim`, one row each. Same walk as `noise_rows`
    /// and separated from it by `kind`: a stimulus is not a generator and must
    /// never reach `noise_gens`, but it reaches codegen through the same
    /// `Contribution.noise_srcs` set.
    ac_rows: []gen_unit.NoiseRow = &.{},
    /// Set by `refuseNoise`: the §4.6.4 export VerA will not write, as the
    /// message the generated `@compileError` carries. First one wins — a device
    /// is refused once, and the diagnostics carry the rest.
    noise_fatal: ?[]const u8 = null,
    /// Every unit function to emit, resolved before any of them is written.
    jobs: []gen_unit.Job = &.{},
    /// Position of this Value in the core's returned struct, or `none_u32`.
    /// Only the unit TARGETS cross the declaration boundary; every one of the
    /// ~22 000 subexpressions behind them stays a local of the core.
    lo_idx: []u32 = &.{},
    /// The returned values, in job order — `lo_idx` is the index into this.
    lo_vals: []Mir.Value = &.{},
    /// §5.6.1.2 path-integrated reactive latches: rv-resolved operand of
    /// every `path_prev`/`path_acc`, each family deduplicated (CSE-shared
    /// sites share a latch — same committed value). `*_lo[k]` is the
    /// operand's slot in `lo_vals`. `path_prev` renders `S.con(inst.pb__k)`
    /// (operand at the last accepted solve), `path_acc` renders
    /// `S.con(inst.pq__k)` (sum of committed operands — the charge base).
    /// `updateState` STAGES both operands into `wb__/wq__` once per Newton
    /// iterate; `stateCtl(.commit)` — operating-point exit and transient
    /// accepted step — latches `pb = wb`, `pq += wq` and zeroes `wq` so a
    /// stray double commit adds 0, not a doubled increment.
    prev_vals: []Mir.Value = &.{},
    prev_lo: []u32 = &.{},
    acc_vals: []Mir.Value = &.{},
    acc_lo: []u32 = &.{},
    /// Temperature/parameter-only hoist (ngspice's `<dev>temp` phase, done
    /// once instead of per eval): value → `Instance.pc__<k>` field index or
    /// `none_u32`, and the mapped roots in field order. Filled by
    /// `planPrecompute`; `emitPrecompute` writes the fields, every other body
    /// reads them as leaves (unit_plan `pcHoisted`).
    pc_idx: []u32 = &.{},
    pc_vals: []Mir.Value = &.{},
    /// §4.5.15 the solve-independent `$limit`/`seed` arguments, hoisted out of
    /// the per-iterate clamp: value → `Instance.lp__<k>` field index or
    /// `none_u32`, and the mapped values in field order. Filled by
    /// `cg_limit.planPrep`; `precompute`'s tail writes them off ONE core
    /// evaluation at x = 0, and `limit`/`seed` read them as leaves.
    lp_idx: []u32 = &.{},
    lp_vals: []Mir.Value = &.{},
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
    /// kernels run in the one unit `planCommon` deliberately keeps out of the
    /// shared core, and in every other unit the family keeps the constant it has
    /// always had. §9.5.9 states the same rule normatively: "if a file is being
    /// written to during an iterative solve, then the file write operations shall
    /// not be performed unless the iteration is accepted."
    emitting_display: bool = false,
    /// `<module>__common__core`, or empty for a model with no targets at all.
    common_name: []const u8 = "",
    common_mode: proof.FloatMode = .optimized,
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
    /// Float mode of the unit CURRENTLY being emitted. `.strict` is the eager
    /// `sel` license — see `renderInst`'s select case. Set by `emitUnit` and
    /// the common-core emitter, false-by-default so any other emission path
    /// keeps the lazy form.
    cur_strict: bool = false,
    /// True once any residual/charge unit steered on an x-dependent value
    /// through a scalar — a `.val()` comparison, a lazy `if`, an int cast, an
    /// event operator, a value-collapsing helper (floor, table lookup …). A
    /// device that finishes with this still false gets `pub const lane_clean
    /// = true;`: instantiating eval/q with a LANE-PARALLEL S (one operating
    /// point per lane) is then exact per lane, which the testbench's batch
    /// differential check asserts. Display units never set it — they are not
    /// part of the residual.
    lane_pinned: bool = false,
    /// §9.4. `.drop` ⇒ nothing below ever looks at `lower.display_root`.
    display: Display = .drop,
    /// `Options.jac_f32` — emit the single-precision-Jacobian permission decl.
    jac_f32: bool = false,
    /// `Options.jac_f32_host` — emit the host-should-take-it-too decl.
    jac_f32_host: bool = false,
    /// `Options.diags` — where E0515 goes, when the caller kept a bag.
    diags: ?*diag.Bag = null,
    /// `<module>__display__tasks`, or empty when the model prints nothing (or
    /// when `display == .drop`). Set by `buildJobs`, which is also where the job
    /// that renders it is queued.
    display_name: []const u8 = "",
    /// Extra solver unknowns codegen appends after `Lower.node_order`: one
    /// branch current per §5.6 potential contribution that lowering did not
    /// already give a `flow(a,b)` slot. Values are node_order-space indices.
    branch_u: []u32 = &.{},
    /// §5.4.2.1/§5.6.6 — the branch-flow unknowns NO branch row defines, in
    /// slot order. See `FreeFlow` and `emitStamps`.
    free_flows: []const gen_state.FreeFlow = &.{},
    /// The §5.6.5 switch branches `collapse` aliases away (`collapsePairs`).
    /// Cached because `emitSwitchRow` needs the membership test and the list
    /// is built once, before any residual is emitted.
    cpairs: []const gen_state.CollapsePair = &.{},
    n_u: u32 = 0,
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
    /// The lanes a §4.5.14 `ddx` reads BY INDEX (`.ddxAt(u)`): the emitted
    /// `ddx_reads`, and a subset of `deriv_reads` by construction.
    ddx_reads: u64 = 0,
    /// The dispatcher's constant-coefficient terms, per half:
    /// `lin[react][row * n_u + col]` is the exact coefficient of `x[col]` in
    /// `res[row]` as far as the stamps are linear. Only the columns OUTSIDE
    /// `deriv_reads` leave as `jac_const`; inside, the lane carries them.
    /// Empty above 64 unknowns, where neither decl is emitted.
    lin: [2][]f64 = .{ &.{}, &.{} },
    /// Sanitized U-enum member name per unknown.
    u_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lower.params` entry.
    p_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lower.aliases` entry (§3.4.7).
    a_names: [][]const u8 = &.{},
    /// §5.10 `Instance` field name per `Lower.held_vars` entry.
    held_names: [][]const u8 = &.{},
    /// Core field index holding each held variable's end-of-block value, or
    /// `none_u32` when it folded to `.f_zero`. Filled by `planCommon`.
    held_idx: []u32 = &.{},
    /// Parameters queried by §9.19 `$param_given` (they gain a `__given` flag).
    p_given: []bool = &.{},
    /// Does the module read §9.15 `$simparam("tnom")`? Its Model then carries
    /// the host-written `Lower.simparamHostField("tnom")` field.
    uses_nom_temp: bool = false,
    /// §4.5.15 the `$limit` call sites this device honours, in source order,
    /// and one line per site it does not. Filled by `cg_limit.collect` before
    /// `buildJobs`, which queues their algorithm arguments into the core.
    limits: []cg_limit.LimitCall = &.{},
    limits_declined: [][]const u8 = &.{},
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

    // ---- the core's hoisted PREFIX (see `planHoistPrefix`) ----------------
    /// This body is a prefix-cache candidate: the common core, tree-shaped,
    /// no fatal. Cleared again if planning finds no region.
    hp_on: bool = false,
    /// Values the cached region defines and the rest of the core reads —
    /// reals first, so `hp_vals[j]` is `Instance.hp[j]` while `j < hp_real`
    /// and `Instance.hpi[j - hp_real]` after. They are ALSO core live-outs,
    /// in fields `f{lo_vals.len + j}`, which is how `precompute` fills them.
    hp_vals: []Mir.Value = &.{},
    hp_real: u32 = 0,
    /// Top-level statement boundary the region ends at (0 = no region), and
    /// the running boundary counter of the body being emitted.
    hp_cut: u32 = 0,
    hp_bnd: u32 = 0,
    /// Probe-text offset of the candidate cut, and "something the cache
    /// cannot hold has been emitted, so the cut may not advance past here".
    hp_off: u32 = 0,
    hp_dirty: bool = false,
    /// Statements the region holds, for the "is skipping it worth a field"
    /// test in `planHoistPrefix`.
    hp_insts: u32 = 0,

    /// Statements emitted so far in the body being walked; `hpBoundary`
    /// snapshots it as the prefix region's size.
    stmt_count: u32 = 0,

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
        try self.buildUnits();
        try self.buildNames();
        // After `buildNames`, which fills `branch_u` — the claim `freeFlows`
        // subtracts.
        self.free_flows = try gen_state.freeFlows(self);
        try cg_filters.planAll(self);
        // Before `buildJobs`: §4.5.15 the algorithm arguments of every honoured
        // `$limit` become core live-outs, and `buildJobs` is what queues them.
        try cg_limit.collect(self);
        // Before `buildJobs`: §4.6.4 the PSD arguments become core live-outs
        // too, and `buildJobs` is what queues them.
        try gen_unit.planNoise(self);
        try gen_unit.buildJobs(self);
        try gen_common.planCommon(self);
        try gen_hoist.planPrecompute(self);
        // After the two planners, which are what fill them. Stable for the
        // rest of the compilation; `cached`/`pcHoisted` read them per unit.
        self.plan.lo_idx = self.lo_idx;
        self.plan.lo_vals = self.lo_vals;
        self.plan.pc_idx = self.pc_idx;
        self.plan.pc_on = self.pc_vals.len != 0;
        // LAST: §4.5.15 the clamp-argument hoist needs `lo_idx` filled, to name
        // the core field `emitPrep` reads each argument out of.
        // These planners evaluate the whole core during parameter preparation.
        // A first-call table must wait for the actual evaluation, not x = 0 prep.
        try cg_limit.planPrep(self);
        // After it, and before ANY emission: `emitInstance` and `emitPrecompute`
        // are both written above the core and both need the region's width.
        if (self.lower.table_samples.items.len == 0) try gen_hoist.planHoistPrefix(self);
    }

    // The shared core: values several units read, computed once per eval — codegen/common.zig
    const gen_common = @import("codegen/common.zig");

    // Hoisting: the temperature hoist and the hoisted core prefix — codegen/hoist.zig
    const gen_hoist = @import("codegen/hoist.zig");
    pub const probeInstance = gen_hoist.probeInstance;

    // --------------------------------------------------------------- units ----

    fn buildUnits(self: *Gen) Error!void {
        const a = self.arena;
        self.units = naming.enumerateUnits(a, self.mir, self.lower) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.NameTooLong,
        };
        // The contract `unitMode` below depends on, checked once where all
        // three tables are in hand for the only time.
        naming.assertCanonicalOrder(self.units, self.lower, self.verdict.unit_modes.len);
        self.unit_names = try a.alloc([]const u8, self.units.len);
        var buf: [naming.max_name_len]u8 = undefined;
        for (self.units, 0..) |u, i| {
            const n = naming.unitName(&buf, self.mir.name, u) catch return error.NameTooLong;
            self.unit_names[i] = try a.dupe(u8, n);
        }
    }

    /// Is unknown `u` already the current of a source from a contribution
    /// before `i`? Two sources in one branch need two currents.
    fn uIsDriven(self: *const Gen, u: u32, i: usize) bool {
        // ponytail: stdlib scans the same bounded prefix; no membership table needed.
        return std.mem.indexOfScalar(u32, self.branch_u[0..i], u) != null;
    }

    /// `nm`, or `nm#k` for the first `k` that no unknown claims yet. `sanitize`
    /// escapes `#`, so the emitted U member stays a legal, injective name.
    fn freshUName(self: *const Gen, nm: []const u8, extra: []const []const u8) Error![]const u8 {
        var name = nm;
        var k: u32 = 1;
        while (self.uNameTaken(name, extra)) : (k += 1) {
            name = try std.fmt.allocPrint(self.arena, "{s}#{d}", .{ nm, k });
        }
        return name;
    }

    fn uNameTaken(self: *const Gen, nm: []const u8, extra: []const []const u8) bool {
        for (self.lower.node_order.items) |n| {
            if (std.mem.eql(u8, n, nm)) return true;
        }
        for (extra) |n| {
            if (std.mem.eql(u8, n, nm)) return true;
        }
        return false;
    }

    fn buildNames(self: *Gen) Error!void {
        const a = self.arena;
        var buf: [naming.max_name_len]u8 = undefined;

        // §5.6 potential contributions need a branch-current unknown. Lowering
        // allocates a `flow(a,b)` slot only where the model PROBES I(a,b), so
        // codegen appends the missing ones after node_order — every existing
        // block_param index keeps its meaning.
        const base: u32 = @intCast(self.lower.node_order.items.len);
        self.branch_u = try a.alloc(u32, self.lower.contributions.items.len);
        @memset(self.branch_u, none_u32);
        // Raw names of the unknowns appended after node_order, in append order.
        var extra: std.ArrayList([]const u8) = .empty;
        for (self.lower.contributions.items, 0..) |c, i| {
            // A §5.6 potential source and a §5.6.7 indirect (nullor) source are
            // the same topology: a source in the branch whose current is its
            // own unknown.
            if (c.access != .potential and c.kind != .indirect) continue;
            // Reuse the §5.4.2 slot lowering already allocated because the model
            // PROBES I(a,b) — unless an earlier contribution is already driving
            // it. §5.6.7.1 permits several indirect contributions to one branch,
            // and each is a separate source with a separate current.
            //
            // Asked for by the NODE PAIR, which is the identity §5.4.1 gives the
            // branch. This used to format `flow(hi,lo)` and scan `node_order`
            // for a string match, which made it the fourth place that re-derived
            // structure from a spelling — and the one that survived the key
            // split in lowering: §1.3.1.1's reference node prints `gnd`, so on a
            // module with a plain net called `gnd` the branches (a, reference)
            // and (a, gnd) matched each other's slot and V(a) and V(a,gnd) drove
            // one current.
            var found: u32 = if (self.lower.flow_unknowns.get(.{ .hi = c.hi, .lo = c.lo })) |u| u else none_u32;
            if (found != none_u32 and self.uIsDriven(found, i)) found = none_u32;
            if (found == none_u32) {
                const nm = try std.fmt.allocPrint(a, "flow({s},{s})", .{
                    self.lower.nodeName(c.hi), self.lower.nodeName(c.lo),
                });
                found = base + @as(u32, @intCast(extra.items.len));
                try extra.append(a, try self.freshUName(nm, extra.items));
            }
            self.branch_u[i] = found;
        }
        self.n_u = base + @as(u32, @intCast(extra.items.len));

        self.u_names = try a.alloc([]const u8, self.n_u);
        for (self.lower.node_order.items, 0..) |n, i| {
            self.u_names[i] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
        }
        for (extra.items, 0..) |n, k| {
            self.u_names[base + k] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
        }

        self.p_names = try a.alloc([]const u8, self.lower.params.items.len);
        for (self.lower.params.items, 0..) |p, i| {
            self.p_names[i] = try a.dupe(u8, naming.sanitize(&buf, p.name) catch return error.OutOfMemory);
        }
        self.a_names = try a.alloc([]const u8, self.lower.aliases.items.len);
        for (self.lower.aliases.items, 0..) |al, i| {
            self.a_names[i] = try a.dupe(u8, naming.sanitize(&buf, al.name) catch return error.OutOfMemory);
        }

        // §5.10 held variables. Same `<module>__<role>__<target>` grammar
        // `naming.unitName` builds, with `held` where a role word would go:
        // `naming.Role` is a closed set that this is deliberately not a member
        // of (a held variable is not an emitted source unit), and no enumerated
        // unit can spell that segment, so the two name spaces cannot meet. The
        // target is one `sanitize`d leaf, which is injective — and a module
        // variable's name is unique in its scope, so the whole key is.
        self.held_names = try a.alloc([]const u8, self.lower.held_vars.items.len);
        if (self.held_names.len != 0) {
            var mod_buf: [naming.max_name_len]u8 = undefined;
            const mod = naming.sanitize(&mod_buf, self.mir.name) catch return error.NameTooLong;
            for (self.lower.held_vars.items, 0..) |h, i| {
                const leaf = naming.sanitize(&buf, h.name) catch return error.NameTooLong;
                self.held_names[i] = try std.fmt.allocPrint(a, "{s}__held__{s}", .{ mod, leaf });
            }
        }
        self.p_given = try a.alloc(bool, self.lower.params.items.len);
        @memset(self.p_given, false);
        // A non-local parameter whose default reads another parameter is a
        // `derive()` target, and its guard (`if (!model.X__given)`) needs the
        // flag whether or not the model ever queries §9.19 — same fold
        // condition `emitDerive` selects assignments on.
        for (self.lower.params.items, 0..) |p, i| {
            if (p.is_local or Analysis.tyOfParam(p.ty) == .str) continue;
            if (self.an.foldConst(p.default, 0, false) == null) self.p_given[i] = true;
        }
        // §9.15's host-published `$simparam` is recorded at the CALL, not by
        // this walk: a parameter default is lowered outside the block stream,
        // and `parameter real tnom = $simparam("tnom")` is the whole point.
        self.uses_nom_temp = self.lower.uses_host_simparam;
        // §9.19 $param_given(p): the flag lives in Model, but only for the
        // parameters actually asked about.
        for (0..self.an.nb) |bi| {
            for (self.an.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.mir.instOp(inst) != .call) continue;
                const d = self.mir.instData(inst).call;
                if (!std.mem.eql(u8, d.name, "$param_given")) continue;
                if (d.args.len == 0) continue;
                const def = self.mir.valueDef(self.an.rv(d.args[0]));
                if (def == .param_ref) self.p_given[def.param_ref] = true;
            }
        }
    }
    // File assembly: the device.zig skeleton (§1.3.1 `U`, §3.4 `Model`, §4.5 `Instance`) — codegen/file.zig
    const gen_file = @import("codegen/file.zig");
    pub const emitFile = gen_file.emitFile;
    pub const isFlowUnknown = gen_file.isFlowUnknown;
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

/// Is argument `i` of this call RENDERED as a value in the calling unit? The
/// others are consumed at codegen time — analysis names (§4.6.1), operator
/// control constants (§4.5), and the operator INPUT, which its own unit
/// recomputes. Keeping this in step with `emitCall` is what stops the slice
/// from declaring a local nothing reads (a hard error in Zig).
/// Is argument `i` of this call an expression the unit has to COMPUTE?
///
/// Most ch9 tasks answer from `Instance` or lower to a constant, so their
/// arguments are dead and slicing them in would emit code nothing reads. The
/// exception is the display family under `display == .emit`: there the operands
/// are the entire point, and forgetting them here renders every one of them as
/// an undefined leaf — which is what `S.con(0.0)` in a print means.
pub fn callArgIsValue(name: []const u8, i: usize, display: Display) bool {
    // The §5.10.3 `enable` is the exception: it is a live expression the event
    // test reads every evaluation, so it needs a slot like any other operand.
    if (opKind(name) != .none) return (enableArgIdx(name) orelse return false) == i;
    const eq = std.mem.eql;
    if (display == .emit and Lower.isDisplayTask(name)) return true;
    // §9.5 every operand is live: the path, the type, the descriptor, the control
    // string, the offset. `emitSysCall` renders them all — in the display unit
    // because the kernels take them, and in every other unit through
    // `emitFileCallDropped`, which exists precisely so this answer can be one
    // rule instead of two.
    if (display == .emit and Lower.isFileCall(name)) return true;
    if (eq(u8, name, "$rng$check")) return i != 1; // prior effect and checked values
    // A live variate/Next call reads its seed and numeric parameters. The
    // automatic-seed site's index is consumed by the emitter, not at runtime.
    if (std.mem.startsWith(u8, name, "$rng$")) return !eq(u8, name, "$rng$auto");
    if (array_index_types.has(name)) return i > 0; // index and selectable cells
    if (eq(u8, name, "$limit$uf")) return i < 2;
    // §9.15's param_name may be "a string variable", so `emitSysCall` renders
    // it and the unit has to compute it.
    if (eq(u8, name, "$simparam$str")) return i == 0;
    if (eq(u8, name, "ddx")) return i == 0;
    if (eq(u8, name, "limexp")) return i == 0;
    if (name.len == 0 or name[0] != '$') return false; // events, noise, analysis
    if (eq(u8, name, "$vt") or eq(u8, name, "$limit") or
        eq(u8, name, "$clog2") or eq(u8, name, "$rtoi") or eq(u8, name, "$itor")) return i == 0;
    const bare = name[1..];
    if (mathOpByName(bare) != null) return true;
    if (eq(u8, bare, "abs") or eq(u8, bare, "min") or eq(u8, bare, "max")) return true;
    return false;
}

pub fn isAnalysisName(s: []const u8) bool {
    const names = [_][]const u8{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" };
    for (names) |n| {
        if (std.mem.eql(u8, s, n)) return true;
    }
    return false;
}

/// §4.5 Table 4-20 "Analog operator arguments": which argument positions the
/// clause marks DYNAMIC (the input at position 0 is already a unit of its own,
/// so it is not listed here). Everything absent from this table stays a
/// `constant_expression` and is still E0515 when it is a solve result.
pub fn dynCtrlArgs(k: OpKind) []const usize {
    return switch (k) {
        .absdelay => &.{1}, // td  ("dynamic: expr, td"; maxdelay is the constant one)
        .idt => &.{ 1, 2 }, // ic, assert
        .idtmod => &.{ 1, 2, 3 }, // ic, modulus, offset
        else => &.{},
    };
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

pub fn unitComment(c: Lower.Contribution, react: bool) []const u8 {
    if (react) return "§5.6.1.2 reactive part (charge/flux; q() differentiates it)";
    if (c.kind == .indirect)
        return "§5.6.7 indirect contribution — the constraint `<probe> − <equation>`";
    return switch (c.access) {
        .flow => "§5.6 flow contribution — current into `hi`, out of `lo` (§1.3.1.2)",
        .potential => "§5.6 potential contribution — the branch constitutive relation",
    };
}

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
    return switch (op) {
        .fadd, .fsub, .fmul, .fdiv, .fneg => true,
        .fabs, .fmin, .fmax => true,
        // sqrt/floor/ceil are sqrt.rn.f64 and cvt.rmi/rpi.f64.f64 — instructions.
        .sqrt, .floor, .ceil => true,
        .opt_barrier => true,
        else => false,
    };
}

// The operator set, and every fact about it, now lives in ONE place:
// `lib/ir/op.zig`. These five declarations used to be the set's definition and
// four independent switches over it; they are now a name each file already
// spells, forwarding to a column. See that file's header for why.
//
// `naming.enumerateUnits` gives a unit to exactly the calls `opKind` names, and
// `opHasState` decides which get Instance state — one table, one set.

pub const OpKind = opdb.OpKind;
pub const opKind = opdb.byName;
pub const opHasState = opdb.hasState;

/// Does this operator's kernel read the CURRENT input? The pure-history ones
/// answer from `Instance` alone, and rendering an input they never emit would
/// leave the unit claiming a parameter (or a cache) nothing references.
/// `emitOperator` renders `in` exactly for these; `planSlots` has to agree,
/// which is why the set lives in the table and not in either of them.
pub fn opNeedsInput(k: OpKind) bool {
    return opdb.get(k).needs_input;
}

/// §5.10.3.1/.2/.3 where each event operator carries its `enable` — the one
/// argument of an analog operator that is a runtime expression, so `UnitPlan`
/// has to keep it live (see `callArgIsValue`) while every other control
/// argument is folded at codegen time.
pub fn enableArgIdx(name: []const u8) ?usize {
    // The table stores it as `?u8` — an argument index, and the narrowest type
    // the range allows. Widened here, at the one boundary that indexes with it.
    return opdb.get(opKind(name)).enable_arg orelse return null;
}

// Fixed emitted text: the runtime kernels every device carries (§4.3 math, §4.5 operators, Clause 9) — codegen/kernel_text.zig
const gen_kernel_text = @import("codegen/kernel_text.zig");

// Codegen self-checks: MIR in, device.zig text out, asserted by shape — codegen/test.zig
const gen_test = @import("codegen/test.zig");

test {
    _ = Gen.gen_common;
    _ = Gen.gen_hoist;
    _ = Gen.gen_file;
    _ = Gen.gen_unit;
    _ = Gen.gen_cfg;
    _ = Gen.gen_render;
    _ = Gen.gen_call;
    _ = Gen.gen_dispatch;
    _ = Gen.gen_state;
    _ = gen_kernel_text;
    _ = gen_test;
}
