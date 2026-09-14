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
const Mir = @import("../ir/mir.zig");
const Analysis = @import("../ir/analysis.zig");
const UnitPlan = @import("unit_plan.zig");
const cg_display = @import("cg_display.zig");
const cg_filters = @import("cg_filters.zig");
const cg_limit = @import("cg_limit.zig");
const Lower = @import("../ir/lower.zig");
const proof = @import("../ir/proof.zig");
const diag = @import("diag");
const naming = @import("naming.zig");
const assert = std.debug.assert;

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
};

const none_u32 = std.math.maxInt(u32);

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
    /// Outline a huge body into `noinline` chunk functions of ~this many
    /// statements each (0 = never, the default). See `emitUnitBody`.
    ///
    /// MEASURED (bsim4va/hisimhv/bsimsoi, zig 0.16 / LLVM 21, -OReleaseFast):
    ///   - nvptx64 (GPU kernels): the whole point. The monolithic bsim4va
    ///     core takes the NVPTX backend 2 min 24 s and emits 1.2 GB of PTX
    ///     (register-file spill storm — ../ARPice/docs/gpu-device-eval.md §4);
    ///     chunked at 300 it is 1.3 s and 26 MB. Pass `--outline-chunk=300`
    ///     when generating a model a GPU kernel root will compile.
    ///   - host, -fstrip (how release hosts build): NEUTRAL to slightly
    ///     negative (bsim4va 1.35 s -> 1.95 s) — the monolith's superlinear
    ///     term was DWARF, which stripping already removes.
    ///   - host, debug info on: 2.6-3.5x faster (6.4 s -> 2.3 s bsim4va,
    ///     14 s -> 4.1 s hisimhv).
    ///   - host RUNTIME of eval: 1.8-3x SLOWER chunked — cross-chunk values
    ///     live in memory (the shared hoist arrays) where the monolith held
    ///     them in registers; chunk-local `var`s claw back part (9.99 s ->
    ///     7.58 s per 1e6 bsim4va evals at 300, monolith 3.18 s) and bigger
    ///     chunks help (5.87 s at 2000), but no size meets a 2% budget.
    ///
    /// So: OFF unless the artifact is a GPU kernel or a build-time-bound
    /// development loop. Emitted values are the same statements either way —
    /// verified bit-identical (f, q, all partials) on the three models above.
    outline_chunk: u32 = 0,
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
    /// Set if any unit collapsed to `@compileError` (see `Gen.any_fatal`).
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
        .outline = opts.outline_chunk,
    };
    errdefer g.out.deinit(gpa);
    try g.prepare();
    try g.emitFile();
    fatal_out.* = g.any_fatal;
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
const VTy = Analysis.VTy;

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
    /// declaration being written. Carries deliberate cross-unit residue — see
    /// unit_plan.zig's header before touching its reset.
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
    /// Sticky: any unit collapsed to `@compileError`. Reported out so callers do
    /// not have to substring-search the generated file for it.
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
    noise_rows: []NoiseRow = &.{},
    /// Every unit function to emit, resolved before any of them is written.
    jobs: []Job = &.{},
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
    /// Unit index of the analog-operator `call` at `Inst`, or `none_u32`.
    op_unit: []u32 = &.{},
    /// Extra solver unknowns codegen appends after `Lower.node_order`: one
    /// branch current per §5.6 potential contribution that lowering did not
    /// already give a `flow(a,b)` slot. Values are node_order-space indices.
    branch_u: []u32 = &.{},
    /// The §5.6.5 switch branches `collapse` aliases away (`collapsePairs`).
    /// Cached because `emitSwitchRow` needs the membership test and the list
    /// is built once, before any residual is emitted.
    cpairs: []const CollapsePair = &.{},
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

    /// Where each slot's declaration goes — `probeBody` fills this, and it is
    /// only meaningful for the out-of-SSA path (`straight` declares everything
    /// at its definition by construction).
    place: std.ArrayList(Place) = .empty,
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
    /// unchunked, no fatal. Cleared again if planning finds no region.
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

    // ---- outlining (`Options.outline_chunk`) — all per-unit transient ----
    /// Statements per chunk (the option). 0 disables.
    outline: u32 = 0,
    /// Chunking is on for the body being emitted (size gate passed, shape ok).
    oc_on: bool = false,
    /// Real pass is inside `emitChunkFns` — `maybeCut` closes/opens chunk fns.
    oc_real: bool = false,
    /// Probe saw a shape the driver layout cannot host: more than one return,
    /// none, or executable text after it (see `probeBody`'s trailing check).
    oc_bad: bool = false,
    oc_returns: u32 = 0,
    /// Probe text offset just past the first emitted return.
    oc_ret_at: usize = 0,
    /// Rendering the return right now — every slot it names must be readable
    /// from the driver, so `probeUse` pins it into a hoist array.
    oc_in_ret: bool = false,
    /// Probe-text offset where each chunk's content starts, plus a terminal
    /// entry at the return. A hoisted slot whose whole life
    /// [def_off, max(max_use, max_def)] sits inside ONE such interval is
    /// declared as that chunk's own `var` instead of in the shared arrays —
    /// LLVM then promotes it exactly like the monolith's locals, which is
    /// most of the outlining runtime cost (bsim4va: 799 of 1368 h slots).
    oc_bounds: std.ArrayList(u32) = .empty,
    /// (chunk, slot, type) rows for those chunk-local vars, in live order.
    oc_local_chunk: std.ArrayList(u32) = .empty,
    oc_local_slot: std.ArrayList(u32) = .empty,
    oc_local_ty: std.ArrayList(VTy) = .empty,
    /// Statements emitted since the open chunk began — the cut trigger.
    oc_insts: u32 = 0,
    /// Cuts fired so far == index of the OPEN chunk. Probe and real pass must
    /// agree (asserted in `emitChunkFns`); both count the same walk.
    oc_cuts: u32 = 0,
    /// Chunk count the probe settled on; the driver call list is emitted from
    /// this before the chunk bodies exist.
    oc_total: u32 = 0,
    /// Unit name + float mode for the chunk headers (`{name}__c{k}`).
    oc_name: []const u8 = "",
    oc_mode: []const u8 = "",
    /// Parameter-name patch offsets of the OPEN chunk header:
    /// x, model, inst, h, hi, hs — same trick as `emitUnit`'s signature.
    oc_at: [6]usize = @splat(0),
    /// Did the open chunk touch each hoist array? (x/model/inst ride the
    /// existing `uses_*` flags.)
    oc_use: [3]bool = @splat(false),
    /// Hoist array lengths by VTy (0 = absent from signatures and calls).
    oc_n: [3]u32 = @splat(0),

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
        // Before `buildJobs`: §4.5.15 the algorithm arguments of every honoured
        // `$limit` become core live-outs, and `buildJobs` is what queues them.
        try cg_limit.collect(self);
        // Before `buildJobs`: §4.6.4 the PSD arguments become core live-outs
        // too, and `buildJobs` is what queues them.
        try self.planNoise();
        try self.buildJobs();
        try self.planCommon();
        try self.planPrecompute();
        // After the two planners, which are what fill them. Stable for the
        // rest of the compilation; `cached`/`pcHoisted` read them per unit.
        self.plan.lo_idx = self.lo_idx;
        self.plan.lo_vals = self.lo_vals;
        self.plan.pc_idx = self.pc_idx;
        self.plan.pc_on = self.pc_vals.len != 0;
        // LAST: §4.5.15 the clamp-argument hoist needs `lo_idx` filled, to name
        // the core field `emitPrep` reads each argument out of.
        try cg_limit.planPrep(self);
        // After it, and before ANY emission: `emitInstance` and `emitPrecompute`
        // are both written above the core and both need the region's width.
        try self.planHoistPrefix();
    }

    // ---------------------------------------------------- the shared core ----
    //
    // WHY THIS EXISTS. `emitUnit` renders the full backward slice of one
    // `Mir.Value` through a CFG all the units share, so ~105 units each emit the
    // same core: `hisimhv_va` measured 1 220 929 emitted values across 58 units
    // of which 22 214 distinct values appear in two or more — 190 MB of output
    // from 614 K of source.
    // CORPUS: `hisimhv_va` is one of the 38 foundry models in the ARPice host
    // repo (`../ARPice/src/devices/models`; `VERA_MODELS` overrides the path).
    // NOT vendored here and no fixture is within three orders of magnitude of
    // it, so every number in this block needs that checkout to re-measure.
    //
    // Recomputing the shared subexpressions per unit was the ORIGINAL shape and
    // it was deliberate: an anonymous subexpression was never promoted to a
    // hidden shared decl, so that every unit stayed independently skippable by
    // `zig -fincremental`. That justification does not hold, and naming.zig's
    // header already concedes the same point for NAMED units — `zig` tracks a
    // declaration by name and dirties its consumers correctly when it changes.
    // A shared declaration is therefore BETTER for incrementality, not worse —
    // one declaration to re-analyse instead of 58 copies of it — and the units'
    // own tails stay independently skippable either way.
    //
    // WHY ONE DECLARATION AND NOT ONE PER VALUE. The obvious shape — a function
    // per shared value, calling the functions of its operands — is wrong, and
    // measurably so: the shared values form a DAG, so a value reachable by two
    // paths would be recomputed once per path, and the cost is exponential in
    // the DAG depth. The values have to be computed ONCE and PASSED.
    //
    // WHY *EVERY* TARGET IS IN IT, and not just the ≥K-shared subexpressions.
    // Hoisting a shared region and leaving a per-unit tail behind was measured,
    // and it is the wrong shape twice over:
    //
    //   SIZE. The tails are not tails. `emitCode` walks the whole reachable CFG
    //   for every unit, so each one re-materialises every merge block and every
    //   §5.9 loop whether or not it computes anything in them. On `hisimhv_va`
    //   the 58 tails were 378 634 lines of which 10 830 — 2.86% — were
    //   arithmetic; the median tail was 6 007 lines containing 6 operations.
    //   Folding the targets into the core deletes all of it: 440 124 → 59 986
    //   lines, 23.73 → 3.25 MB. The merged body is the same size as the core
    //   already was (60 061 lines), because the tails carried no information.
    //
    //   RUNTIME. Every tail opened with `const c = core(...)`, so one `eval`
    //   evaluated the core once per contribution — 40 times on `hisimhv_va`,
    //   30 on `vbic13_4t`. LLVM does NOT recover this: built -OReleaseFast it
    //   inlines all 30 `vbic13_4t` tails into the caller and still emits 30
    //   calls to the core (`objdump | grep -c core` = 30), because it cannot
    //   prove a 60 000-line two-pointer function `readonly willreturn`. Merging
    //   is therefore a runtime fix, not a size optimisation: one core per
    //   `eval`, one per `q`.
    //   CORPUS: `vbic13_4t` is the public VBIC 1.3 four-terminal reference
    //   Verilog-A, from the same 38-model set — likewise not vendored here.
    //
    // WHAT IS LOST. The per-unit `@setFloatMode` — see `common_mode`. Nothing
    // else: `contract.zig` exposes only `eval`/`q`, and engine.zig (:511, :534,
    // :1216) always evaluates the whole residual, so a unit was never
    // independently callable in the first place.

    /// Decide what the one emitted body returns: every unit target, deduplicated
    /// and in job order.
    ///
    /// Job order — contributions in source order, then §4.5 operator inputs,
    /// then §9.4 display — is what makes `f<k>` insert-tolerant in the same
    /// sense `naming.zig` makes declaration names insert-tolerant: adding a
    /// contribution at the end of a module appends fields, it does not renumber
    /// them.
    fn planCommon(self: *Gen) Error!void {
        const a = self.arena;
        self.lo_idx = try a.alloc(u32, self.an.nv);
        @memset(self.lo_idx, none_u32);

        var vals: std.ArrayList(Mir.Value) = .empty;
        var mode: proof.FloatMode = .optimized;
        for (self.jobs) |job| {
            // §9.4 the display root stays OUT: the core runs once per `eval`,
            // and printing once per Newton iteration is exactly what
            // `emitDisplay` exists to prevent. It keeps its own declaration and
            // reads the core like the units used to.
            if (job.is_display) continue;
            mode = .strictest(mode, job.mode);
            const v = self.an.rv(job.target);
            if (v == .f_zero) continue; // an operator with no input; rendered inline
            if (self.lo_idx[@intFromEnum(v)] != none_u32) continue;
            self.lo_idx[@intFromEnum(v)] = @intCast(vals.items.len);
            try vals.append(a, v);
        }
        // Path-latch operands ride the same live-out queue: `updateState`'s
        // single core(R) sweep is where their staged values come from.
        {
            var pv: std.ArrayList(Mir.Value) = .empty;
            var pl: std.ArrayList(u32) = .empty;
            var qv: std.ArrayList(Mir.Value) = .empty;
            var ql: std.ArrayList(u32) = .empty;
            for (0..self.mir.insts.len) |ii| {
                const row = self.mir.insts.get(ii);
                if (row.op != .path_prev and row.op != .path_acc) continue;
                const fam_v = if (row.op == .path_prev) &pv else &qv;
                const fam_l = if (row.op == .path_prev) &pl else &ql;
                const v = self.an.rv(@enumFromInt(row.a));
                // ponytail: keep first-seen order with the stdlib membership scan.
                if (std.mem.indexOfScalar(Mir.Value, fam_v.items, v) != null) continue;
                if (self.lo_idx[@intFromEnum(v)] == none_u32) {
                    self.lo_idx[@intFromEnum(v)] = @intCast(vals.items.len);
                    try vals.append(a, v);
                }
                try fam_v.append(a, v);
                try fam_l.append(a, self.lo_idx[@intFromEnum(v)]);
            }
            self.prev_vals = pv.items;
            self.prev_lo = pl.items;
            self.acc_vals = qv.items;
            self.acc_lo = ql.items;
        }
        self.common_mode = mode;
        self.lo_vals = vals.items;
        // §5.10 which core field each held variable's write-back reads. Done
        // here rather than by scanning `jobs` in `emitStateMachine`, because
        // `lo_idx` is only meaningful once every job has been folded in.
        self.held_idx = try a.alloc(u32, self.lower.held_vars.items.len);
        for (self.lower.held_vars.items, 0..) |h, i| {
            const v = self.an.rv(h.final);
            self.held_idx[i] = if (v == .f_zero) none_u32 else self.lo_idx[@intFromEnum(v)];
        }
        if (self.lo_vals.len == 0) return;

        var buf: [naming.max_name_len]u8 = undefined;
        const n = naming.unitName(&buf, self.mir.name, .{
            .role = .common,
            // A single declaration, so the target is a fixed word rather than a
            // key: naming.zig's insert-tolerance is about the NAME not moving,
            // and this one cannot.
            .target = "core",
        }) catch return error.NameTooLong;
        self.common_name = try a.dupe(u8, n);
    }

    // ------------------------------------------- the temperature hoist ----
    //
    // MEASURED MOTIVE (ARPice callgrind, tran/fourbitadder): log 8.2% +
    // pow 6.4% + exp 5.1% + ldexp/frexp ~3% of TOTAL instructions sit inside
    // BJT eval — `pow(t/tnom, xti)`-class factors recomputed per instance per
    // Newton iteration. ngspice computes them once (bjttemp.c) at setup/.temp;
    // the host already has the hook (`precompute` runs at finalize and on
    // every reprep — parameter writes and setTemp both route through it).
    //
    // A value is HOISTABLE when its transitive inputs are only parameters,
    // literals and `$temperature` — no §4.4 probe, no `$abstime`, no stateful
    // operator, no phi (a loop-carried value is not one value) — AND every op
    // on the way down is one the precompute body can re-spell with the exact
    // VALUE semantics the in-eval rendering had (see `pscalar_txt`). A
    // hoist ROOT is such a value, containing at least one libm-class op
    // (anything cheaper is not the measured cost), read at least once from
    // OUTSIDE the hoistable region. Roots become `Instance.pc__<k>` fields.

    /// Three-state memo for `pcClass` — `unknown` doubles as the visit mark.
    const PcCls = enum(u8) { unknown, no, yes };

    /// Is `v0` computable from parameters/literals/`$temperature` alone,
    /// through ops the precompute body can mirror bit-exactly? Fills the memo
    /// at the rv-RESOLVED index. Recursion depth is the expression depth;
    /// the cap is a sound fail-safe (false never hoists).
    fn pcClass(self: *Gen, cls: []PcCls, v0: Mir.Value, depth: u32) bool {
        const v = self.an.rv(v0);
        const i = @intFromEnum(v);
        switch (cls[i]) {
            .yes => return true,
            .no => return false,
            .unknown => {},
        }
        if (depth > 2048) return false;
        const ok: bool = switch (self.mir.valueDef(v)) {
            .undef, .float_const, .int_const => true,
            .str_const, .block_param => false,
            .param_ref => |p| Analysis.tyOfParam(self.lower.params.items[p].ty) != .str,
            .inst_result => |inst| blk: {
                const row = self.mir.instRow(inst);
                switch (row.op) {
                    .call => {
                        const d = self.mir.instData(inst).call;
                        // §9.19's two queries answer from the model card alone:
                        // `renderSysCall` spells `$param_given` as the Model
                        // field `<p>__given` and `$port_connected` as the
                        // literal 1, so both are as parameter-only as a
                        // `param_ref` and precompute can re-spell them
                        // character for character. Excluding them cost the
                        // whole `<dev>temp` phase of every machine-converted
                        // SPICE model: `if ($param_given(tox)) cox = …` guards
                        // the ladder, an unhoistable condition makes the
                        // select unhoistable, and one unhoistable select
                        // strands every value downstream of it in the core.
                        break :blk std.mem.eql(u8, d.name, "$temperature") or
                            std.mem.eql(u8, d.name, "$param_given") or
                            std.mem.eql(u8, d.name, "$port_connected") or
                            (std.mem.eql(u8, d.name, "$vt") and d.args.len == 0);
                    },
                    // A phi is not one value; the path latches read Instance
                    // state `updateState`/commit have not written yet at
                    // precompute time.
                    .phi, .branch, .jump, .path_prev, .path_acc => break :blk false,
                    .select => {
                        const d = self.mir.instData(inst).ternary;
                        break :blk self.pcClass(cls, d.cond, depth + 1) and
                            self.pcClass(cls, d.then_val, depth + 1) and
                            self.pcClass(cls, d.else_val, depth + 1);
                    },
                    else => switch (Mir.opClass(row.op)) {
                        .unary => break :blk self.pcClass(cls, @enumFromInt(row.a), depth + 1),
                        .binary => break :blk self.pcClass(cls, @enumFromInt(row.a), depth + 1) and
                            self.pcClass(cls, @enumFromInt(row.b), depth + 1),
                        else => break :blk false,
                    },
                }
            },
        };
        cls[i] = if (ok) .yes else .no;
        return ok;
    }

    fn libmClass(op: Mir.Opcode) bool {
        return switch (op) {
            .exp, .expm1, .ln, .ln1p, .log10, .pow, .hypot => true,
            .sin, .cos, .tan, .asin, .acos, .atan, .atan2 => true,
            .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => true,
            else => false,
        };
    }

    /// One use of `o` from outside the hoistable region: make it a root if it
    /// qualifies. Ascending value order later turns `root` into `pc_idx`.
    fn pcConsider(self: *Gen, cls: []PcCls, root: []bool, o: Mir.Value) void {
        const v = self.an.rv(o);
        const i = @intFromEnum(v);
        if (cls[i] != .yes) return;
        if (root[i]) return;
        if (self.an.vty[i] != .real) return;
        // A tree that folds to a literal costs nothing per eval already.
        if (self.an.foldConst(v, 0, false) != null) return;
        // ponytail: every non-folding instruction qualifies, so a libm-cost
        // walk cannot change the answer. Add a cost model only if this policy changes.
        if (self.mir.valueDef(v) != .inst_result) return;
        root[i] = true;
    }

    fn planPrecompute(self: *Gen) Error!void {
        const a = self.arena;
        const nv = self.an.nv;
        self.pc_idx = try a.alloc(u32, nv);
        @memset(self.pc_idx, none_u32);

        const cls = try a.alloc(PcCls, nv);
        @memset(cls, .unknown);
        for (0..nv) |i| _ = self.pcClass(cls, @enumFromInt(@as(u32, @intCast(i))), 0);

        const root = try a.alloc(bool, nv);
        @memset(root, false);

        // Every use from a consumer that is NOT itself hoistable marks a root:
        // instruction operands (a branch/call/phi result is never hoistable, so
        // conditions, operator inputs and phi copies are covered by the same
        // rule), plus the unit targets the residual returns.
        for (0..self.mir.insts.len) |ii| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(ii)));
            const res = self.mir.instResult(inst);
            if (res != .undef and cls[@intFromEnum(self.an.rv(res))] == .yes) continue;
            switch (self.mir.instData(inst)) {
                .unary => |d| self.pcConsider(cls, root, d.operand),
                .binary => |d| {
                    self.pcConsider(cls, root, d.lhs);
                    self.pcConsider(cls, root, d.rhs);
                },
                .ternary => |d| {
                    self.pcConsider(cls, root, d.cond);
                    self.pcConsider(cls, root, d.then_val);
                    self.pcConsider(cls, root, d.else_val);
                },
                .branch => |d| self.pcConsider(cls, root, d.cond),
                .call => |d| for (d.args, 0..) |arg, k| {
                    // Control arguments render host-side through `f64Expr`
                    // (never a pc read), so a field for one would go unread.
                    if (callArgIsValue(d.name, k, self.display))
                        self.pcConsider(cls, root, arg);
                },
                .phi => |d| {
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1)
                        self.pcConsider(cls, root, self.mir.phiPair(inst, k).value);
                },
                .jump => {},
            }
        }
        for (self.jobs) |job| {
            // §4.6.4 EXCEPT the noise PSDs. Hoisting one moves it out of the
            // `if (r > 0)` that declared it and evaluates it unconditionally —
            // `4kT/0` — where staying a core live-out gives it the zero seed
            // that is the right answer for a generator this bias does not have.
            // See `buildJobs`'s `$noise` queue.
            if (std.mem.eql(u8, job.name, "$noise")) continue;
            self.pcConsider(cls, root, job.target);
        }

        var vals: std.ArrayList(Mir.Value) = .empty;
        for (0..nv) |i| {
            if (!root[i]) continue;
            self.pc_idx[i] = @intCast(vals.items.len);
            try vals.append(a, @enumFromInt(@as(u32, @intCast(i))));
        }
        self.pc_vals = vals.items;
    }

    // ------------------------------------------ the hoisted core PREFIX ----
    //
    // `planPrecompute` above hoists a value by RE-SPELLING it in a flat
    // `precompute` body, which is why `pcClass` refuses a phi: a value assigned
    // inside an `if` is not one expression, and precompute has no control flow
    // to put it back in. That refusal is expensive far beyond the phi itself —
    // one unhoistable value strands everything downstream of it — and the
    // guards it trips over are the SPICE idiom itself: `$param_given(nsub)`,
    // `js > 0 && ad > 0 && as > 0`, `cbs > 0`, `rd > 0`, `lambda0 != 0`. On
    // mos6 that left 15 solve-independent Duals inside the bias body.
    //
    // This is the other half, and it re-spells nothing. The core's emitted body
    // opens with a PREFIX of top-level statements that reads no §4.4 probe and
    // no per-step Instance state; `precompute` already calls the core once at
    // x = 0 (cg_limit.emitPrep), so that prefix has already run there. Return
    // its live-outs as extra core fields, latch them in `Instance.hp*`, and let
    // every later evaluation jump the region:
    //
    //     if (inst.hp_ok == 0) { …the prefix, verbatim… }
    //     else { h[3] = S.con(inst.hp[0]); … }
    //
    // Nothing about the arithmetic moves — the same statements run, in the same
    // order, on the same inputs; they simply run once. That is why bit-identity
    // is structural here and not a hope, and it is the same claim `pc__`
    // already makes (`precompute` computes in `R`, the core reads `S.con` of
    // the field). Storing an f64 per crossing value is exact for the same
    // reason: a region with no `x[]` read builds every S through `S.con`, so
    // every derivative lane in it is a zero this reload reproduces.
    //
    // Cost is one `Instance` f64 per crossing value plus one predictable
    // branch. Measured on mos6 (`devices/mos6_inverter` biases): 1224.6 →
    // 1164.2 Ir/eval, 0 mismatches over 546 880 values.

    /// May the cached region hold `v`? Everything the region may read must be
    /// fixed between `precompute` and the evaluations that skip it — so this is
    /// `pcClass`'s whitelist (default DENY: an op or a `$name` neither knows is
    /// impure) with two differences that only make sense for a text region.
    ///
    /// A value that is already a STATEMENT stops the walk: it was emitted
    /// earlier and asked this same question then. That is what admits the phi
    /// `pcClass` has to refuse — a phi slot is written by `emitPhiCopies` on
    /// the incoming edges, and those copies are checked as they are emitted.
    /// It also means an impure CONDITION cannot smuggle a bias dependence in
    /// through a pure-looking merge: the branch is an emitted value too, so the
    /// region has already closed before its phi is reached.
    ///
    /// Read-before-written (a loop-carried slot, or one the emitter never
    /// assigns) is pure as well: that read takes the `undefined`/zero seed, and
    /// the seed is emitted above the region.
    fn hpPure(self: *Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 256) return false;
        const v = self.an.rv(v0);
        return switch (self.mir.valueDef(v)) {
            .undef, .float_const, .int_const, .str_const, .param_ref => true,
            .block_param => false, // §4.4 probe: the solve itself
            // The MATERIALIZED shortcut belongs to operands only — asking it of
            // an instruction's own result would answer "yes, it has a slot" and
            // wave the instruction through unread.
            .inst_result => |inst| self.materialized(v) or self.hpPureInst(inst, depth),
        };
    }

    /// The same question about an emitted STATEMENT: its opcode has to be one
    /// the cache may hold, and every operand it renders inline has to be pure.
    fn hpPureInst(self: *Gen, inst: Mir.Inst, depth: u32) bool {
        if (depth > 256) return false;
        const row = self.mir.instRow(inst);
        switch (row.op) {
            .call => {
                const d = self.mir.instData(inst).call;
                return std.mem.eql(u8, d.name, "$temperature") or
                    std.mem.eql(u8, d.name, "$param_given") or
                    std.mem.eql(u8, d.name, "$port_connected") or
                    (std.mem.eql(u8, d.name, "$vt") and d.args.len == 0);
            },
            // `path_prev`/`path_acc` read the §5.6.1.2 latches, which move on
            // every accepted step — the one class of Instance state that looks
            // parameter-only and is not.
            .phi, .branch, .jump, .path_prev, .path_acc => return false,
            .select => {
                const d = self.mir.instData(inst).ternary;
                return self.hpPure(d.cond, depth + 1) and
                    self.hpPure(d.then_val, depth + 1) and
                    self.hpPure(d.else_val, depth + 1);
            },
            else => return switch (Mir.opClass(row.op)) {
                .unary => self.hpPure(@enumFromInt(row.a), depth + 1),
                .binary => self.hpPure(@enumFromInt(row.a), depth + 1) and
                    self.hpPure(@enumFromInt(row.b), depth + 1),
                else => false,
            },
        }
    }

    /// One emitted item's verdict. Once dirty, dirty for the rest of the body:
    /// the region is a text PREFIX, so the first thing it cannot hold ends it.
    fn hpMark(self: *Gen, v: Mir.Value) void {
        if (!self.hp_on or self.hp_dirty) return;
        if (!self.hpPure(v, 0)) self.hp_dirty = true;
    }

    fn hpMarkInst(self: *Gen, inst: Mir.Inst) void {
        if (!self.hp_on or self.hp_dirty) return;
        if (!self.hpPureInst(inst, 0)) self.hp_dirty = true;
    }

    /// A top-level statement boundary — `maybeCut`'s two call sites, which are
    /// the only points where the emitter's depth is 1 and therefore no label,
    /// loop or arm is open. Probing: remember the last clean one. Emitting: open
    /// the guard at the top of the body, close it at the remembered boundary.
    fn hpBoundary(self: *Gen) Error!void {
        if (!self.hp_on or !self.emitting_common) return;
        if (self.probing) {
            if (!self.hp_dirty) {
                self.hp_cut = self.hp_bnd;
                self.hp_off = @intCast(self.out.items.len);
                self.hp_insts = self.oc_insts;
            }
        } else if (self.hp_bnd == 0) {
            self.uses_inst = true;
            try self.ind(1);
            try self.b("if (inst.hp_ok == 0) {{\n", .{});
            self.ind_base += 1;
        } else if (self.hp_bnd == self.hp_cut) {
            self.ind_base -= 1;
            try self.ind(1);
            try self.b("}} else {{\n", .{});
            for (self.hp_vals, 0..) |v, j| {
                const i = @intFromEnum(v);
                try self.ind(2);
                try self.writeSlotRef(i);
                if (self.an.vty[i] == .int)
                    try self.b(" = inst.hpi[{d}];\n", .{j - self.hp_real})
                else
                    try self.b(" = S.con(inst.hp[{d}]);\n", .{j});
            }
            try self.ind(1);
            try self.b("}}\n", .{});
        }
        self.hp_bnd += 1;
    }

    /// Find the region, once, before `emitInstance` needs its width. Runs the
    /// same dry run `emitUnitBody` runs (`probeBody` only appends and rewinds),
    /// under the same plan and float mode, so the boundary count it lands on is
    /// the one the real walk will reach.
    fn planHoistPrefix(self: *Gen) Error!void {
        self.hp_on = false;
        self.hp_vals = &.{};
        self.hp_real = 0;
        // No shared core to cut, or the cuts are already spoken for: the
        // chunked layout puts a FUNCTION boundary at every top-level statement
        // and no `if` may span two of them.
        if (self.lo_vals.len == 0 or self.outline != 0) return;
        for (self.jobs) |job| {
            if (!job.is_display and job.pre_fatal != null) return;
        }
        const save_common = self.emitting_common;
        const save_strict = self.cur_strict;
        defer {
            self.emitting_common = save_common;
            self.cur_strict = save_strict;
        }
        self.emitting_common = true;
        self.cur_strict = self.common_mode == .strict;
        self.plan.display_unit = false;
        self.oc_on = false;
        try self.plan.analyze(.undef, true);
        // Straight-line: no phi to strand, so `pc__` already took everything
        // this could take, and a prefix guard would only add a branch.
        if (self.plan.straight) return;

        self.hp_on = true;
        self.hoist_idx.clearRetainingCapacity();
        try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);
        try self.probeBody(.undef);
        if (self.hp_cut == 0) {
            self.hp_on = false;
            return;
        }
        // Live-out of the region: assigned inside it, read after it. `place`
        // holds one dry run's offsets, and `hp_off` is an offset of that same
        // run — the only coordinate system either is compared in. Emission
        // order (`plan.live`) so the field indices are stable, reals first.
        //
        // `max_def` is the load-bearing half. The seeding call runs the WHOLE
        // core, so what it latches is the slot's value at the RETURN; the else
        // arm needs its value at the CUT. Those agree only when the region
        // holds the slot's last write. A `while` preheader seeding a
        // loop-carried phi is the counter-example that made this a rule rather
        // than a comment: the initial `i = 0` is solve-independent and the loop
        // that overwrites it is not, so caching it replayed the walk's LAST
        // index into its first iteration (annex_e_spice/primitive_{i,v}pwl).
        //
        // Every refusal below leaves `hp_on` false and BOTH of `hp_vals`/
        // `hp_real` at their entry zeros — `emitInstance` sizes `hpi` as
        // `hp_vals.len - hp_real`, so a half-written pair is an integer
        // overflow rather than a missing optimization.
        var vals: std.ArrayList(Mir.Value) = .empty;
        var n_real: u32 = 0;
        for ([_]VTy{ .real, .int }) |want| {
            for (self.plan.live.items) |lv| {
                const i = @intFromEnum(lv);
                if (self.an.vty[i] != want or self.plan.pcHoisted(lv)) continue;
                const s = self.plan.slot[i];
                if (s == none_u32) continue;
                const p = self.place.items[s];
                if (p.defs == 0 or p.def_off >= self.hp_off or p.max_use <= self.hp_off) continue;
                // Written on BOTH sides of the cut: no field can hold two
                // values, and cutting earlier is a search this does not run.
                if (p.max_def > self.hp_off) {
                    self.hp_on = false;
                    return;
                }
                try vals.append(self.arena, lv);
            }
            if (want == .real) n_real = @intCast(vals.items.len);
        }
        // A `[]const u8` has no `Instance` field to live in. Vanishingly rare
        // in a core prefix, and a whole region is not worth a third array.
        for (self.plan.live.items) |lv| {
            const i = @intFromEnum(lv);
            if (self.an.vty[i] != .str or self.plan.slot[i] == none_u32) continue;
            const p = self.place.items[self.plan.slot[i]];
            if (p.defs != 0 and p.def_off < self.hp_off and p.max_use > self.hp_off) {
                self.hp_on = false;
                return;
            }
        }
        // Worth a field? One reload is a load and a store, which is what the
        // cheapest skipped statement costs — so a region has to hold more than
        // two statements per value it hands on before the branch, the fields
        // and the `precompute` stores pay for themselves. Same accounting as
        // `pcConsider`'s, one level up. Zero values is the degenerate case:
        // nothing the region computed outlives it, so skipping it saves
        // nothing and the guard would be pure cost.
        if (vals.items.len == 0 or vals.items.len * 2 >= self.hp_insts) {
            self.hp_on = false;
            return;
        }
        self.hp_vals = vals.items;
        self.hp_real = n_real;
    }

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
    fn ind(self: *Gen, n: u32) Error!void {
        try self.out.appendNTimes(self.gpa, ' ', (n + self.ind_base) * 4);
    }

    // --------------------------------------------------------------- units ----

    fn buildUnits(self: *Gen) Error!void {
        const a = self.arena;
        self.units = naming.enumerateUnits(a, self.mir, self.lower) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.NameTooLong,
        };
        self.unit_names = try a.alloc([]const u8, self.units.len);
        var buf: [naming.max_name_len]u8 = undefined;
        for (self.units, 0..) |u, i| {
            const n = naming.unitName(&buf, self.mir.name, u) catch return error.NameTooLong;
            self.unit_names[i] = try a.dupe(u8, n);
        }
        // The analog-operator units are enumerated by naming.zig with exactly
        // this walk; repeating it maps each stateful `call` back to its unit.
        self.op_unit = try a.alloc(u32, self.mir.insts.len);
        @memset(self.op_unit, none_u32);
        var next = self.lower.contributions.items.len;
        for (0..self.an.nb) |bi| {
            for (self.an.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.mir.instOp(inst) != .call) continue;
                if (opKind(self.mir.instData(inst).call.name) == .none) continue;
                assert(next < self.units.len);
                self.op_unit[@intFromEnum(inst)] = @intCast(next);
                next += 1;
            }
        }
        assert(next == self.units.len);
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

    // =======================================================================
    // File assembly
    // =======================================================================

    fn emitFile(self: *Gen) Error!void {
        const stateful = self.hasStatefulOps();
        const hist = self.usesOp(.absdelay);
        const filt = self.usesOp(.laplace) or self.usesOp(.zi);
        const timer = self.usesOp(.timer);
        // §9.5.3/§9.5.4.2. Set at the call in lowering, because by the time the
        // MIR is sliced into units the formatter's call may sit in any of them.
        const strs = self.lower.uses_str_tasks;
        // §9.21, set at the call for the same reason `strs` is: the lookup may
        // land in any unit once the MIR is sliced.
        const tbl = self.lower.uses_table_model;
        // §9.13, set at the call for the same reason: `lowerRandom` runs long
        // before the MIR is sliced into units.
        const rng = self.lower.uses_rng;
        // §9.5 the descriptor table. `display == .emit` is the second condition
        // and not a convenience: it is the artifact whose host runs the per-point
        // side-effect phase these kernels have to be sequenced in.
        const files = self.display == .emit and self.lower.uses_file_tasks;
        try self.buildPrelude(stateful, hist, filt, timer, strs, tbl, rng, files);
        try self.out.appendSlice(self.gpa, header_txt);
        try self.out.appendSlice(self.gpa, math_txt);
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
        if (self.display == .emit or strs) try self.out.appendSlice(self.gpa, display_txt);
        if (strs) try depublish(self.gpa, &self.out, str_txt);
        if (files) try depublish(self.gpa, &self.out, file_txt);
        if (tbl) try depublish(self.gpa, &self.out, table_txt);
        if (rng) try depublish(self.gpa, &self.out, rng_txt);
        if (self.limits.len != 0) try depublish(self.gpa, &self.out, limit_txt);
        try self.out.appendSlice(self.gpa, "\n");
        // §4.5.15 `limit`/`seed` evaluate the core on a plain solution too, so
        // they need `R` for the same reason `updateState` does. It stays out of
        // `buildPrelude`/`h.zig`: no UNIT body can reach these, because `$limit`
        // renders as the identity inside one. `collapse` reads the core the
        // same way, so it opens `R` too — and so does §4.6.4 `noisePsd`, which
        // is `updateState`'s shape exactly: one value-only core sweep at a
        // state vector the caller hands in.
        // Before `emitDispatchers`: `emitSwitchRow` splits exactly these
        // branches, so the list has to exist before any residual is emitted.
        self.cpairs = try self.collapsePairs();
        const cpairs = self.cpairs;
        if (stateful or cg_limit.needsR(self) or cpairs.len != 0 or self.pathLatches() or
            self.hp_vals.len != 0 or self.noise_rows.len != 0)
        {
            try self.out.appendSlice(self.gpa, rscalar_txt);
            // Pinned to the contract's primitive list, same as tb.zig's
            // Dual/Vec — a primitive added there cannot silently miss R.
            try self.out.appendSlice(self.gpa, "comptime {\n    contract.checkScalar(R);\n}\n\n");
        }

        try self.emitTopology();
        try self.emitModel();
        try self.emitDerive();
        try self.emitInstance();
        // Before `emitUnits`: its `plan.analyze` is the pass that clears the
        // precompute plan's live-set residue (unit_plan.zig's partial reset).
        try self.emitPrecompute();
        const units_from = self.out.items.len;
        try self.emitUnits();
        // Does the CORE (physics units, not the updateState epilogue) read a
        // host-published sim-state Instance field? A GPU host keeps Instance
        // blobs device-resident and republishes t/dt/kind on the HOST copy
        // only, so such a core evals against stale values there — the decl
        // lets it exclude the device (ARPice engine.gpuEligible). Text scan
        // over exactly the unit range: the lowering sites are many (§4.6
        // analysis(), $abstime, ddt/idt/laplace/transition/timer/cross) and
        // every one spells its read `inst.<field>`.
        const units_text = self.out.items[units_from..];
        const reads_dt = blk: { // boundary-aware: `inst.dtemp` must not match
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, units_text, from, "inst.dt")) |at| : (from = at + 1) {
                const nxt = at + "inst.dt".len;
                if (nxt >= units_text.len) break :blk true;
                const c = units_text[nxt];
                if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk true;
            }
            break :blk false;
        };
        const core_reads_simstate = reads_dt or
            std.mem.indexOf(u8, units_text, "inst.analysis_kind") != null or
            std.mem.indexOf(u8, units_text, "inst.abstime") != null or
            std.mem.indexOf(u8, units_text, "inst.is_initial_step") != null or
            std.mem.indexOf(u8, units_text, "inst.is_final_step") != null;
        try self.emitDispatchers();
        try self.emitNoiseTable();
        try self.emitSystfTable();
        // §4.5.2's accepted-step sweep also carries §9.13.1's internal-seed
        // advance, which is the ONLY place a stream may move: a per-iteration draw
        // makes the residual non-deterministic and Newton never converges.
        if (stateful or self.lower.rng_auto_sites != 0 or self.pathLatches()) try self.emitStateMachine();
        try cg_limit.emit(self);
        try self.emitCollapse(cpairs);
        try self.emitNextBreakpoint();
        try self.emitDelays();
        // Lane-parallel permission (see `lane_pinned`): eval/q of this device
        // instantiated with a vector S is exact per lane. The testbench's
        // batch differential check keys on it, and a batching host may.
        if (!self.lane_pinned) try self.w("pub const lane_clean = true;\n\n", .{});
        if (core_reads_simstate) try self.w("pub const core_reads_simstate = true;\n\n", .{});
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
    fn buildPrelude(self: *Gen, stateful: bool, hist: bool, filt: bool, timer: bool, strs: bool, tbl: bool, rng: bool, files: bool) Error!void {
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
        if (self.common_name.len != 0)
            try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.common_name});
        try p.appendSlice(self.arena, "\n");
        self.prelude = p.items;

        var hz: std.ArrayList(u8) = .empty;
        try hz.appendSlice(self.arena, helpers_head_txt);
        try publish(self.arena, &hz, math_txt);
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
    fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, src, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try out.append(gpa, '\n');
            first = false;
            try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
        }
    }

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

    /// Close the byte range of the unit declaration that started at `lo`. The
    /// ranges must TILE (`Output`'s invariant), which is what lets the writer
    /// reconstruct `device.zig` as prologue ++ imports ++ tail.
    fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
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
    fn hasStatefulOps(self: *const Gen) bool {
        if (self.lower.held_vars.items.len != 0) return true;
        for (self.units) |u| {
            if (u.role == .analog_op and opHasState(opKind(u.target))) return true;
        }
        return false;
    }

    fn usesOp(self: *const Gen, k: OpKind) bool {
        for (self.units) |u| {
            if (u.role == .analog_op and opKind(u.target) == k) return true;
        }
        return false;
    }

    /// §1.3.1 nodes / §6.5 ports. `x[i]` in every emitted body indexes exactly
    /// this enum, and ports come first so the host's terminal order is the
    /// module header order.
    fn emitTopology(self: *Gen) Error!void {
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
        if (self.u_names.len > 256) {
            if (self.diags) |bag| try bag.add(
                .codegen,
                .E1003,
                .{},
                "this module needs {d} solver unknowns; the emitted `U` is an enum(u8) and holds 256",
                .{self.u_names.len},
            );
            return error.TooManyUnknowns;
        }
        try self.w("/// Solver unknowns: §6.5 ports first, then §3.6.3 internal nets,\n", .{});
        try self.w("/// then §5.4.2 branch-flow unknowns.\n", .{});
        try self.w("pub const U = enum(u8) {{\n", .{});
        for (self.u_names, 0..) |n, i| {
            const kindc: []const u8 = if (i < self.lower.num_ports) "port" else if (self.isFlowUnknown(@intCast(i))) "branch flow" else "internal";
            try self.w("    {s}, // {s}\n", .{ n, kindc });
        }
        try self.w("}};\n\npub const num_ports: usize = {d};\nconst n_u = contract.nU(Self);\n\n", .{self.lower.num_ports});

        if (self.jac_f32) try self.w(
            \\/// This device permits a single-precision DERIVATIVE half in the
            \\/// host's scalar S. The residual stays f64 — see `--jac-f32`.
            \\/// Permission, not order: a host may take it on one instantiation
            \\/// (its GPU kernel) and decline it on another (its CPU path).
            \\pub const jac_f32 = true;
            \\
            \\
        , .{});
        if (self.jac_f32_host) try self.w(
            \\/// ...and the host should take that permission on its CPU path too,
            \\/// not only where f32 is free. See `--jac-f32-host`.
            \\pub const jac_f32_host = true;
            \\
            \\
        , .{});

        var any_current = false;
        for (0..self.n_u) |i| {
            if (self.isFlowUnknown(@intCast(i))) any_current = true;
        }
        if (any_current) {
            try self.w("pub const u_kinds = [n_u]contract.UnknownKind{{\n", .{});
            for (0..self.n_u) |i| {
                try self.w("    .{s},\n", .{if (self.isFlowUnknown(@intCast(i))) "current" else "voltage"});
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
        for (0..self.n_u) |i| {
            try self.w("    {d},\n", .{self.abstolOf(@intCast(i))});
        }
        try self.w("}};\n\n", .{});
        try self.w(
            \\/// §4.6.1 analysis() / §5.10.2 global events. The host sets this per pass.
            \\pub const AnalysisKind = enum(u8) {{ static, ic, nodeset, dc, tran, ac, noise }};
            \\
            \\
        , .{});
    }

    /// §1.3.4/§3.6.2.2. Returns the name of the contribution's net when that
    /// net is a SIGNAL-FLOW PORT: a directional (`input`/`output`, §6.5.2.2)
    /// port whose discipline binds only one nature. That combination is the
    /// LRM's unambiguous signal-flow port, and it has no conserved pair for a
    /// nodal device to stamp.
    ///
    /// A single-nature discipline on an `inout` port is NOT caught here, and no
    /// longer can be: §1.3.4.1/§1.3.4.2 forbid that binding outright and
    /// lower.zig rejects it at the declaration (E0132). An internal net is not
    /// caught either — it is a conservative-shaped declaration whose net simply
    /// has one tolerance, which the device stamps as usual (§3.9).
    ///
    /// §1.3.4.2's flow-only net is the one case the ordinary nodal stamp gets
    /// WRONG. On such a net there is no potential (§1.3.4: "Potential for such
    /// a node is not defined"), so the node's single unknown carries the FLOW,
    /// and `I(out) <+ e` is the equation `x[out] − e = 0`, not a KCL injection
    /// into a conservation law the net does not obey. §1.3.4.1's potential-only
    /// net needs nothing special: the ordinary branch relation already reduces
    /// to it — the KCL row at the net is `ib = 0` (a signal-flow net has no
    /// flow to conserve, and zero is what the clause says it is), which leaves
    /// the branch row `V(out) − e = 0` to fix the potential.
    fn flowOnlySignalFlowNet(self: *const Gen, c: Lower.Contribution) ?u16 {
        if (c.access != .flow or c.kind != .direct) return null;
        for ([_]u16{ c.hi, c.lo }) |n| {
            if (n >= self.lower.node_order.items.len) continue; // ground
            switch (self.lower.node_dir.items[n]) {
                .input, .output => {},
                else => continue,
            }
            const dname = self.lower.node_disciplines.items[n];
            if (dname.len == 0) continue;
            const d = self.lower.disciplines.get(dname) orelse continue;
            if (!d.has_potential and d.has_flow) return n;
        }
        return null;
    }

    pub fn isFlowUnknown(self: *const Gen, i: u32) bool {
        if (i >= self.lower.node_order.items.len) return true; // codegen-added branch current
        // §5.4.2/§5.4.3. An array read: lowering records the kind where it
        // creates the slot. It used to be `startsWith("flow(")`, which §2.8.1
        // makes a lie — a net declared `\flow(p,n)` IS the identifier
        // `flow(p,n)` and was classified as a current.
        if (self.lower.node_kind.items[i] != .net) return true;
        // §1.3.4.2 a flow signal-flow net has no potential ("Potential for such
        // a node is not defined"), so its ONE unknown is a flow even though it
        // is a plain node with a plain name. Everything that asks this question
        // — the host's `u_kinds`, the §3.6.1.2 tolerance, §4.5.15's refusal to
        // `$limit` a current — wants the quantity, not the spelling.
        const dname = self.lower.node_disciplines.items[i];
        if (dname.len == 0) return false;
        const d = self.lower.disciplines.get(dname) orelse return false;
        return d.has_flow and !d.has_potential;
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
    fn abstolOf(self: *const Gen, i: u32) f64 {
        const flow = self.isFlowUnknown(i);
        var idx: u16 = @intCast(i);
        if (i < self.lower.node_kind.items.len) switch (self.lower.node_kind.items[i]) {
            .net => {},
            .branch_flow, .port_flow => |n| idx = n,
        };
        if (idx == Lower.ground or idx >= self.lower.node_disciplines.items.len)
            return if (flow) 1e-12 else 1e-6;
        const info = self.lower.disciplines.get(self.lower.node_disciplines.items[idx]) orelse
            return if (flow) 1e-12 else 1e-6;
        return if (flow) info.flow_abstol else info.potential_abstol;
    }

    /// §3.4 parameters. One field, typed, with the constant-folded spec default.
    fn emitModel(self: *Gen) Error!void {
        try self.w("/// §3.4 module parameters (spec defaults folded at compile time).\npub const Model = struct {{\n", .{});
        for (self.lower.params.items, 0..) |p, i| {
            const ty: []const u8 = switch (Analysis.tyOfParam(p.ty)) {
                .real => "f64",
                .int => "i64",
                .str => "[]const u8",
            };
            try self.checkParamDefault(p);
            try self.w("    {s}: {s} = {s},\n", .{ self.p_names[i], ty, try self.paramDefault(p, Analysis.tyOfParam(p.ty)) });
            if (self.p_given[i]) {
                try self.w("    {s}__given: bool = false, // §9.19 $param_given\n", .{self.p_names[i]});
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
        for (self.lower.aliases.items, 0..) |al, i| {
            const p = self.lower.params.items[al.param];
            const ty = Analysis.tyOfParam(p.ty);
            try self.w("    {s}: {s} = {s}, // §3.4.7 alias of `{s}`\n", .{
                self.a_names[i],
                switch (ty) {
                    .real => "f64",
                    .int => "i64",
                    .str => "[]const u8",
                },
                try self.paramDefault(p, ty),
                p.name,
            });
            try self.w("    {s}__given: bool = false,\n", .{self.a_names[i]});
        }
        // §9.15 the host-published nominal temperature this module reads.
        // Model, not Instance: `.options tnom` is one number per RUN, so an
        // Instance copy would replicate a global across every instance of
        // every batch for a value `derive()` reads once at build. The
        // initializer is Table 9-27's default, so `Model{}` is unchanged for a
        // host that never writes it.
        if (self.uses_nom_temp) try self.w(
            "    {s}: f64 = {s}, // §9.15 $simparam(\"tnom\"), degC — host-written\n",
            .{ Lower.simparamHostField("tnom").?, try self.fmtF64(self.lower.simparamValue("tnom").?) },
        );
        if (self.lower.params.items.len == 0 and !self.uses_nom_temp) {
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
    fn emitDerive(self: *Gen) Error!void {
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
        for (self.lower.aliases.items, 0..) |al, i| {
            try self.w("    if (model.{s}__given) model.{s} = model.{s};\n", .{
                self.a_names[i], self.p_names[al.param], self.a_names[i],
            });
        }
        for (self.lower.params.items, 0..) |p, i| {
            const ty = Analysis.tyOfParam(p.ty);
            // A string parameter has no arithmetic to redo; a string localparam
            // is left overridable rather than growing a second renderer for it.
            if (ty == .str) continue;
            // `resolve_params = false` ⇒ this folds only if the default is
            // self-contained, which is exactly "not derived from a parameter".
            if (self.an.foldConst(p.default, 0, false) != null and !p.is_local) continue;
            // Not renderable in the host's f64 domain (a default over an op
            // `f64Const` does not carry): leave the folded field initializer, as
            // before. Widening the op set there is the fix if a model asks.
            const e = try self.f64Const(p.default, 0, false) orelse continue;
            // §6.3.4 gives the DEFAULT; an explicit host write wins. Only a
            // localparam is overwritten unconditionally ("shall not be
            // directly modified"). Unguarded, BSIMSOI's `VTH0 = VTHO` erased
            // every card VTH0 back to VTHO's default. `initGiven` raised the
            // `__given` companion for every non-local derived parameter.
            if (!p.is_local)
                try self.w("    if (!model.{s}__given) ", .{self.p_names[i]})
            else
                try self.w("    ", .{});
            switch (ty) {
                .real => try self.w("model.{s} = {s};\n", .{ self.p_names[i], e }),
                // §3.2's 32-bit result (`Lower.wrap32`) applied once, at the end.
                // For +, - and * that is not an approximation: those three are
                // the ring Z/2^32, so reducing after the whole expression is the
                // same value as reducing at every step, which is what the fold
                // and the device do. The ceiling is that `f64Const` renders the
                // arithmetic in f64, so a chain whose INTERMEDIATE leaves 2^53,
                // or one that wraps around a `/`, does not agree with them; a
                // derived integer parameter needs its own int-typed renderer for
                // that, and no model has asked.
                // `lossyCast`, not `@intFromFloat`: `derive()` runs in the
                // HOST on card values this compiler never saw, and a huge or
                // NaN default expression is then runtime UB (ReleaseFast) or a
                // panic (Debug). Saturate-then-wrap is the fold's own rule
                // (`Analysis.asI64` + `Lower.wrap32`), so both agree.
                .int => try self.w("model.{s} = @as(i32, @truncate(std.math.lossyCast(i64, @round({s}))));\n", .{ self.p_names[i], e }),
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
    fn checkParamDefault(self: *Gen, p: Lower.ParamInfo) Error!void {
        const bag = self.diags orelse return;
        if (!bag.enabled(.W1050)) return;
        if (p.folded != null or self.an.foldConst(p.default, 0, true) != null) return;
        if (try self.f64Const(p.default, 0, false) != null) return;
        var d = bag.build(.codegen, .W1050, self.lower.tokenSpan(p.tok));
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
    /// carries its result here. The MIR fold runs first, so the two agree
    /// wherever both can answer and only the residue reaches the second.
    fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
        const c = self.an.foldConst(p.default, 0, true);
        if (c == null) if (p.folded) |k| return switch (want) {
            .real => try self.fmtF64(k.asReal()),
            // From the i64 side rather than through the f64 carrier: `folded`
            // kept the integer, so nothing has to be rounded back out of it.
            // A REAL default on an integer parameter goes through the same
            // saturating cast as the fold path below — `Lower.Const.asInt`
            // casts unguarded, and lower.zig is not this file's to change.
            .int => try std.fmt.allocPrint(self.arena, "{d}", .{switch (k) {
                .real => |r| std.math.lossyCast(i64, @round(r)),
                else => k.asInt(),
            }}),
            .str => switch (k) {
                .str => |s| try std.fmt.allocPrint(self.arena, "\"{f}\"", .{std.zig.fmtString(s)}),
                else => "\"\"",
            },
        };
        return switch (want) {
            .real => try self.fmtF64(if (c) |k| k.f else 0.0),
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

    /// Per-instance state: environment (§9.10) plus one field group per
    /// stateful §4.5 operator, KEYED BY THE STABLE UNIT NAME so adding an
    /// unrelated operator never renumbers existing state.
    fn emitInstance(self: *Gen) Error!void {
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
        // §9.13.1's "internal seed", one slot per seedless call site. The
        // DEFAULT is the seed "the simulator picks" — a fixed value, not a clock
        // read, because §9.13.2's "shall always return the same value given the
        // same seed" is only checkable if a run is reproducible, and a device
        // whose numbers move between two identical runs cannot be debugged.
        // Distinct per site: §9.13.1 says the internal seed "gets updated every
        // time the call ... is made", so two call sites are two streams.
        if (self.lower.rng_auto_sites != 0) {
            try self.w(
                "    /// §9.13.1 the internal seed of each seedless `$random`/`$arandom`\n" ++
                    "    /// call site. Advanced by `updateState` on the ACCEPTED step and only\n" ++
                    "    /// READ by `eval`: a draw that moved between Newton iterations would\n" ++
                    "    /// make the residual non-deterministic and the solve would not converge.\n" ++
                    "    rng_auto: [{d}]i64 = .{{", .{self.lower.rng_auto_sites},
            );
            for (0..self.lower.rng_auto_sites) |k| try self.w("{s}{d}", .{
                if (k == 0) "" else ", ", 1 + 7919 * @as(u32, @intCast(k)),
            });
            try self.w("}},\n", .{});
        }
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const n = self.unit_names[i];
            switch (opKind(u.target)) {
                .ddt, .slew => try self.w("    {s}__prev: f64 = 0.0, // §4.5\n", .{n}),
                // §4.5.8 the ORIGIN of the ramp in progress: the level the
                // output left, and the time it left it. Not "the previous
                // output" — that is the whole difference between a piecewise
                // LINEAR traversal of the excursion and an exponential one.
                // Re-armed by `zTransStep` only once the output has caught up
                // with its input, so a ramp spanning several timesteps keeps
                // counting from where it actually started.
                .transition => try self.w(
                    "    {s}__from: f64 = 0.0, // §4.5.8 ramp origin (value, time)\n    {s}__t0: f64 = 0.0,\n",
                    .{ n, n },
                ),
                .idt, .idtmod => try self.w("    {s}__acc: f64 = 0.0, // §4.5.4\n", .{n}),
                .absdelay => try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u32 = 0,\n",
                    .{ n, hist_len, n, hist_len, n },
                ),
                .last_crossing => try self.w("    {s}__prev: f64 = 0.0, // §4.5.10\n    {s}__t_last: f64 = -1.0,\n", .{ n, n }),
                // §5.10.3 the history the event test compares against, and
                // nothing else: there is no `__hit` flag any more, because a
                // flag written on the accepted step is a flag read one timepoint
                // after the event (see `emitOperator`).
                .cross => try self.w("    {s}__prev: f64 = 0.0, // §5.10.3\n", .{n}),
                // §5.10.3.2 the same history, and the 0.0 initialiser is not a
                // placeholder — it IS the clause's initialisation rule. "If the
                // expression is positive at the conclusion of the initial
                // condition analysis that precedes a transient analysis, the
                // above() function shall generate an event": with `__prev` at
                // zero the ordinary "was ≤ 0, is now > 0" test fires on exactly
                // that first positive evaluation, so the special case needs no
                // code of its own.
                .above => try self.w("    {s}__prev: f64 = 0.0, // §5.10.3.2\n", .{n}),
                .timer => try self.w("    {s}__next: f64 = 0.0, // §5.10.3\n", .{n}),
                // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
                // past inputs and past outputs per section, newest first. The
                // SHAPE is structural (it comes from the flattened call), which
                // is what keeps it a codegen-time constant even though every
                // coefficient VALUE is a runtime read of Model.
                .laplace, .zi => {
                    const p = try cg_filters.filterPlan(self, self.opInstOf(@intCast(i)) orelse continue, self.opArgs(i));
                    if (p.err != null) continue;
                    try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                        n, p.ns * p.deg, if (opKind(u.target) == .zi) "12" else "11",
                    });
                    try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                    if (opKind(u.target) == .zi) try self.w(
                        "    {s}__next: f64 = 0.0, // §4.5.12 next sample time\n    {s}__out: f64 = 0.0,\n",
                        .{ n, n },
                    );
                },
                // §9.17 writes the two unconditional fields above, not a
                // per-unit one.
                .none, .bound_step, .discontinuity => {},
            }
        }
        // §5.6.1.2 path-integrated reactive latches (ngspice NIintegrate
        // semantics, mesaload.c:341-344): pb__k = ddt operand at the last
        // ACCEPTED solve, pq__k = Σ committed A·ΔB increments — the charge
        // base, FIXED across one Newton attempt. wb__/wq__ stage the current
        // iterate's values (updateState); stateCtl(.commit) latches them.
        // Zero defaults make the first committed increment A·(B−0) = A·B —
        // exactly ngspice MODEINITTRAN's qgs = capgs·vgs product seeding.
        for (0..self.prev_lo.len) |k| {
            try self.w("    pb__{d}: f64 = 0.0, // path_prev latch\n    wb__{d}: f64 = 0.0, // staged\n", .{ k, k });
        }
        for (0..self.acc_lo.len) |k| {
            try self.w("    pq__{d}: f64 = 0.0, // path_acc latch\n    wq__{d}: f64 = 0.0, // staged\n", .{ k, k });
        }
        // §5.10 event-assigned variables. LAST, so a model that gains one does
        // not move a single operator field, and the default is the DECLARED
        // initializer — the only evaluation that can observe it is the first,
        // before `updateState` has ever run.
        for (self.lower.held_vars.items, 0..) |h, i| {
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
                    self.held_names[i], std.math.lossyCast(i64, @round(v)),
                });
            } else {
                try self.w("    {s}: f64 = {s}, // §5.10 held across evaluations\n", .{
                    self.held_names[i], try self.fmtF64(v),
                });
            }
        }
        // FSM accepted/working twins — `stateCtl`'s accepted copy. Emitted
        // only for modules whose hook has an FSM half (`fsmStateCtl`), so a
        // plain cross-observer — or a path-latch model — carries no dead
        // fields.
        if (self.fsmStateCtl()) {
            for (self.lower.held_vars.items, 0..) |h, i| {
                const init = self.an.foldConst(self.an.rv(h.init), 0, true);
                const v: f64 = if (init) |c| c.f else 0.0;
                if (h.ty == .integer) {
                    try self.w("    {s}__acc: i64 = {d}, // stateCtl accepted copy\n", .{
                        self.held_names[i], std.math.lossyCast(i64, @round(v)),
                    });
                } else {
                    try self.w("    {s}__acc: f64 = {s}, // stateCtl accepted copy\n", .{
                        self.held_names[i], try self.fmtF64(v),
                    });
                }
            }
            for (self.units, 0..) |u, i| {
                if (u.role != .analog_op) continue;
                switch (opKind(u.target)) {
                    .cross, .above => try self.w(
                        "    {s}__prev__acc: f64 = 0.0, // stateCtl accepted copy\n",
                        .{self.unit_names[i]},
                    ),
                    else => {},
                }
            }
        }
        // Temperature/parameter-only prep, hoisted out of the per-eval path:
        // `precompute` writes these once per model-card/temperature write.
        // LAST, for the same insert-tolerance reason as the held block above.
        for (0..self.pc_vals.len) |k| {
            try self.w("    pc__{d}: f64 = 0.0, // precompute\n", .{k});
        }
        // §4.5.15 the solve-independent clamp arguments, latched by
        // `cg_limit.emitPrep` off the same `precompute` call. After `pc__`
        // because `emitPrep`'s core evaluation READS those fields.
        for (0..self.lp_vals.len) |k| {
            try self.w("    lp__{d}: f64 = 0.0, // $limit prep\n", .{k});
        }
        // The core's hoisted PREFIX (`planHoistPrefix`): the solve-independent
        // opening of the shared body, latched off the same `precompute` core
        // call the `lp__` fields ride. `hp_ok` is what the core tests, so it is
        // cleared on entry to `precompute` and set only once the values behind
        // it belong to the model card now in force.
        if (self.hp_real != 0) try self.w("    hp: [{d}]f64 = @splat(0.0), // core prefix cache\n", .{self.hp_real});
        if (self.hp_vals.len != self.hp_real)
            try self.w("    hpi: [{d}]i64 = @splat(0),\n", .{self.hp_vals.len - self.hp_real});
        if (self.hp_vals.len != 0) try self.w("    hp_ok: i64 = 0,\n", .{});
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
    fn emitPrecompute(self: *Gen) Error!void {
        // §4.5.15's clamp-argument latch rides in this same function — it is the
        // same "once per model-card/temperature write" phase — so a model with
        // no `pc__` roots but a hoisted clamp argument still needs the body.
        const has_pc = self.pc_vals.len != 0;
        const has_lp = self.lp_vals.len != 0;
        // …and so does the core's hoisted prefix, off the same core call.
        const has_hp = self.hp_vals.len != 0;
        if (!has_pc and !has_lp and !has_hp) return;
        if (has_pc) try self.out.appendSlice(self.gpa, pscalar_txt);

        // Plan the pc slice through the common-mode path: targets = pc_vals.
        // Skipped wholesale when there are none: `analyze` would clear the
        // live set for an empty target list and the `defer` would hand the
        // units back a `pc_on = true` that `planUnits` never set.
        const save_idx = self.plan.lo_idx;
        const save_vals = self.plan.lo_vals;
        if (has_pc) {
            self.plan.lo_idx = self.pc_idx;
            self.plan.lo_vals = self.pc_vals;
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
        try self.w("    @setFloatMode(.{t});\n", .{self.common_mode});
        if (has_pc) try self.w("    const S = P;\n", .{});
        self.cur_strict = self.common_mode == .strict;
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
                    try self.w("    const t{d}: {s} = ", .{ self.plan.slot[i], zigTy(self.an.vty[i]) });
                    try self.renderInst(inst);
                    try self.w(";\n", .{});
                }
            }
            for (self.pc_vals, 0..) |v, k| {
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
            // `emitPrep` already evaluated the core at x = 0 and called it `m`;
            // without it, the same two lines. Either way this is the ONE
            // evaluation of the prefix per model card, and `hp_ok` is still 0
            // for it — which is what makes the region run rather than reload.
            if (!has_lp) try self.w(
                \\    var xr: [n_u]R = undefined;
                \\    for (&xr) |*p| p.* = R.con(0.0);
                \\    const m = core(R, xr, model, inst);
                \\
            , .{});
            for (self.hp_vals, 0..) |v, j| {
                const f = self.lo_vals.len + j;
                if (self.an.vty[@intFromEnum(v)] == .int)
                    try self.w("    inst.hpi[{d}] = m.f{d};\n", .{ j - self.hp_real, f })
                else
                    try self.w("    inst.hp[{d}] = m.f{d}.v;\n", .{ j, f });
            }
            try self.w("    inst.hp_ok = 1;\n", .{});
        }
        if (has_lp or has_hp) self.uses_model = true;
        if (!self.uses_model) self.patchParam(at_model, "model".len);
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
    fn fsmStateCtl(self: *const Gen) bool {
        if (self.lower.held_vars.items.len == 0) return false;
        for (self.units) |u| {
            if (u.role != .analog_op) continue;
            switch (opKind(u.target)) {
                .cross, .above => return true,
                else => {},
            }
        }
        return false;
    }

    /// Any path latch at all. The reactive lowering always plants prev+acc
    /// pairs, but a source-level `$prev` site arrives alone — every gate that
    /// keys the latch machinery (R text, state machine, core sweep, stateCtl)
    /// tests this, not `acc_lo`, so a `$prev`-only model still gets its
    /// updateState staging and commit advance.
    fn pathLatches(self: *const Gen) bool {
        return self.acc_lo.len != 0 or self.prev_lo.len != 0;
    }

    /// §5.6.1.2 path-integrated reactive sites also ride `stateCtl`: the
    /// driver's existing `.commit` calls (operating-point exit, transient
    /// accepted step) are exactly the accepted-solve boundary the latches
    /// advance on. They contribute nothing to `query` — the base moving is
    /// the integrator's business, not a step-reject condition.
    fn emitsStateCtl(self: *const Gen) bool {
        return self.fsmStateCtl() or self.pathLatches();
    }

    /// The hook body. `query` compares the HELD (discrete) state only; the
    /// continuous cross histories are committed/reverted alongside so a
    /// rejected attempt cannot leave a half-advanced edge test behind (which
    /// would suppress the refire on the retry). Path latches commit `pb = wb`,
    /// `pq += wq` (and zero `wq` so a commit with no fresh `updateState`
    /// adds 0); on revert they need nothing — the base was never written
    /// speculatively. Tag ORDER mirrors contract.StateCtlOp — the engine
    /// converts by ordinal.
    fn emitStateCtl(self: *Gen) Error!void {
        // ponytail: topology is fixed during emission; scan once for all three actions.
        const fsm = self.fsmStateCtl();
        try self.w(
            \\pub fn stateCtl(_: *const Model, inst: *Instance, _: *State, op: contract.StateCtlOp) bool {{
            \\    if (op == .query) {{
            \\        return
        , .{});
        var first = true;
        for (self.held_names) |n| {
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
        for (0..self.prev_lo.len) |k| try self.w("        inst.pb__{d} = inst.wb__{d};\n", .{ k, k });
        for (0..self.acc_lo.len) |k| try self.w("        inst.pq__{d} += inst.wq__{d};\n        inst.wq__{d} = 0.0;\n", .{ k, k, k });
        if (fsm) for (self.held_names) |n| try self.w("        inst.{s}__acc = inst.{s};\n", .{ n, n });
        for (self.units, 0..) |u, i| {
            if (!fsm) break;
            if (u.role != .analog_op) continue;
            switch (opKind(u.target)) {
                .cross, .above => try self.w("        inst.{s}__prev__acc = inst.{s}__prev;\n", .{ self.unit_names[i], self.unit_names[i] }),
                else => {},
            }
        }
        try self.w("    }} else {{\n", .{});
        if (fsm) for (self.held_names) |n| try self.w("        inst.{s} = inst.{s}__acc;\n", .{ n, n });
        for (self.units, 0..) |u, i| {
            if (!fsm) break;
            if (u.role != .analog_op) continue;
            switch (opKind(u.target)) {
                .cross, .above => try self.w("        inst.{s}__prev = inst.{s}__prev__acc;\n", .{ self.unit_names[i], self.unit_names[i] }),
                else => {},
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

    // =======================================================================
    // Units
    // =======================================================================

    /// One emitted unit function, resolved BEFORE anything is written.
    ///
    /// `planCommon` has to know the exact set of units and their targets in
    /// order to count how many of them share a value, and `emitUnits` has to
    /// emit exactly that set — a disagreement between the two would leave a
    /// value rendered as a cache read in a unit whose slice was never counted.
    /// One list, built once, walked twice.
    const Job = struct {
        name: []const u8,
        target: Mir.Value,
        mode: proof.FloatMode,
        comment: []const u8,
        /// §3.6.2.2 refusal seeded from the unit's DECLARATION (`Gen.pre_fatal`).
        pre_fatal: ?[]const u8 = null,
        /// Index into `units` for an analog-operator job whose §4.5.11/§4.5.12
        /// coefficient reader is emitted right after it; `none_u32` otherwise.
        sec_of: u32 = none_u32,
        /// §9.4: the one job that is NOT folded into the core, because its body
        /// has side effects the residual must not trigger. See `planCommon`.
        is_display: bool = false,
    };

    fn unitMode(self: *const Gen, i: usize) proof.FloatMode {
        // proof.zig rates the CONTRIBUTION units only (proof.unitCount ==
        // lower.contributions.len); an analog-operator unit is not covered, so
        // it takes the safe side.
        if (i >= self.verdict.unit_modes.len) return .strict;
        return self.verdict.unit_modes[i];
    }

    /// §5.6.1.3 what is known STATICALLY about a `.direct` contribution's
    /// retention this cycle, read off `Lower.Contribution.wrote_val`.
    const Retention = union(enum) {
        /// The flag folded to 1.0: a value is retained on every path. Today's
        /// static row, byte-identical — the common unconditional case.
        on,
        /// Folded to 0.0: discarded on every path (§5.6.1.3's unconditional
        /// replacement). The accumulators folded to `.f_zero` with it, so no
        /// row is emitted — exactly as before the flag existed.
        off,
        /// A phi: which quantity the branch retains is a property of the
        /// CYCLE'S EXECUTION PATH, so the branch row's CONTENT is selected at
        /// run time on this flag (carried as a core field).
        runtime: Mir.Value,
    };

    fn retention(self: *const Gen, c: Lower.Contribution) Retention {
        const v = self.an.rv(c.wrote_val);
        return switch (self.mir.valueDef(v)) {
            .float_const => |x| if (x != 0.0) Retention.on else Retention.off,
            .int_const => |x| if (x != 0) Retention.on else Retention.off,
            else => .{ .runtime = v },
        };
    }

    /// The §5.6.5 switch-branch partner of potential contribution `pi`: the one
    /// `.flow` direct entry over the same (hi, lo, branch), or null.
    /// `contribIndex` dedupes per (access, pair, branch), so there is at most
    /// one. ponytail: O(n) scan per potential entry; contributions per module
    /// are tens, same order as `uIsDriven`'s existing scan.
    fn switchFlowOf(self: *const Gen, pi: usize) ?usize {
        const p = self.lower.contributions.items[pi];
        for (self.lower.contributions.items, 0..) |c, j| {
            if (j == pi or c.kind != .direct or c.access != .flow) continue;
            if (c.hi == p.hi and c.lo == p.lo and c.br == p.br) return j;
        }
        return null;
    }

    /// Is flow entry `j` consumed by a RUNTIME-selected potential row over the
    /// same branch? Then its retained value reaches KCL through the branch
    /// unknown (row `I_b − value`, stamps ±I_b), and stamping it here as well
    /// would inject the current twice.
    fn flowIsMerged(self: *const Gen, j: usize) bool {
        const f = self.lower.contributions.items[j];
        if (f.kind != .direct or f.access != .flow) return false;
        for (self.lower.contributions.items) |c| {
            if (c.kind != .direct or c.access != .potential) continue;
            if (c.hi != f.hi or c.lo != f.lo or c.br != f.br) continue;
            return self.retention(c) == .runtime;
        }
        return false;
    }

    /// One row of `noise_gens` AND of the `noisePsd` result — the two tables
    /// are positional in each other (`PsdTerm` k belongs to `noise_gens[k]`),
    /// so they are built once here rather than by two loops that could drift.
    const NoiseRow = struct {
        row: u16,
        col: u16,
        kind: Lower.NoiseKind,
        source: usize,
        /// §4.6.4.1/.2 the PSD itself: `S(f) = pwr` for white, `pwr/f^exp` for
        /// flicker. rv-resolved, so `.f_zero` means "no generator at this bias".
        pwr: Mir.Value,
        exp: Mir.Value,
    };

    /// Flatten every contribution's generator set into `noise_rows`, in the
    /// order `noise_gens` declares them. §4.6.4.6's shared-generator identity
    /// (`NoiseSrc.id`) is renamed densely in first-seen order on the way.
    fn planNoise(self: *Gen) Error!void {
        var rows: std.ArrayList(NoiseRow) = .empty;
        var ids: std.ArrayList(u32) = .empty;
        for (self.lower.contributions.items) |c| {
            // §1.3.1.1 ground is not an unknown: a to-ground generator is
            // spelled row == col, and one on ground-ground has neither.
            if (c.hi == Lower.ground and c.lo == Lower.ground) continue;
            const row = if (c.hi != Lower.ground) c.hi else c.lo;
            const col = if (c.lo != Lower.ground) c.lo else row;
            for (c.noise_srcs) |s| {
                const sid = for (ids.items, 0..) |v, i| {
                    if (v == s.id) break i;
                } else blk: {
                    try ids.append(self.arena, s.id);
                    break :blk ids.items.len - 1;
                };
                try rows.append(self.arena, .{
                    .row = row,
                    .col = col,
                    .kind = s.kind,
                    .source = sid,
                    .pwr = self.an.rv(s.pwr),
                    .exp = self.an.rv(s.exp),
                });
            }
        }
        self.noise_rows = rows.items;
    }

    fn buildJobs(self: *Gen) Error!void {
        var jobs: std.ArrayList(Job) = .empty;
        for (self.lower.contributions.items, 0..) |c, i| {
            const mode = self.unitMode(i);
            const resist = self.an.rv(c.resist_val);
            const react = self.an.rv(c.react_val);
            if (resist != .f_zero) try jobs.append(self.arena, .{
                .name = self.unit_names[i],
                .target = resist,
                .mode = mode,
                .comment = unitComment(c, false),
            });
            if (react != .f_zero) try jobs.append(self.arena, .{
                .name = try std.fmt.allocPrint(self.arena, "{s}__q", .{self.unit_names[i]}),
                .target = react,
                .mode = mode,
                .comment = unitComment(c, true),
            });
        }
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            const args = self.mir.instData(inst).call.args;
            const k = opKind(u.target);
            try jobs.append(self.arena, .{
                .name = self.unit_names[i],
                .target = if (args.len == 0) Mir.Value.f_zero else self.an.rv(args[0]),
                .mode = self.unitMode(i),
                .comment = switch (k) {
                    .bound_step, .discontinuity => "§9.17 analog kernel control request",
                    else => "§4.5 analog operator input",
                },
                .sec_of = if (k == .laplace or k == .zi) @intCast(i) else none_u32,
            });
        }
        // §5.10 the end-of-block value of every held variable, so `updateState`
        // can store it back. Queued AFTER the operator inputs and before the
        // §9.4 display job for the same insert-tolerance reason: a model that
        // gains a held variable appends a core field, it renumbers none.
        //
        // `.strict` unconditionally: proof.zig rates contributions only.
        for (self.lower.held_vars.items, 0..) |h, i| {
            try jobs.append(self.arena, .{
                .name = self.held_names[i],
                .target = self.an.rv(h.final),
                .mode = .strict,
                .comment = "§5.10 event-assigned variable, held across evaluations",
            });
        }
        // §4.5.15 the arguments of every honoured `$limit`, so `limit` can read
        // them out of the core instead of re-deriving the temperature prelude.
        // Queued after the held variables and before the §9.4 display job for
        // the same insert-tolerance reason: a model that gains a `$limit`
        // appends core fields, it renumbers none.
        for (self.limits) |lc| {
            for ([_]Mir.Value{ lc.argv[0], lc.argv[1], lc.sign }) |v| {
                if (v == .f_zero) continue;
                try jobs.append(self.arena, .{
                    // Only the §9.4 display job is emitted as a declaration of
                    // its own (see `emitUnits`); every other job exists to put
                    // its target in the core, so this name is never written.
                    .name = "$limit",
                    .target = v,
                    .mode = .strict,
                    .comment = "§4.5.15 $limit algorithm argument",
                });
            }
        }
        // §5.6.1.3 the retention flags of every runtime-selected branch row
        // (see `Retention.runtime`), so `emitResidual` can read them as core
        // fields. Queued after the limit arguments and before the §9.4 display
        // job for the same insert-tolerance reason as both neighbours — and a
        // module whose every potential contribution is unconditional queues
        // NOTHING here, so its core fields do not move. Like the `$limit`
        // arguments, these jobs exist to put a value in the core; the name is
        // never written.
        for (self.lower.contributions.items, 0..) |c, i| {
            if (c.kind != .direct or c.access != .potential) continue;
            const ret = self.retention(c);
            if (ret != .runtime) continue;
            try jobs.append(self.arena, .{
                .name = "$retained",
                .target = ret.runtime,
                .mode = self.unitMode(i),
                .comment = "§5.6.1.3 retention flag",
            });
            if (self.switchFlowOf(i)) |j| {
                const fret = self.retention(self.lower.contributions.items[j]);
                if (fret == .runtime) try jobs.append(self.arena, .{
                    .name = "$retained",
                    .target = fret.runtime,
                    .mode = self.unitMode(j),
                    .comment = "§5.6.1.3 retention flag",
                });
            }
        }
        // §4.6.4 the PSD argument of every noise generator, so `noisePsd` can
        // read the model's OWN expression out of the core instead of a host
        // guessing it back off the Jacobian. Queued after the retention flags
        // and before the §9.4 display job for the same insert-tolerance reason
        // as every neighbour.
        //
        // The POWER is always routed through the core, even when it folds to a
        // model constant, because §4.6.4's generators are CONDITIONAL: every
        // series resistance in the tree spells `if (r > 0) I(a,b) <+
        // white_noise(4kT/r)`, and a generator whose statement did not execute
        // has to read back zero. A core live-out does exactly that (`h[k]` is
        // seeded `S.con(0)` at entry and assigned only inside the branch);
        // anything rendered outside the core evaluates unconditionally, and
        // `4kT/0` is not zero, it is an infinity that reaches the host as a
        // NaN the moment the collapsed branch gives it a zero adjoint gain.
        // `planPrecompute` declines these targets for the same reason.
        //
        // The EXPONENT is exempt: a constant renders inline, because it is only
        // ever read on a row whose power is non-zero — i.e. one that executed.
        for (self.noise_rows) |nr| {
            for ([_]Mir.Value{ nr.pwr, nr.exp }, 0..) |v, k| {
                if (v == .f_zero) continue;
                if (k == 1 and self.psdConst(v) != null) continue;
                try jobs.append(self.arena, .{
                    // Never written: like `$limit`/`$retained`, this job exists
                    // only to put its target in the core.
                    .name = "$noise",
                    .target = v,
                    .mode = .strict,
                    .comment = "§4.6.4 noise PSD",
                });
            }
        }
        // §9.4 the display tasks, as ONE unit. Queued last, so no existing job —
        // and therefore no existing declaration name — moves when a model gains
        // or loses a `$strobe`.
        //
        // `.strict` unconditionally: proof.zig rates contributions only, a print
        // is not on the residual path, so there is nothing here for `.optimized`
        // to speed up and no verdict that would justify claiming it.
        const root = self.an.rv(self.lower.display_root);
        if (self.display == .emit and root != .f_zero) {
            var buf: [naming.max_name_len]u8 = undefined;
            const n = naming.unitName(&buf, self.mir.name, .{
                .role = .display,
                .target = "tasks",
            }) catch return error.NameTooLong;
            self.display_name = try self.arena.dupe(u8, n);
            try jobs.append(self.arena, .{
                .name = self.display_name,
                .target = root,
                .mode = .strict,
                .comment = "§9.4 display tasks, in source order",
                .is_display = true,
            });
        }
        self.jobs = jobs.items;
    }

    fn emitUnits(self: *Gen) Error!void {
        try self.w("// ---- the model, in one declaration ----\n\n", .{});
        // The §9.4 display unit calls the core through `core`, not through its
        // structural key, so the ONE call spelling works in both the single-file
        // form (this alias) and the split form (the alias in `Output.prelude`,
        // which is an `@import`). It sits in the prologue, ahead of the first
        // recorded unit range, so the ranges still tile.
        if (self.common_name.len != 0) try self.w("const core = {s};\n\n", .{self.common_name});
        try self.emitCommon();
        // §4.5.11/§4.5.12 the coefficient reader is DERIVED from the operator's
        // unit name (like the old `<unit>__q`), not a Unit of its own, so the
        // normative ordering in naming.zig/proof.zig is untouched. It reads
        // `Model` alone, so it was never part of the residual slice and is
        // unaffected by the merge.
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const k = opKind(u.target);
            if (k != .laplace and k != .zi) continue;
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            const p = try cg_filters.filterPlan(self, inst, self.mir.instData(inst).call.args);
            if (p.err != null) continue;
            const lo = self.out.items.len;
            const nm = try std.fmt.allocPrint(self.arena, "{s}__sec", .{self.unit_names[i]});
            const at = try cg_filters.emitFilterSections(self, self.unit_names[i], p, k == .zi);
            try self.recordUnitFile(nm, lo, at);
        }
        for (self.jobs) |job| {
            if (!job.is_display) continue;
            self.pre_fatal = job.pre_fatal;
            // §9.5 the one unit where a descriptor operation may actually happen.
            self.emitting_display = true;
            defer self.emitting_display = false;
            const lo = self.out.items.len;
            const at = try self.emitUnit(job.name, job.target, @tagName(job.mode), job.comment);
            try self.recordUnitFile(job.name, lo, at);
        }
        self.pre_fatal = null;
    }

    /// The one declaration the shared core is emitted into. See the block
    /// comment at "the shared core" for why the whole model is one declaration
    /// returning a struct rather than one declaration per unit.
    ///
    /// The return type is written INLINE (an anonymous struct in the signature)
    /// rather than as a named `Common(S)`: a named type would be a second
    /// top-level declaration, and in the single-file form it would have to be
    /// public for the unit files to reach it — which `contract.validate`
    /// rejects. Zig infers the anonymous type at both ends, so the units never
    /// have to name it.
    fn emitCommon(self: *Gen) Error!void {
        if (self.lo_vals.len == 0) return;
        self.emitting_common = true;
        defer self.emitting_common = false;

        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        // §3.6.2.2 a refusal visible from ANY unit's declaration poisons the one
        // body they now share. That is not a widening: `eval` stamps every
        // contribution, so a `@compileError` in any single unit already failed
        // the whole device.
        self.fatal = null;
        for (self.jobs) |job| {
            if (job.is_display) continue;
            if (job.pre_fatal) |m| {
                self.fatal = m;
                break;
            }
        }
        const pre = self.fatal;
        self.plan.display_unit = self.emitting_display;
        try self.plan.analyze(.undef, self.emitting_common); // `emitting_common` ⇒ the live-outs are the targets

        const lo = self.out.items.len;
        try self.w(
            \\/// The whole model, evaluated ONCE per residual: the {d} source units
            \\/// share one CFG, so they share one declaration and `eval`/`q` read
            \\/// their targets out of the returned struct.
            \\
            \\/// `inline` because the ONLY caller shape is `eval`/`q`/`evalQ`
            \\/// destructuring the returned struct immediately: behind a call
            \\/// boundary the `[n_u]S` argument and the {d}-field result both go
            \\/// to memory, the host's Dual derivative vectors spill instead of
            \\/// staying in registers, and no live-out the caller drops can be
            \\/// dead-coded. Measured on ARPice devices/mos6_inverter: 45.3 ms
            \\/// inline vs 64.9 ms out-of-line (+43%), tran/fourbitadder +40%,
            \\/// scaling/parallel_inverters_500 +51%.
            \\
        , .{ self.jobs.len, self.jobs.len });
        const at_fn = self.out.items.len;
        try self.w("inline fn {s}(comptime S: type, ", .{self.common_name});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]S, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance) struct {{\n", .{});
        for (self.lo_vals, 0..) |v, k| {
            try self.w("    f{d}: {s},\n", .{ k, zigTy(self.an.vty[@intFromEnum(v)]) });
        }
        for (self.hp_vals, 0..) |v, j| {
            try self.w("    f{d}: {s}, // hoisted prefix\n", .{
                self.lo_vals.len + j, zigTy(self.an.vty[@intFromEnum(v)]),
            });
        }
        try self.w("}} {{\n", .{});
        // §4.3: the STRICTEST mode of every consumer — `proof.FloatMode.strictest`
        // explains why the join has to absorb `.strict`.
        try self.w("    @setFloatMode(.{t});\n", .{self.common_mode});
        self.cur_strict = self.common_mode == .strict;
        self.oc_name = self.common_name;
        self.oc_mode = @tagName(self.common_mode);

        const body_start = self.out.items.len;
        self.fatal = pre;
        try self.emitUnitBody(.undef);
        if (self.fatal) |msg| {
            self.any_fatal = true;
            self.out.shrinkRetainingCapacity(body_start);
            self.uses_x = false;
            self.uses_model = false;
            self.uses_inst = false;
            try self.b("    @compileError(\"{s}\");\n", .{msg});
        }
        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        try self.w("}}\n\n", .{});
        try self.emitChunkFns(.undef);
        try self.recordUnitFile(self.common_name, lo, at_fn);
    }

    fn opInstOf(self: *const Gen, unit: u32) ?Mir.Inst {
        for (self.op_unit, 0..) |u, k| {
            if (u == unit) return @enumFromInt(@as(u32, @intCast(k)));
        }
        return null;
    }

    /// Call arguments of the operator that owns unit `i` (empty if it has none).
    fn opArgs(self: *const Gen, i: usize) []const Mir.Value {
        const inst = self.opInstOf(@intCast(i)) orelse return &.{};
        return self.mir.instData(inst).call.args;
    }

    /// Which field of the core holds analog-operator unit `i`'s §4.5 input, or
    /// `none_u32` for an operator called with no argument (its input is the
    /// literal zero and never reaches the core).
    fn opInputIdx(self: *const Gen, i: u32) u32 {
        const args = self.opArgs(i);
        if (args.len == 0) return none_u32;
        return self.lo_idx[@intFromEnum(self.an.rv(args[0]))];
    }

    /// Emit one source-unit function. LRM §5.6/§4.7/§5.3.
    /// The signature is UNIFORM and never churns; only the body depends on the
    /// unit's own logic, so `zig` re-Semas exactly the units that changed.
    /// Which parameters the body ended up reading is only known after the body
    /// is rendered, but the signature comes first. Rather than render into a
    /// scratch buffer and copy (a second pass over every byte of a 191 MB
    /// output), emit the signature with three fixed-width slots and overwrite
    /// them in place. Zig does the same thing — `Parse.reserveNode` /`setNode`,
    /// AstGen's `instructions.append(undefined)` … `instructions.set(...)`.
    ///
    /// Zig allows whitespace before a parameter's `:`, so `_` can be padded out
    /// to the width of the name it replaces. Padding the DISCARD rather than the
    /// name keeps the used case byte-identical to a direct emit.
    ///
    /// Returns the offset of the `fn` keyword, which is where
    /// `orchestrator.writeTree` splices `pub ` when the declaration is written
    /// to its own `u/<key>.zig`. It is NOT emitted `pub` here: `text` is also
    /// the single-file `--emit-zig` form, and `contract.rejectStrayPubDecls`
    /// (tools/contract.zig) allows only contract-recognized names
    /// to be public on a device type. A per-unit name can never be one of
    /// those, so the visibility belongs to the split, not to the emission.
    fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: []const u8, comment: []const u8) Error!usize {
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        self.fatal = self.pre_fatal;
        self.plan.display_unit = self.emitting_display;
        try self.plan.analyze(target, self.emitting_common);

        try self.w("/// {s}\n", .{comment});
        const at_fn = self.out.items.len;
        try self.w("fn {s}(comptime S: type, ", .{name});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]S, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance) S {{\n", .{});
        try self.w("    @setFloatMode(.{s});\n", .{mode});
        self.cur_strict = std.mem.eql(u8, mode, "strict");
        self.oc_name = name;
        self.oc_mode = mode;

        const body_start = self.out.items.len;
        try self.emitUnitBody(target);
        if (self.fatal) |msg| {
            self.any_fatal = true;
            self.out.shrinkRetainingCapacity(body_start);
            self.uses_x = false;
            self.uses_model = false;
            self.uses_inst = false;
            try self.b("    @compileError(\"{s}\");\n", .{msg});
        }
        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        try self.w("}}\n\n", .{});
        try self.emitChunkFns(target);
        return at_fn;
    }

    /// Overwrite a reserved parameter-name slot with `_`, space-padded to the
    /// name's width so the bytes after it do not move.
    fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
        self.out.items[at..][0..width].* = ("_" ++ " " ** (width - 1)).*;
    }

    // ---- slicing: what this unit actually has to compute -------------------

    /// What taking `from → to` reduces to for this unit, or null when the edge
    /// does something the unit can observe. Iterative, not recursive: the chain
    /// of empty blocks is bounded by nothing syntactic.

    // ---- body emission ------------------------------------------------------

    fn zigTy(t: VTy) []const u8 {
        return switch (t) {
            .real => "S",
            .int => "i64",
            .str => "[]const u8",
        };
    }

    /// The identity a slot starts at when it must be defined on every path.
    /// Matches `renderVal`'s rendering of an `.undef` operand, so the two agree
    /// on what "no value here" looks like.
    /// Name of the hoist array a slot of this type lives in — see `hoist_idx`.
    fn hoistArray(t: VTy) []const u8 {
        return switch (t) {
            .real => "h",
            .int => "hi",
            .str => "hs",
        };
    }

    /// The name a value's slot is read and written under: its own `tN`, or an
    /// element of its type's hoist array. The ONE place that knows the
    /// difference, so declaration and use can never drift apart.
    ///
    /// `writeSlotRef` is the hot form — every slotted use goes through it, and
    /// it writes straight into the output buffer. `slotRefStr` is for the one
    /// caller that needs the name as a value (`f64Const`).
    fn slotArr(self: *Gen, i: usize) ?[]const u8 {
        const s = self.plan.slot[i];
        if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
        return null;
    }
    fn slotNum(self: *Gen, i: usize) u32 {
        const s = self.plan.slot[i];
        if (s < self.hoist_idx.items.len and self.hoist_idx.items[s] != none_u32) return self.hoist_idx.items[s];
        return s;
    }
    fn writeSlotRef(self: *Gen, i: usize) Error!void {
        if (self.slotArr(i)) |arr| {
            self.oc_use[@intFromEnum(self.an.vty[i])] = true;
            return self.b("{s}[{d}]", .{ arr, self.slotNum(i) });
        }
        return self.b("t{d}", .{self.slotNum(i)});
    }
    fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
        if (self.slotArr(i)) |arr| {
            self.oc_use[@intFromEnum(self.an.vty[i])] = true;
            return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ arr, self.slotNum(i) });
        }
        return std.fmt.allocPrint(self.arena, "t{d}", .{self.slotNum(i)});
    }

    fn zeroOf(t: VTy) []const u8 {
        return switch (t) {
            .real => "S.con(0.0)",
            .int => "0",
            .str => "\"\"",
        };
    }

    /// Where one slot's declaration ends up, and the evidence for it.
    ///
    /// `def_off`/`max_use` are output offsets and `scope` an index into
    /// `sc_end`: since the emitted scopes nest, "every use is lexically inside
    /// the block that defines this slot" is exactly
    /// `def_off < max_use < sc_end[scope]`, and no dominator query is needed —
    /// the emitter's own brace placement IS the answer.
    const Place = struct {
        defs: u32 = 0,
        uses: u32 = 0,
        def_off: u32 = 0,
        /// Offset of the LAST def — a loop-carried slot's final write sits
        /// textually after its last read, and chunk-locality (below) must
        /// cover it too.
        max_def: u32 = 0,
        max_use: u32 = 0,
        scope: u32 = 0,
        /// Something disqualifies this slot from `const`-at-definition: a
        /// second assignment (a real phi), a phi copy on a CFG edge, or a use
        /// emitted before the assignment (a loop-carried read).
        pinned: bool = false,
        /// Set once, after the probe: declare at the definition instead of at
        /// function scope.
        at_def: bool = false,
    };

    fn scopeOpen(self: *Gen) Error!void {
        if (!self.probing) return;
        try self.sc_end.append(self.arena, 0);
        try self.sc_open.append(self.arena, @intCast(self.sc_end.items.len - 1));
    }

    /// `at` is where the scope's text ends, which is NOT always `out.len`: the
    /// `emitCode` peephole rewinds over a label it decided not to keep.
    fn scopeClose(self: *Gen, at: usize) void {
        if (!self.probing) return;
        self.sc_end.items[self.sc_open.pop().?] = @intCast(at);
    }

    /// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
    /// several edges, and even a single-edge copy lands in an arm its merge
    /// block's readers are lexically outside of.
    fn probeDef(self: *Gen, slot: u32, movable: bool) void {
        if (!self.probing) return;
        const p = &self.place.items[slot];
        if (p.defs == 0) {
            p.def_off = @intCast(self.out.items.len);
            p.scope = self.sc_open.getLast();
        }
        p.max_def = @intCast(self.out.items.len);
        p.defs += 1;
        if (p.defs > 1 or !movable) p.pinned = true;
    }

    fn probeUse(self: *Gen, slot: u32) void {
        if (!self.probing) return;
        const p = &self.place.items[slot];
        p.uses += 1;
        // Read before written in the text: a loop-carried value, or a slot the
        // emitter never assigns at all (which is the `undefined`/zero seed the
        // hoist exists to provide).
        if (p.defs == 0) p.pinned = true;
        // Outlining: a read from the driver's return crosses an emitted
        // FUNCTION boundary — only a hoist array crosses one.
        if (self.oc_in_ret) p.pinned = true;
        p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
    }

    /// Emit the body once into scratch to learn, per slot, where its assignment
    /// lands relative to its reads; rewind; then emit for real.
    ///
    /// A dry run rather than a dominator/liveness query because the emitted
    /// nesting is not the CFG: `planDeadBranches` deletes `if`s, the `emitCode`
    /// peephole deletes labels, and `emitEdge` inlines a whole subtree into an
    /// arm. Re-deriving the resulting brace structure would be a second, subtly
    /// different copy of the emitter. Emission only appends to `out` and only
    /// sets monotone `uses_*` flags, so running it twice is free of side
    /// effects (`fatal` is set-once and reproduces the same message).
    fn probeBody(self: *Gen, target: Mir.Value) Error!void {
        self.place.clearRetainingCapacity();
        try self.place.appendNTimes(self.arena, .{}, self.plan.n_slots);
        self.sc_end.clearRetainingCapacity();
        self.sc_open.clearRetainingCapacity();

        const at = self.out.items.len;
        self.probing = true;
        self.hp_bnd = 0;
        self.hp_cut = 0;
        self.hp_off = 0;
        self.hp_dirty = false;
        self.oc_insts = 0;
        self.oc_cuts = 0;
        self.oc_returns = 0;
        self.oc_ret_at = 0;
        self.oc_bad = false;
        try self.scopeOpen(); // the function body itself (the driver, chunked)
        // Chunked, every top-level cut ends one of these scopes and opens the
        // next, so `at_def` below answers "def and every use inside ONE
        // emitted function".
        self.oc_bounds.clearRetainingCapacity();
        if (self.oc_on) {
            try self.scopeOpen();
            try self.oc_bounds.append(self.arena, @intCast(self.out.items.len));
        }
        try self.emitTree(0, 1, target);
        if (self.oc_on) {
            self.scopeClose(self.out.items.len); // the last chunk
            // The driver returns AFTER the last chunk call, so the layout is
            // only sound when the one return already was the last executable
            // text — anything after it but closing braces (merge code the
            // return was nested under) would become reachable in a chunk
            // that no longer returns. Checked on the probe's own text.
            self.oc_bad = self.oc_returns != 1;
            if (!self.oc_bad) for (self.out.items[self.oc_ret_at..]) |ch| {
                if (ch != ' ' and ch != '\n' and ch != '}') {
                    self.oc_bad = true;
                    break;
                }
            };
        }
        self.scopeClose(self.out.items.len);
        self.probing = false;
        self.hp_bnd = 0; // the real walk counts the same boundaries from zero
        self.out.shrinkRetainingCapacity(at);

        for (self.place.items) |*p| {
            // `uses == 0` keeps its `var`: a slot that is written and never read
            // is legal Zig, but the same code as an unused `const` is not.
            p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
                p.max_use < self.sc_end.items[p.scope];
        }
        // A value crossing the prefix guard has to be in a hoist ARRAY: the
        // guard is a scope its `const` would not survive, and the else arm has
        // to be able to assign it.
        for (self.hp_vals) |v| {
            const s = self.plan.slot[@intFromEnum(v)];
            if (s != none_u32) self.place.items[s].at_def = false;
        }
    }

    fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
        // FIRST, before anything can emit a slot name: slot numbering is
        // unit-local, so last unit's hoist indices would otherwise still be
        // live here and rename this unit's slots into another unit's array.
        // Both paths below can emit before the real assignment happens — the
        // straight-line path returns early, and `probeBody` dry-runs the whole
        // body — so clearing anywhere later is too late.
        self.hoist_idx.clearRetainingCapacity();
        try self.hoist_idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);

        // One call, at the top of the body, so the shared core is evaluated
        // exactly once per unit — the same number of times it is evaluated
        // today, when every unit inlines a copy of it.
        if (self.plan.uses_cache) {
            self.uses_x = true;
            self.uses_model = true;
            self.uses_inst = true;
            try self.ind(1);
            try self.b("const c = core(S, x, model, inst);\n", .{});
        }
        // Outlining gate. `n_slots` IS the emitted statement count (one slot,
        // one statement), so a body at or under the chunk size keeps today's
        // output byte for byte. No extra floor: the option is opt-in and the
        // caller picks the size per artifact (`Options.outline_chunk` has the
        // measured guidance — bodies under ~2-3 k statements are better off
        // whole). `uses_cache` bodies hold a `const c` no chunk could see;
        // they are the post-fold unit tails and small.
        self.oc_on = self.outline != 0 and !self.plan.uses_cache and
            !self.emitting_display and self.plan.n_slots > self.outline;
        if (self.plan.straight and !self.oc_on) {
            try self.emitBlockInsts(0, 1, true);
            try self.emitReturn(1, target);
            return;
        }
        // Out-of-SSA: a function-scope `var` per surviving value that NEEDS
        // one. Function scope (not the defining lexical block) because a
        // labelled-block reconstruction can put a definition inside a scope its
        // dominated uses are lexically outside of — but that is the exception,
        // not the rule, so `probeBody` measures it instead of assuming it and
        // `emitBlockInsts` declares the rest as `const` at the definition. On
        // `hisimhv_va` that is 16 k of 20 k hoists removed, ~26% of the file.
        //
        // What is left hoisted, and why each one has to be:
        //   - assigned more than once — a genuine phi, so it must be a `var`;
        //   - assigned by `emitPhiCopies` — the copy sits in the arm, the
        //     readers sit after the merge;
        //   - read outside the block that assigns it — the labelled-block case
        //     the comment above describes;
        //   - never assigned at all, which is the `undefined`/zero seed below.
        //
        // `undefined` is safe for every slot EXCEPT one the function RETURNS.
        // SSA guarantees a use is dominated by its definition, so an ordinary
        // slot is always written before it is read — but the return is reached
        // from every exit block, including ones the definition does not
        // dominate. That happens whenever the unit's target is defined inside a
        // conditional, which is exactly what `if (c) I <+ transition(x)` builds:
        // the operator's INPUT unit then returned `undefined` on the not-taken
        // path, and `updateState` pushed that into the operator's history —
        // undefined behavior in a shipped device, and silent state corruption in
        // the far more common case where it merely looked like a number.
        //
        // Zero is the value, not just a safe one: the arm did not execute, so it
        // contributed nothing this step — the same reason lowering seeds a §5.6
        // contribution accumulator with `.f_zero`.
        // Pinned by tests/fixtures/exhaustive/069_conditional_operator_state.va.
        try self.probeBody(target);
        // Outlining is off the table when the probe hit a fatal (the body
        // becomes one `@compileError`), when the return shape failed the
        // trailing-text check (`probeBody`), or when the body never actually
        // crossed the chunk size. The probe's per-chunk scopes only ever make
        // at_def STRICTER, so its result is valid for the unchunked layout
        // too — but re-probe for the exact one-scope answer; two dry runs
        // cost less than one hoist kept.
        if (self.oc_on) {
            if (self.fatal != null or self.oc_bad or self.oc_cuts == 0) {
                self.oc_on = false;
                try self.probeBody(target);
            } else {
                self.oc_total = self.oc_cuts + 1;
            }
        }
        const ret = self.an.rv(target);

        // One array per type instead of one `var` per slot. Two passes: assign
        // every survivor its index first, so the array lengths are known before
        // anything is written, then emit the declarations. `hoist_idx` was
        // cleared at entry and `probeBody` has just run against those cleared
        // names, so this is the first assignment either pass has seen.
        var n_hoist = [_]u32{0} ** 3;
        // A returned slot cannot be seeded `undefined` (see above), and an array
        // is declared once for all of its elements — so those are seeded by an
        // explicit store after the declaration instead.
        var seeded: std.ArrayList(Mir.Value) = .empty;
        defer seeded.deinit(self.arena);
        self.oc_local_chunk.clearRetainingCapacity();
        self.oc_local_slot.clearRetainingCapacity();
        self.oc_local_ty.clearRetainingCapacity();
        for (self.plan.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (self.plan.slot[v] == none_u32) continue;
            const p = self.place.items[self.plan.slot[v]];
            if (p.at_def) continue;
            // Never assigned and never read: `mark` kept the value alive but
            // the emitted tree reaches neither end of it. Declaring it would be
            // an unused local.
            if (p.defs == 0 and p.uses == 0) continue;
            // Chunked: a slot whose whole life sits inside one chunk becomes
            // that chunk's own `var` — register-promotable, unlike a store
            // through the escaped shared array. A returned slot can never
            // classify (its return read lies past the terminal boundary).
            if (self.oc_on and p.defs != 0) {
                if (self.ocLocalIn(p)) |k| {
                    try self.oc_local_chunk.append(self.arena, k);
                    try self.oc_local_slot.append(self.arena, self.plan.slot[v]);
                    try self.oc_local_ty.append(self.arena, self.an.vty[v]);
                    continue;
                }
            }
            const ty = @intFromEnum(self.an.vty[v]);
            self.hoist_idx.items[self.plan.slot[v]] = n_hoist[ty];
            n_hoist[ty] += 1;
            const returned = if (self.emitting_common) self.lo_idx[v] != none_u32 else lv == ret;
            if (returned) try seeded.append(self.arena, lv);
        }
        for ([_]VTy{ .real, .int, .str }) |ty| {
            const n = n_hoist[@intFromEnum(ty)];
            if (n == 0) continue;
            try self.ind(1);
            try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
        }
        for (seeded.items) |lv| {
            const v = @intFromEnum(lv);
            try self.ind(1);
            try self.writeSlotRef(v);
            try self.b(" = {s};\n", .{zeroOf(self.an.vty[v])});
        }
        if (!self.oc_on) {
            try self.emitTree(0, 1, target);
            // The guard opened at boundary 0 is closed at boundary `hp_cut`;
            // if the real walk never reached it the emitted brace is unbalanced,
            // which is a generator bug and not something to ship.
            assert(!self.hp_on or !self.emitting_common or self.hp_bnd > self.hp_cut);
            return;
        }
        // Chunked: this function is now the DRIVER — the hoist arrays above,
        // one `@call(.never_inline, ...)` per chunk, and the one return. The
        // chunk bodies follow the driver's closing brace (`emitChunkFns`,
        // called by `emitUnit`/`emitCommon`); Zig's decl order doesn't care,
        // and `writeTree`'s `pub ` splice at `fn_at` publishes only the
        // driver. `.never_inline` is the point: LLVM must see N small
        // functions, not one body it re-inlines into the very thing outlining
        // exists to break up.
        self.oc_n = n_hoist;
        for (0..self.oc_total) |k| {
            try self.ind(1);
            try self.b("@call(.never_inline, {s}__c{d}, .{{ S, &x, model, inst", .{ self.oc_name, k });
            for ([_]VTy{ .real, .int, .str }) |ty| {
                if (self.oc_n[@intFromEnum(ty)] == 0) continue;
                try self.b(", &{s}", .{hoistArray(ty)});
            }
            try self.b(" }});\n", .{});
        }
        try self.emitReturn(1, target);
        self.uses_x = true;
        self.uses_model = true;
        self.uses_inst = true;
    }

    // ---- outlining ----------------------------------------------------------

    /// Cut trigger, called at the two places a chunk may end: between top-level
    /// statements (`emitBlockInsts` at depth 1) and before a top-level subtree
    /// (`emitTree` at depth 1). Depth 1 means no label, loop or arm is open —
    /// the emitter's depth IS its brace count — so a `break`/`continue` can
    /// never cross a chunk boundary, and every value that does is in a hoist
    /// array (the probe's per-chunk scopes force exactly that).
    fn maybeCut(self: *Gen) Error!void {
        // Same two call sites, same reason (see below): depth 1 is the only
        // place a region boundary can land. The two are mutually exclusive —
        // `planHoistPrefix` declines whenever `outline` is set.
        try self.hpBoundary();
        if (!self.oc_on or self.oc_insts < self.outline) return;
        self.oc_insts = 0;
        self.oc_cuts += 1;
        if (self.probing) {
            self.scopeClose(self.out.items.len);
            try self.scopeOpen();
            try self.oc_bounds.append(self.arena, @intCast(self.out.items.len));
        } else if (self.oc_real) {
            try self.closeChunkFn();
            try self.openChunkFn();
        }
    }

    /// The chunk whose probe-text interval contains this slot's whole life,
    /// or null when it spans a boundary (or the driver's return).
    fn ocLocalIn(self: *const Gen, p: Place) ?u32 {
        const hi = @max(p.max_use, p.max_def);
        const bounds = self.oc_bounds.items;
        for (0..bounds.len - 1) |k| {
            if (p.def_off >= bounds[k] and hi < bounds[k + 1]) return @intCast(k);
        }
        return null;
    }

    /// One chunk header. Uniform signature — always all three unit parameters
    /// plus every hoist array the unit has — with the same reserve-and-patch
    /// slots as `emitUnit`, so a chunk that reads only `h` says so.
    fn openChunkFn(self: *Gen) Error!void {
        try self.w("fn {s}__c{d}(comptime S: type, ", .{ self.oc_name, self.oc_cuts });
        self.oc_at[0] = self.out.items.len;
        try self.w("x: *const [n_u]S, ", .{});
        self.oc_at[1] = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        self.oc_at[2] = self.out.items.len;
        try self.w("inst: *const Instance", .{});
        for ([_]VTy{ .real, .int, .str }) |ty| {
            const n = self.oc_n[@intFromEnum(ty)];
            if (n == 0) continue;
            try self.w(", ", .{});
            self.oc_at[3 + @intFromEnum(ty)] = self.out.items.len;
            try self.w("{s}: *[{d}]{s}", .{ hoistArray(ty), n, zigTy(ty) });
        }
        try self.w(") void {{\n", .{});
        try self.w("    @setFloatMode(.{s});\n", .{self.oc_mode});
        // This chunk's own share of the out-of-SSA vars (see `ocLocalIn`).
        for (self.oc_local_chunk.items, self.oc_local_slot.items, self.oc_local_ty.items) |k, slot, ty| {
            if (k != self.oc_cuts) continue;
            try self.w("    var t{d}: {s} = undefined;\n", .{ slot, zigTy(ty) });
        }
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        self.oc_use = @splat(false);
    }

    fn closeChunkFn(self: *Gen) Error!void {
        if (!self.uses_x) self.patchParam(self.oc_at[0], "x".len);
        if (!self.uses_model) self.patchParam(self.oc_at[1], "model".len);
        if (!self.uses_inst) self.patchParam(self.oc_at[2], "inst".len);
        if (self.oc_n[0] != 0 and !self.oc_use[0]) self.patchParam(self.oc_at[3], "h".len);
        if (self.oc_n[1] != 0 and !self.oc_use[1]) self.patchParam(self.oc_at[4], "hi".len);
        if (self.oc_n[2] != 0 and !self.oc_use[2]) self.patchParam(self.oc_at[5], "hs".len);
        try self.w("}}\n\n", .{});
    }

    /// The real walk, emitted as sibling `fn`s after the driver's closing
    /// brace. Same walk the probe ran, so the cuts land on the same statements;
    /// the driver's call list was emitted from the probe's count and the assert
    /// is the agreement check.
    fn emitChunkFns(self: *Gen, target: Mir.Value) Error!void {
        if (!self.oc_on) return;
        self.oc_real = true;
        self.oc_insts = 0;
        self.oc_cuts = 0;
        self.oc_returns = 0;
        try self.openChunkFn();
        try self.emitTree(0, 1, target);
        try self.closeChunkFn();
        self.oc_real = false;
        self.oc_on = false;
        assert(self.oc_cuts + 1 == self.oc_total);
    }

    /// A unit returns its one contribution value; the common declaration
    /// returns the whole cache. Same exit points either way, so this is the one
    /// place that knows the difference.
    fn emitReturn(self: *Gen, depth: u32, target: Mir.Value) Error!void {
        try self.ind(depth);
        if (!self.emitting_common) {
            try self.b("return ", .{});
            try self.renderVal(target, .real);
            try self.b(";\n", .{});
            return;
        }
        // An exit inside the prefix guard would skip the else arm's reloads and
        // the whole body after them, so the region ends before it.
        self.hp_dirty = true;
        try self.b("return .{{\n", .{});
        for (self.lo_vals, 0..) |v, k| {
            try self.ind(depth + 1);
            try self.b(".f{d} = ", .{k});
            try self.renderVal(v, self.an.vty[@intFromEnum(v)]);
            try self.b(",\n", .{});
        }
        // The prefix's live-outs ride out as ordinary fields — that is the only
        // way `precompute` can see them (`planHoistPrefix`).
        for (self.hp_vals, 0..) |v, j| {
            try self.ind(depth + 1);
            try self.b(".f{d} = ", .{self.lo_vals.len + j});
            try self.renderVal(v, self.an.vty[@intFromEnum(v)]);
            try self.b(",\n", .{});
        }
        try self.ind(depth);
        try self.b("}};\n", .{});
    }

    fn emitBlockInsts(self: *Gen, bi: u32, depth: u32, comptime decl: bool) Error!void {
        const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
        for (stmts) |inst| {
            const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
            if (!self.plan.needed[i] or self.plan.slot[i] == none_u32) continue;
            if (depth == 1) try self.maybeCut();
            self.hpMarkInst(inst);
            self.oc_insts += 1;
            self.probeDef(self.plan.slot[i], true);
            // `or` short-circuits, so the straight-line path (`decl`, which runs
            // without a probe) never touches `place`.
            const at_def = decl or self.place.items[self.plan.slot[i]].at_def;
            try self.ind(depth);
            if (at_def) {
                try self.b("const t{d}: {s} = ", .{ self.plan.slot[i], zigTy(self.an.vty[i]) });
            } else {
                try self.writeSlotRef(i);
                try self.b(" = ", .{});
            }
            try self.renderInst(inst);
            try self.b(";\n", .{});
        }
    }

    fn emitTree(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
        if (depth == 1) try self.maybeCut();
        if (self.an.is_loop[bi]) {
            try self.ind(depth);
            try self.b("L{d}: while (true) {{\n", .{bi});
            try self.scopeOpen();
            try self.emitCode(bi, depth + 1, target);
            self.scopeClose(self.out.items.len);
            try self.ind(depth);
            try self.b("}}\n", .{});
        } else {
            try self.emitCode(bi, depth, target);
        }
    }

    fn emitCode(self: *Gen, bi: u32, depth0: u32, target: Mir.Value) Error!void {
        const mc = self.an.mk_pool[self.an.mk_off[bi]..self.an.mk_off[bi + 1]];
        var depth = depth0;
        // Where the INNERMOST label (`mc[0]`, opened last) begins — the peephole
        // below rewinds to it.
        var at_inner: usize = 0;
        var i = mc.len;
        while (i > 0) {
            i -= 1;
            if (i == 0) at_inner = self.out.items.len;
            try self.ind(depth);
            try self.b("B{d}: {{\n", .{mc[i]});
            try self.scopeOpen();
            depth += 1;
        }
        const body_start = self.out.items.len;
        try self.emitBlockInsts(bi, depth, false);
        try self.emitTerm(bi, depth, target);

        // PEEPHOLE. `B{k}: { break :B{k}; }` is a labelled block whose only
        // statement is to leave it, and an empty one says the same thing — both
        // mean "fall through to `k`'s own code", which is emitted right after
        // the closing brace either way. This is what `planDeadBranches` leaves
        // behind once the `if` that used to sit here is gone: measured on
        // `bsimsoi_va`, 2 262 of a unit's remaining 3 207 lines. Rewinding `out`
        // is the same reserve-and-back-patch `emitUnit` uses for the signature.
        const dropped = mc.len != 0 and self.isFallThrough(body_start, depth, mc[0]);
        if (dropped) {
            self.out.shrinkRetainingCapacity(at_inner);
            self.scopeClose(at_inner);
            depth -= 1;
        }
        for (mc, 0..) |k, j| {
            if (j != 0 or !dropped) {
                depth -= 1;
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}}\n", .{});
            }
            try self.emitTree(k, depth, target);
        }
    }

    /// Is everything emitted since `at` exactly "leave the block labelled `k`"?
    /// A break to any OTHER label is not the same thing: dropping this label
    /// would then let control fall into `k`'s code instead of past it.
    fn isFallThrough(self: *const Gen, at: usize, depth: u32, k: u32) bool {
        const body = self.out.items[at..];
        if (body.len == 0) return true;
        var buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "break :B{d};\n", .{k}) catch return false;
        if (body.len != depth * 4 + want.len) return false;
        for (body[0 .. depth * 4]) |ch| {
            if (ch != ' ') return false;
        }
        return std.mem.eql(u8, body[depth * 4 ..], want);
    }

    fn emitTerm(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
        const t = self.an.term[bi];
        if (t == .none) {
            // The block lowering ended in: the contribution accumulators are
            // read here (§5.6.1.3).
            if (self.oc_on) {
                self.oc_returns += 1;
                if (self.oc_real) {
                    // The driver owns the VALUE return; the chunk still must
                    // LEAVE here — hisimhv's exit sits inside a `while (true)`,
                    // and falling through where the monolith returned re-runs
                    // the loop forever.
                    try self.ind(depth);
                    try self.b("return;\n", .{});
                    return;
                }
                // Probe: render it so its reads are counted — pinned into the
                // hoist arrays by `probeUse` — and record where it ended for
                // `probeBody`'s trailing-text feasibility check. The pre-
                // return offset closes the last chunk-locality interval, so
                // a slot the return reads can never classify chunk-local.
                try self.oc_bounds.append(self.arena, @intCast(self.out.items.len));
                self.oc_in_ret = true;
                try self.emitReturn(depth, target);
                self.oc_in_ret = false;
                if (self.oc_returns == 1) self.oc_ret_at = self.out.items.len;
                return;
            }
            try self.emitReturn(depth, target);
            return;
        }
        switch (self.mir.instData(t)) {
            .jump => |d| try self.emitEdge(bi, @intFromEnum(d.target), depth, target),
            .branch => |d| {
                // `planDeadBranches`: both arms reconverge with nothing this
                // unit can observe in between, so emit the common action once.
                if (self.plan.dead_branch[bi])
                    return self.emitEdge(bi, @intFromEnum(d.then_block), depth, target);
                // The condition decides which arm's phi copies run, so a
                // bias-dependent one ends the region even when both arms are
                // parameter-only.
                self.hpMark(d.cond);
                try self.ind(depth);
                try self.b("if (", .{});
                try self.renderCond(d.cond);
                try self.b(") {{\n", .{});
                try self.scopeOpen();
                try self.emitEdge(bi, @intFromEnum(d.then_block), depth + 1, target);
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}} else {{\n", .{});
                try self.scopeOpen();
                try self.emitEdge(bi, @intFromEnum(d.else_block), depth + 1, target);
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}}\n", .{});
            },
            else => unreachable,
        }
    }

    fn renderCond(self: *Gen, cond: Mir.Value) Error!void {
        self.pinLanes(cond);
        const v = self.an.rv(cond);
        if (self.an.tyOf(v) == .int) {
            try self.renderVal(v, .int);
            try self.b(" != 0", .{});
        } else {
            try self.b("(", .{});
            try self.renderVal(v, .real);
            try self.b(").val() != 0.0", .{});
        }
    }

    fn emitEdge(self: *Gen, from: u32, to: u32, depth: u32, target: Mir.Value) Error!void {
        try self.emitPhiCopies(from, to, depth);
        if (self.an.is_loop[to] and self.an.dominates(to, from)) {
            try self.ind(depth);
            try self.b("continue :L{d};\n", .{to});
        } else if (self.an.is_merge[to]) {
            try self.ind(depth);
            try self.b("break :B{d};\n", .{to});
        } else {
            try self.emitTree(to, depth, target);
        }
    }

    /// SSA-out-of-form on the edge `from → to`. Emitted through temporaries when
    /// `to` has more than one live phi, so a phi reading another phi of the same
    /// block (the swap idiom) cannot lose a copy.
    fn emitPhiCopies(self: *Gen, from: u32, to: u32, depth: u32) Error!void {
        const phis = self.an.phi_pool[self.an.phi_off[to]..self.an.phi_off[to + 1]];
        var n: u32 = 0;
        for (phis) |inst| {
            if (self.slotted(inst)) n += 1;
        }
        if (n == 0) return;
        const par = n > 1;
        if (par) {
            try self.ind(depth);
            try self.b("{{\n", .{});
        }
        const d2 = if (par) depth + 1 else depth;
        var k: u32 = 0;
        for (phis) |inst| {
            if (!self.slotted(inst)) continue;
            const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
            // A phi is transparent to `hpPure` because THIS is where its value
            // enters — one incoming copy per edge, each checked as it is written.
            self.hpMark(self.an.phiIn(inst, from));
            self.oc_insts += 1;
            try self.ind(d2);
            if (par) {
                try self.b("const c{d}: {s} = ", .{ k, zigTy(self.an.vty[i]) });
            } else {
                self.probeDef(self.plan.slot[i], false);
                try self.writeSlotRef(i);
                try self.b(" = ", .{});
            }
            try self.renderVal(self.an.phiIn(inst, from), self.an.vty[i]);
            try self.b(";\n", .{});
            k += 1;
        }
        if (!par) return;
        k = 0;
        for (phis) |inst| {
            if (!self.slotted(inst)) continue;
            try self.ind(d2);
            self.probeDef(self.plan.slot[@intFromEnum(self.an.i_res[@intFromEnum(inst)])], false);
            try self.writeSlotRef(@intFromEnum(self.an.i_res[@intFromEnum(inst)]));
            try self.b(" = c{d};\n", .{k});
            k += 1;
        }
        try self.ind(depth);
        try self.b("}}\n", .{});
    }

    /// A pooled phi this unit actually materializes into a local slot.
    fn slotted(self: *const Gen, inst: Mir.Inst) bool {
        const i = @intFromEnum(self.an.i_res[@intFromEnum(inst)]);
        return self.plan.needed[i] and self.plan.slot[i] != none_u32;
    }

    // ---- value / instruction rendering --------------------------------------

    /// Emit a value reference, converting per §4.2.1.1/§4.2.1.2 when the use
    /// wants the other LRM type.
    /// `renderVal` into a string instead of into `out`.
    ///
    /// Rendering only ever APPENDS, so the scratch buffer is `out` itself: emit,
    /// copy the tail, rewind. That keeps one growable buffer for the whole
    /// emission and keeps `uses_x`/`uses_model` accounting identical to a direct
    /// render — the same reserve-and-rewind trick `emitCode`'s peephole and
    /// `emitUnit`'s parameter slots use.
    ///
    /// Only for the handful of §4.5 operator inputs that have to appear inside a
    /// `{s}` of a kernel call; everything else renders straight into `out`.
    fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8 {
        const at = self.out.items.len;
        try self.renderVal(v, want);
        const s = try self.arena.dupe(u8, self.out.items[at..]);
        self.out.shrinkRetainingCapacity(at);
        return s;
    }

    pub fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void {
        const v = self.an.rv(v0);
        const def = self.mir.valueDef(v);
        if (def == .undef) {
            // ponytail: undefined operands share the slot initializer's spelling.
            try self.b("{s}", .{zeroOf(want)});
            return;
        }
        if (self.an.tyOf(v) == want) return self.renderValueRef(v);
        switch (want) {
            .real => {
                if (def == .int_const) {
                    try self.b("S.con({s})", .{try self.fmtF64(@floatFromInt(def.int_const))});
                    return;
                }
                try self.b("S.con(@as(f64, @floatFromInt(", .{});
                try self.renderValueRef(v);
                try self.b(")))", .{});
            },
            .int => {
                if (def == .float_const) {
                    // `lossyCast`, not an isFinite branch: `isFinite(1e300)` is
                    // true and the old `@intFromFloat` panicked on it. Saturate
                    // exactly like the emitted runtime cast below, so folding a
                    // constant cannot change what the device would compute.
                    const x = def.float_const;
                    try self.b("{d}", .{std.math.lossyCast(i64, @round(x))});
                    return;
                }
                // §2.7: a string LITERAL used as an operand is the unsigned
                // base-256 integer its bytes spell, which is what a §9.4
                // numeric conversion applied to one prints — `$strobe("%d",
                // "\n")` is 10. Lowering converts one everywhere it can see a
                // numeric context; the format string is the one context it
                // cannot, since the specifier is only paired with its operand
                // here (cg_display.appendConv).
                if (self.an.tyOf(v) == .str) return switch (def) {
                    .str_const => |s| self.b("@as(i64, {d})", .{Lower.strToInt(s, 64)}),
                    // Not a literal, so §3.3 leaves it with no numeric value.
                    else => self.b("@as(i64, 0)", .{}),
                };
                self.pinLanes(v); // a real→int collapse is a scalar decision
                // Saturating (§4.2.1.1 only defines the rounding): the device
                // is built ReleaseFast by real hosts, where `@intFromFloat` of
                // an out-of-range or NaN value is UB, not a trap.
                try self.b("std.math.lossyCast(i64, @round((", .{});
                try self.renderValueRef(v);
                try self.b(").val()))", .{});
            },
            .str => try self.b("\"\"", .{}),
        }
    }

    /// LRM §4. Constants → `S.con(literal)`, parameters → `model.<name>`, node
    /// probes → `x[@intFromEnum(U.<node>)]`, instruction results → the
    /// UNIT-LOCAL slot name (never `v{MIR index}` — naming.zig's ABSOLUTE RULE).
    fn renderValueRef(self: *Gen, v: Mir.Value) Error!void {
        const i = @intFromEnum(v);
        // Hoisted out of the run entirely: `precompute` wrote the field when
        // the model card / temperature last changed.
        if (i < self.an.nv and self.plan.pcHoisted(v)) {
            self.uses_inst = true;
            return self.b("S.con(inst.pc__{d})", .{self.pc_idx[i]});
        }
        // Hoisted: computed once by the common declaration, read here out of the
        // cache the body opened with — see "the shared core" in `Plan`.
        if (i < self.an.nv and self.plan.cached(v)) return self.b("c.f{d}", .{self.lo_idx[i]});
        if (i < self.an.nv and self.plan.slot[i] != none_u32) {
            self.probeUse(self.plan.slot[i]);
            try self.writeSlotRef(i);
            return;
        }
        switch (self.mir.valueDef(v)) {
            .undef => try self.b("S.con(0.0)", .{}),
            .float_const => |x| try self.b("S.con({s})", .{try self.fmtF64(x)}),
            .int_const => |x| try self.b("@as(i64, {d})", .{x}),
            .str_const => |s| try self.b("\"{f}\"", .{std.zig.fmtString(s)}),
            .param_ref => |p| {
                self.uses_model = true;
                switch (Analysis.tyOfParam(self.lower.params.items[p].ty)) {
                    .real => try self.b("S.con(model.{s})", .{self.p_names[p]}),
                    .int, .str => try self.b("model.{s}", .{self.p_names[p]}),
                }
            },
            .block_param => |u| {
                self.uses_x = true;
                try self.b("x[@intFromEnum(U.{s})]", .{self.u_names[u]});
            },
            .inst_result => |inst| try self.renderInst(inst),
        }
    }

    /// May `v`'s inline-rendered subtree run UNCONDITIONALLY in a `.strict`
    /// unit? True for anything already materialized (slots/cache/phi vars are
    /// computed before the select either way), leaves, and trees of ops that
    /// are total on all of R under IEEE semantics: no call, and
    /// `proof.domainOf == .all` — which excludes ln/sqrt/pow/… and the
    /// hard-UB idiv/imod/fmod. Mirrors `foldHidesSlot`'s stop condition, so
    /// "inline" here is exactly what `renderVal` would inline.
    /// Would evaluating this arm eagerly run a libm call that the branch would
    /// have skipped? `eagerSafe` answers whether both arms MAY be evaluated;
    /// this answers whether they SHOULD.
    ///
    /// Branchless is the right default because the arms are a few FP ops and a
    /// mispredict costs more than both. A transcendental inverts that: `exp` is
    /// ~50 instructions, so a `sel` over it pays for the arm that is thrown
    /// away every single time. mos1 measured 2.00 `exp` per instance-eval
    /// against ngspice's 1.45 for exactly this reason — the b-s junction kept
    /// its `if` (a multi-use domain op blocked if-conversion) while the
    /// identical b-d junction was flattened, so both of ITS arms run forever.
    ///
    /// The cost of saying no is a data-dependent branch and a lane pin. That
    /// was the argument for keeping these eager — a lane-parallel S has no
    /// single `.val()` to steer on. It does not survive measurement: an
    /// instance-parallel S would have to take BOTH junction arms anyway, which
    /// is what collapses that design's kernel speedup from 3.6x to 1.67x, and
    /// the sparse stamp it cannot vectorize at all (195 Ir/instance at W=1,
    /// 196 at W=4) caps the whole idea at 1.17x end-to-end. Not a lever worth
    /// protecting with a real per-iterate cost.
    ///
    /// Only the INLINE tree counts: a `materialized` value is a statement that
    /// already ran, so hoisting it into a select changes nothing.
    fn eagerCostly(self: *Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 64) return false;
        const v = self.an.rv(v0);
        if (self.materialized(v)) return false;
        const def = self.mir.valueDef(v);
        if (def != .inst_result) return false;
        const row = self.mir.instRow(def.inst_result);
        if (libmClass(row.op)) return true;
        return switch (Mir.opClass(row.op)) {
            .unary => self.eagerCostly(@enumFromInt(row.a), depth + 1),
            .binary => self.eagerCostly(@enumFromInt(row.a), depth + 1) or
                self.eagerCostly(@enumFromInt(row.b), depth + 1),
            .ternary => self.eagerCostly(@enumFromInt(row.a), depth + 1) or
                self.eagerCostly(@enumFromInt(row.b), depth + 1) or
                self.eagerCostly(@enumFromInt(row.c), depth + 1),
            .phi, .branch, .jump, .call => false,
        };
    }

    fn eagerSafe(self: *Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 64) return false;
        const v = self.an.rv(v0);
        if (self.materialized(v)) return true;
        const def = self.mir.valueDef(v);
        if (def != .inst_result) return true; // const / param / probe
        const inst = def.inst_result;
        const row = self.mir.instRow(inst);
        if (row.op == .call) return false;
        if (proof.domainOf(row.op) != .all) return false;
        return switch (Mir.opClass(row.op)) {
            .phi => true, // function-scope var, assigned on edges before here
            .unary => self.eagerSafe(@enumFromInt(row.a), depth + 1),
            .binary => self.eagerSafe(@enumFromInt(row.a), depth + 1) and
                self.eagerSafe(@enumFromInt(row.b), depth + 1),
            .ternary => self.eagerSafe(@enumFromInt(row.a), depth + 1) and
                self.eagerSafe(@enumFromInt(row.b), depth + 1) and
                self.eagerSafe(@enumFromInt(row.c), depth + 1),
            .branch, .jump, .call => false,
        };
    }

    /// Already computed as a statement (slot), a cache field, or a precompute
    /// field — rendering it is a name, not an expression. The stop condition
    /// `eagerSafe`, `maskCmp` and `foldHidesSlot` share.
    fn materialized(self: *const Gen, v: Mir.Value) bool {
        const i = @intFromEnum(v);
        return i < self.an.nv and
            (self.plan.pcHoisted(v) or self.plan.cached(v) or self.plan.slot[i] != none_u32);
    }

    /// An x-dependent value is about to be collapsed to one scalar decision —
    /// record that lanes are pinned. dFree values are lane-uniform (params,
    /// temperature, time), so collapsing them steers nothing.
    fn pinLanes(self: *Gen, v: Mir.Value) void {
        if (self.emitting_display) return;
        if (self.an.dFree(v)) return;
        self.lane_pinned = true;
    }

    /// The select cond as an INLINE real comparison — unslotted, so rendering
    /// it in mask space leaves no unread `const` behind. Slotted predicates
    /// and int comparisons take the `S.con(@floatFromInt(..))` fallback.
    fn maskCmp(self: *Gen, cond: Mir.Value) ?Mir.Inst {
        const v = self.an.rv(cond);
        if (self.materialized(v)) return null;
        const def = self.mir.valueDef(v);
        if (def != .inst_result) return null;
        return switch (self.mir.instOp(def.inst_result)) {
            .flt, .fgt, .fle, .fge, .feq, .fne => def.inst_result,
            else => null,
        };
    }

    fn renderInst(self: *Gen, inst: Mir.Inst) Error!void {
        const row = self.mir.instRow(inst);
        const op = row.op;
        if (op == .call) return self.emitCall(inst);
        if (op == .phi) return self.b("S.con(0.0)", .{}); // materialised as a var

        // A whole derivative-free subtree comes out as ONE `S.con` over plain
        // f64 arithmetic, which is contract.zig's rule for physics code:
        // "everything not depending on x stays plain f64". Every S op it
        // replaces was carrying an n_u-wide zero the host cannot fold away
        // under `@setFloatMode(.strict)`. `f64Const` is the whole test — it
        // succeeds only on literals, parameters and arithmetic over them.
        const res = self.mir.instResult(inst);
        if (res != .undef and self.an.vty[@intFromEnum(res)] == .real and self.an.dFree(res)) {
            if (try self.f64Const(res, 0, true)) |s| return self.b("S.con({s})", .{s});
        }

        const a: Mir.Value = @enumFromInt(row.a);
        const b2: Mir.Value = @enumFromInt(row.b);
        const c: Mir.Value = @enumFromInt(row.c);

        // §4.2.12 the value-form conditional stays LAZY by default: proof.zig
        // treats the condition as a guard on the arms, so `x > 0 ? ln(x) : 0`
        // is accepted — evaluating both arms would run ln(x) with x <= 0,
        // which is UB under @setFloatMode(.optimized). Do not "simplify" this
        // to a select of two pre-computed values.
        //
        // EXCEPT where laziness buys nothing: in a `.strict` unit every f64
        // op is IEEE-defined, so a real select whose inline arms contain no
        // call and no domain-restricted op (proof.domainOf == .all — which
        // also excludes idiv/imod/fmod, the hard-UB ones) may evaluate BOTH
        // arms and pick with the contract's `sel` mask primitive. A dead
        // arm's NaN/inf is discarded by the pick. That removes the branch the
        // host's predictor would eat per Newton iteration (T7) and is what a
        // lane-parallel S needs — `.val()` has no single answer across lanes.
        if (op == .select) {
            const want = self.an.vty[@intFromEnum(self.mir.instResult(inst))];
            if (want == .real and self.cur_strict and
                self.eagerSafe(b2, 0) and self.eagerSafe(c, 0) and
                !self.eagerCostly(b2, 0) and !self.eagerCostly(c, 0))
            {
                // Best mask first: an inline real comparison renders in S
                // space (`lt`/`le`/`eq`) and is TRUE PER LANE on a vector S.
                // gt/ge are operand swaps; ne swaps the select's arms — the
                // contract carries exactly lt/le/eq/sel. ifconv peels the
                // `toBool` wrapper, so the cond IS the bare comparison here.
                // The MASK, best form first: an inline real comparison
                // renders in S space (TRUE PER LANE on a vector S; ne swaps
                // the arms — the contract carries exactly lt/le/eq/sel).
                // Otherwise the emitted predicate is a 0/1 i64 (or a real S
                // tested against zero): still branchless, but the int form is
                // lane-UNIFORM — fine for a scalar S, pinned on a vector S.
                var swap_arms = false;
                if (self.maskCmp(a)) |cmp| {
                    const d = self.mir.instData(cmp).binary;
                    const swap_ops = d.op == .fgt or d.op == .fge;
                    swap_arms = d.op == .fne;
                    const prim: []const u8 = switch (d.op) {
                        .flt, .fgt => "lt",
                        .fle, .fge => "le",
                        .feq, .fne => "eq",
                        else => unreachable,
                    };
                    try self.b("((", .{});
                    try self.renderVal(if (swap_ops) d.rhs else d.lhs, .real);
                    try self.b(").{s}(", .{prim});
                    try self.renderVal(if (swap_ops) d.lhs else d.rhs, .real);
                    try self.b(")).sel(", .{});
                } else if (self.an.tyOf(self.an.rv(a)) == .int) {
                    self.pinLanes(a);
                    try self.b("(S.con(@floatFromInt(", .{});
                    try self.renderVal(a, .int);
                    try self.b("))).sel(", .{});
                } else {
                    try self.b("(", .{});
                    try self.renderVal(a, .real);
                    try self.b(").sel(", .{});
                }
                try self.renderVal(if (swap_arms) c else b2, .real);
                try self.b(", ", .{});
                try self.renderVal(if (swap_arms) b2 else c, .real);
                try self.b(")", .{});
                return;
            }
            try self.b("(if (", .{});
            try self.renderCond(a);
            try self.b(") ", .{});
            try self.renderVal(b2, want);
            try self.b(" else ", .{});
            try self.renderVal(c, want);
            try self.b(")", .{});
            return;
        }
        return self.renderOp(op, a, b2, self.an.vty[@intFromEnum(self.mir.instResult(inst))]);
    }

    /// One opcode, rendered. Shared with the `$`-prefixed spellings of the same
    /// math functions (IEEE 1364 §17.11, carried into Verilog-AMS ch9).
    fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void {
        // §3.3.1 string relations: lowering types both operands `.string` and
        // picks the integer comparison opcodes for them.
        if (self.an.tyOf(self.an.rv(a)) == .str or self.an.tyOf(self.an.rv(b2)) == .str) {
            const rel: ?[]const u8 = switch (op) {
                .ieq, .feq => "== 0",
                .ine, .fne => "!= 0",
                .ilt, .flt => "< 0",
                .ile, .fle => "<= 0",
                .igt, .fgt => "> 0",
                .ige, .fge => ">= 0",
                else => null,
            };
            if (rel) |r| {
                try self.b("@as(i64, @intFromBool(zStrCmp(", .{});
                try self.renderVal(a, .str);
                try self.b(", ", .{});
                try self.renderVal(b2, .str);
                try self.b(") {s}))", .{r});
                return;
            }
        }
        switch (op) {
            // §4.2.4 real arithmetic. The mixed case — ONE operand
            // derivative-free — reaches the scalar half of the contract
            // (`scale`, `addC`) instead of the dual half, which is where the
            // saving is: `x.mul(S.con(k))` costs n_u multiplies against
            // `splat(0)` plus an n_u-wide add that `.strict` will not fold,
            // where `x.scale(k)` costs n_u multiplies and nothing else.
            //
            // Every rewrite here is value-preserving under IEEE 754: `a - k` is
            // defined as `a + (-k)`, and `k - a` as `(-a) + k`. `fdiv` has no
            // scalar form in the primitive set and `a * (1/k)` is NOT `a / k`,
            // so it keeps the dual op — see `renderOp`'s callers in the header.
            .fadd, .fsub, .fmul => {
                if (self.an.dFree(b2)) {
                    try self.b("(", .{});
                    try self.renderVal(a, .real);
                    try self.b(").{s}(", .{if (op == .fmul) "scale" else "addC"});
                    if (op == .fsub) try self.writeNegConst(b2) else try self.writeConst(b2);
                    return self.b(")", .{});
                }
                if (self.an.dFree(a)) {
                    try self.b("(", .{});
                    try self.renderVal(b2, .real);
                    // k - b: negate first, so the constant still arrives through
                    // `addC` and the derivative costs one negation.
                    try self.b("){s}.{s}(", .{
                        if (op == .fsub) ".neg()" else "",
                        if (op == .fmul) "scale" else "addC",
                    });
                    try self.writeConst(a);
                    return self.b(")", .{});
                }
                try self.method2(a, switch (op) {
                    .fadd => "add",
                    .fsub => "sub",
                    else => "mul",
                }, b2);
            },
            .fdiv => try self.method2(a, "div", b2),
            .fneg => try self.method1(a, "neg"),
            .fmod => {
                // zFmod truncates a `.val()` quotient — a scalar collapse.
                self.pinLanes(a);
                self.pinLanes(b2);
                try self.helper2("zFmod", a, b2);
            },
            // §4.3.1/§4.3.2 math
            .sqrt => try self.method1(a, "sqrt"),
            .exp => try self.method1(a, "exp"),
            .ln => try self.method1(a, "log"),
            .sin => try self.method1(a, "sin"),
            .cos => try self.method1(a, "cos"),
            .tanh => try self.method1(a, "tanh"),
            .sinh => try self.method1(a, "sinh"),
            .cosh => try self.method1(a, "cosh"),
            .atan => try self.method1(a, "atan"),
            .fabs => try self.method1(a, "abs"),
            // §4.3.1 Table 4-14 names the C library's expm1/log1p, which exist
            // BECAUSE exp(x)-1 and log(1+x) cancel for small x. So they are
            // scalar PRIMITIVES here, not helpers composed from exp/log — a
            // composed helper is the exact form the clause tells us to avoid.
            .expm1 => try self.method1(a, "expm1"),
            .ln1p => try self.method1(a, "log1p"),
            .log10 => try self.helper1("zLog10", a),
            .tan => try self.helper1("zTan", a),
            .asin => try self.helper1("zAsin", a),
            .acos => try self.helper1("zAcos", a),
            .asinh => try self.helper1("zAsinh", a),
            .acosh => try self.helper1("zAcosh", a),
            .atanh => try self.helper1("zAtanh", a),
            // zFloor/zCeil collapse to `S.con` of a `.val()`, and zAtan2
            // branches on its operands' signs — all three pin lanes.
            .floor => {
                self.pinLanes(a);
                try self.helper1("zFloor", a);
            },
            .ceil => {
                self.pinLanes(a);
                try self.helper1("zCeil", a);
            },
            // zHypot linearizes around `.val()` of both operands — pins.
            .hypot => {
                self.pinLanes(a);
                self.pinLanes(b2);
                try self.helper2("zHypot", a, b2);
            },
            .atan2 => {
                self.pinLanes(a);
                self.pinLanes(b2);
                try self.helper2("zAtan2", a, b2);
            },
            .fmin => try self.method2(a, "min", b2),
            .fmax => try self.method2(a, "max", b2),
            .pow => {
                // The scalar interface only has pow(S, f64); a constant exponent
                // (the overwhelming case) uses it, anything else goes through
                // `zPow`. `resolve_params = false` — the fold's own rule: only
                // a Model DEFAULT may look through a parameter. Folding with
                // `true` here baked the DECLARED default into `.pow(k)` and a
                // model-card override was silently ignored (value AND
                // Jacobian). A parameter exponent renders as a value
                // (`S.con(model.<p>)`) and `zPow` handles it — a model param
                // is solve-constant, so its derivative half is zero and the
                // c·a^(c−1) treatment is intact. `UnitPlan.foldedExponent` is
                // the exact mirror of this test; change both or neither.
                // A SOLVE-CONSTANT exponent takes the same `pow(S, f64)` route
                // as a literal one, with the f64 spelled as an expression
                // instead of a number. `dFree` is the whole test: the exponent
                // carries no derivative, so `zPow`'s ∂/∂y machinery has nothing
                // to build and its `.val()` on the BASE — which is x-dependent
                // and would pin lanes — buys nothing either. This is the case
                // that fires for every junction grading coefficient in every
                // SPICE model (`pow(1 - v/pj, 1 - mj)`, `pow(vgon, nc)`), so it
                // is worth taking off the pinning path: `S.pow` is one protocol
                // call a lane-parallel S implements per lane, where `zPow`
                // collapses to lane 0. `UnitPlan.foldedExponent` still marks the
                // exponent live here (it only skips a LITERAL fold), so the
                // "change both or neither" mirror is intact.
                const par_exp: ?[]const u8 = if (self.an.foldConst(b2, 0, false) == null and self.an.dFree(b2))
                    try self.f64Const(b2, 1, true)
                else
                    null;
                if (self.an.foldConst(b2, 0, false)) |k| {
                    try self.b("(", .{});
                    try self.renderVal(a, .real);
                    try self.b(").pow({s})", .{try self.fmtF64(k.f)});
                } else if (par_exp) |s| {
                    try self.b("(", .{});
                    try self.renderVal(a, .real);
                    try self.b(").pow({s})", .{s});
                } else {
                    // zPow linearizes around `.val()` of BOTH operands
                    // (§4.3.1's negative-base/integer-y steering included),
                    // so either being x-dependent pins lanes — the batch
                    // gate's fixture-158 catch.
                    self.pinLanes(a);
                    self.pinLanes(b2);
                    // ∂/∂y is dropped when the exponent cannot move with the
                    // solve — `b.addC(-y)` is then value-0 and derivative-0, so
                    // the term it scales contributes nothing and the `ln` that
                    // built its coefficient is pure cost. Every junction
                    // exponent in every SPICE model is a model PARAMETER, so
                    // this is the case that fires.
                    try self.b("zPow(S, ", .{});
                    try self.renderVal(a, .real);
                    try self.b(", ", .{});
                    try self.renderVal(b2, .real);
                    try self.b(", {})", .{!self.an.dFree(b2)});
                }
            },
            // §4.2.1 conversions
            .if_cast => {
                try self.b("S.con(@as(f64, @floatFromInt(", .{});
                try self.renderVal(a, .int);
                try self.b(")))", .{});
            },
            .fi_cast => {
                // §4.2.1.1 rounds; overflow is the language's silence and the
                // artifact's UB under ReleaseFast — `lossyCast` (saturate,
                // NaN→0) is the defined answer, and `Analysis.asI64` folds
                // with the identical rule.
                self.pinLanes(a); // a real→int collapse is a scalar decision
                try self.b("std.math.lossyCast(i64, @round((", .{});
                try self.renderVal(a, .real);
                try self.b(").val()))", .{});
            },
            .opt_barrier => try self.renderVal(a, res_ty),
            // §5.6.1.2 path-integrated reactive latches: value only, no
            // derivative, FIXED across one Newton attempt (advanced by
            // stateCtl(.commit) at the operating-point exit and per accepted
            // transient step). The residual is one smooth function per
            // attempt, so its AD Jacobian is exact — the coefficient's dA
            // enters only multiplied by (B − pb), which is zero at every
            // committed point (AC reads the pure capacitance form there).
            .path_prev, .path_acc => {
                const v = self.an.rv(a);
                const fam = if (op == .path_prev) self.prev_vals else self.acc_vals;
                const k = for (fam, 0..) |fv, fk| {
                    if (fv == v) break fk;
                } else unreachable; // planCommon queued every site
                self.uses_inst = true; // the latch read keeps `inst` in the signature
                try self.b("S.con(inst.{s}__{d})", .{ @as([]const u8, if (op == .path_prev) "pb" else "pq"), k });
            },
            // §3.2 integer arithmetic, at §3.2's 32-bit 2's complement width —
            // see `Lower.wrap32`, which is the definition this and the two
            // constant folds all implement. `%` (remainder) is never wider than
            // its operands and needs no wrap; `/` overflows for exactly one pair,
            // -2^31 / -1, whose 2's complement answer is -2^31 again.
            .iadd => try self.intBin32(a, "+%", b2),
            .isub => try self.intBin32(a, "-%", b2),
            .imul => try self.intBin32(a, "*%", b2),
            .idiv => {
                try self.b("@as(i64, @as(i32, @truncate(", .{});
                try self.intCall2("@divTrunc", a, b2);
                try self.b(")))", .{});
            },
            .imod => try self.intCall2("@rem", a, b2),
            .ineg => {
                try self.b("@as(i64, @as(i32, @truncate(-%(", .{});
                try self.renderVal(a, .int);
                try self.b("))))", .{});
            },
            .iabs => try self.intCall1("zIabs", a),
            .imin => try self.intCall2("@min", a, b2),
            .imax => try self.intCall2("@max", a, b2),
            // §4.2.5/§4.2.7 relational + equality — integer 0/1
            .flt => try self.cmpReal(a, "<", b2),
            .fgt => try self.cmpReal(a, ">", b2),
            .fle => try self.cmpReal(a, "<=", b2),
            .fge => try self.cmpReal(a, ">=", b2),
            .feq => try self.cmpReal(a, "==", b2),
            .fne => try self.cmpReal(a, "!=", b2),
            .ilt => try self.cmpInt(a, "<", b2),
            .igt => try self.cmpInt(a, ">", b2),
            .ile => try self.cmpInt(a, "<=", b2),
            .ige => try self.cmpInt(a, ">=", b2),
            .ieq => try self.cmpInt(a, "==", b2),
            .ine => try self.cmpInt(a, "!=", b2),
            // §4.2.8 logical
            .logand, .logor => {
                try self.b("@as(i64, @intFromBool((", .{});
                try self.renderVal(a, .int);
                try self.b(") != 0 {s} (", .{if (op == .logand) "and" else "or"});
                try self.renderVal(b2, .int);
                try self.b(") != 0))", .{});
            },
            .lognot => {
                try self.b("@as(i64, @intFromBool((", .{});
                try self.renderVal(a, .int);
                try self.b(") == 0))", .{});
            },
            // §4.2.9 bitwise
            .bitand => try self.intBin(a, "&", b2),
            .bitor => try self.intBin(a, "|", b2),
            .bitxor => try self.intBin(a, "^", b2),
            .bitxnor => {
                try self.b("~(", .{});
                try self.intBin(a, "^", b2);
                try self.b(")", .{});
            },
            .bitnot => {
                try self.b("~(", .{});
                try self.renderVal(a, .int);
                try self.b(")", .{});
            },
            // §4.2.11 shifts. `<<` zero-fills from the right on its own; the
            // truncation is §3.2's width, which is what makes `1 << 31` negative
            // and `1 << 32` zero. `zShl` wraps `std.math.shl` — which defines an
            // over-wide shift as 0 rather than as UB — with the unsigned-count
            // reading a NEGATIVE count needs (see the helper).
            .shl => {
                try self.b("@as(i64, @as(i32, @truncate(", .{});
                try self.intCall2("zShl", a, b2);
                try self.b(")))", .{});
            },
            // §4.2.11: "Both the << and >> shift operators fill the vacated bit
            // positions with zeroes (0)." A zero fill only means something
            // against a WIDTH, and §3.2.1 fixes the Verilog-A `integer` at 32
            // bits — so `>>` is not `std.math.shr(i64, ...)`, which sign-fills.
            .shr => try self.shrLogical(a, b2),
            .phi, .select, .call, .branch, .jump => unreachable,
        }
    }

    /// Would folding `v` to a single number leave a materialised temporary with
    /// no reader? `foldConst` collapses a subtree in one step and knows nothing
    /// about slots, and `unit_plan` already emitted a declaration for every one
    /// of them — an unread `const` is a Zig compile error, not a missed
    /// optimisation.
    ///
    /// Only the shapes `foldConst` itself walks: anything else it declines
    /// anyway, so answering `true` there costs nothing.
    fn foldHidesSlot(self: *Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 32) return true;
        const v = self.an.rv(v0);
        if (depth > 0 and self.materialized(v)) return true;
        const def = self.mir.valueDef(v);
        if (def != .inst_result) return false;
        const row = self.mir.instRow(def.inst_result);
        return switch (Mir.opClass(row.op)) {
            .unary => self.foldHidesSlot(@enumFromInt(row.a), depth + 1),
            .binary => self.foldHidesSlot(@enumFromInt(row.a), depth + 1) or
                self.foldHidesSlot(@enumFromInt(row.b), depth + 1),
            else => true,
        };
    }

    /// The f64 value of a DERIVATIVE-FREE operand, written in place. Callers
    /// check `dFree` first; this only decides how to spell it.
    ///
    /// Preferred spelling is the arithmetic itself (`model.is`, `(model.n) *
    /// (t0.val())`). The fallback reads the value out of the S the generator
    /// would have built anyway, which is what `$temperature` and every
    /// transcendental of a parameter need — neither has a plain-f64 spelling
    /// that a GPU can execute (`devSafe`), but both are still constants as far
    /// as the derivative is concerned.
    ///
    /// Depth 1, not 0: `v` is an OPERAND, so naming its own slot is exactly
    /// what is wanted. Depth 0 is reserved for `renderInst` asking about the
    /// value it is declaring, where naming that slot is a self-reference.
    fn writeConst(self: *Gen, v: Mir.Value) Error!void {
        if (try self.f64Const(v, 1, true)) |s| return self.b("{s}", .{s});
        try self.b("(", .{});
        try self.renderVal(v, .real);
        try self.b(").val()", .{});
    }

    /// `writeConst` negated, for `a - k` rendered as `a.addC(-k)`. A literal
    /// negates in the formatter rather than picking up a `-(...)` wrapper,
    /// because `addC(-1.0)` is the spelling a reader expects.
    fn writeNegConst(self: *Gen, v: Mir.Value) Error!void {
        // Same guard as `f64Const`: negating the folded number is only legal
        // where the fold itself is.
        if (!self.foldHidesSlot(v, 0)) {
            if (self.an.foldConst(v, 0, false)) |k| return self.b("{s}", .{try self.fmtF64(-k.f)});
        }
        try self.b("-(", .{});
        try self.writeConst(v);
        try self.b(")", .{});
    }

    fn method1(self: *Gen, a: Mir.Value, name: []const u8) Error!void {
        try self.b("(", .{});
        try self.renderVal(a, .real);
        try self.b(").{s}()", .{name});
    }

    fn method2(self: *Gen, a: Mir.Value, name: []const u8, b2: Mir.Value) Error!void {
        try self.b("(", .{});
        try self.renderVal(a, .real);
        try self.b(").{s}(", .{name});
        try self.renderVal(b2, .real);
        try self.b(")", .{});
    }

    fn helper1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
        try self.b("{s}(S, ", .{name});
        try self.renderVal(a, .real);
        try self.b(")", .{});
    }

    fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("{s}(S, ", .{name});
        try self.renderVal(a, .real);
        try self.b(", ", .{});
        try self.renderVal(b2, .real);
        try self.b(")", .{});
    }

    fn intBin(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("((", .{});
        try self.renderVal(a, .int);
        try self.b(") {s} (", .{opx});
        try self.renderVal(b2, .int);
        try self.b("))", .{});
    }

    /// The same operation, at §3.2's width: `Lower.wrap32`, emitted. The `%`
    /// wrapping ops below it are still needed — an i64 `+` that overflowed would
    /// PANIC before this could truncate it — so the two together are "wrap at 64,
    /// keep 32", which for in-range operands is the 32-bit answer. `intBin` is
    /// left un-wrapped for the bitwise ops that cannot leave the range.
    fn intBin32(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("@as(i64, @as(i32, @truncate(", .{});
        try self.intBin(a, opx, b2);
        try self.b(")))", .{});
    }

    fn intCall1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
        try self.b("{s}(", .{name});
        try self.renderVal(a, .int);
        try self.b(")", .{});
    }

    /// §9.5.4.2 one `zScan*` call: `(src, fmt)` for the count, plus the item
    /// index for the three item flavours. `want` is the type the RESULT lands in,
    /// so only the real flavour needs the `S.con` wrapper the scalar interface
    /// requires — the other two are already the plain Zig types their slots hold.
    fn emitScan(self: *Gen, fn_name: []const u8, args: []const Mir.Value, want: VTy) Error!void {
        if (want == .real) try self.b("S.con(", .{});
        try self.b("{s}(", .{fn_name});
        try self.renderVal(if (args.len > 0) args[0] else .undef, .str);
        try self.b(", ", .{});
        try self.renderVal(if (args.len > 1) args[1] else .undef, .str);
        if (args.len > 2) {
            try self.b(", ", .{});
            try self.renderVal(args[2], .int);
        }
        try self.b(")", .{});
        if (want == .real) try self.b(")", .{});
    }

    /// §9.13 one probabilistic draw. `$rng$auto` is the seedless form's
    /// `Instance` latch and reads a field; every other name is a `rng_kernels.zig`
    /// call taking the i64 seed and its real parameters.
    fn emitRng(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
        // A draw is one scalar per CALL, not per lane: a batch eval draws once
        // where N scalar evals draw N times. Pins unconditionally.
        self.lane_pinned = self.lane_pinned or !self.emitting_display;
        const tail = name["$rng$".len..];
        if (std.mem.eql(u8, tail, "auto")) {
            // §9.13.1's "internal seed", which "gets updated every time the call
            // ... is made" — by `updateState` on the accepted step, never here.
            self.uses_inst = true;
            const site = self.intArg(args, 0) orelse 0;
            return self.b("S.con(@floatFromInt(inst.rng_auto[{d}]))", .{site});
        }
        // `zRngIUniform`, `zRngChiSquare`, … — the kernel's camel spelling of the
        // callee's tail, so the two lists cannot drift apart by a typo.
        var fn_name: std.ArrayList(u8) = .empty;
        defer fn_name.deinit(self.gpa);
        try fn_name.appendSlice(self.gpa, "zRng");
        var up = true;
        for (tail) |c| {
            if (c == '_') {
                up = true;
                continue;
            }
            try fn_name.append(self.gpa, if (up) std.ascii.toUpper(c) else c);
            up = false;
        }
        try self.b("S.con({s}(", .{fn_name.items});
        try self.renderVal(if (args.len > 0) args[0] else .zero, .int);
        for (args[@min(1, args.len)..]) |a| {
            try self.b(", ", .{});
            try self.renderVal(a, .real);
            try self.b(".val()", .{});
        }
        try self.b("))", .{});
    }

    /// §9.21 `$table_model`, in the shape `Lower.lowerTableModel` rewrote it:
    ///
    ///     (ND, NP, NCOL, dep, "<extrap>", in₀…, row₀…)
    ///
    /// Every §9.21.1/§9.21.2 decision was made in lowering, where the control
    /// string and the array declarations exist, so this is a transcription: the
    /// four counts and the extrapolation characters become `zTable`'s comptime
    /// arguments, the lookup point an `[ND]S` and the sample block one flat
    /// `[NP*NCOL]f64`.
    ///
    /// The samples go in as f64 and the lookup point as `S`. That is not a
    /// simplification: §9.21.1 fixes the data source at the first call ("Any
    /// change after this point is ignored"), so a sample carries no derivative,
    /// while the lookup point is routinely a probe and its derivative is the
    /// Jacobian row the solver needs.
    fn emitTable(self: *Gen, args: []const Mir.Value) Error!void {
        // §9.21 zTable brackets on `.val()` — the cell choice is one scalar
        // decision, so a lane off the chosen cell would read a linear
        // extrapolation. Pins.
        for (args) |arg| self.pinLanes(arg);
        const nd = self.intArg(args, 0) orelse 0;
        const np = self.intArg(args, 1) orelse 0;
        const ncol = self.intArg(args, 2) orelse 0;
        const dep = self.intArg(args, 3) orelse 0;
        const ext = self.strArg(args, 4) orelse "";
        const head = 5 + nd;
        if (nd == 0 or np * ncol == 0 or args.len != head + np * ncol)
            return self.abort("malformed `$table_model` call reached codegen", .{});
        try self.b("zTable(S, {d}, {d}, {d}, {d}, \"{s}\", [_]f64{{", .{ np, ncol, nd, dep, ext });
        for (args[head..], 0..) |v, k| {
            if (k != 0) try self.b(", ", .{});
            try self.b("S.val(", .{});
            try self.renderVal(v, .real);
            try self.b(")", .{});
        }
        try self.b("}}, [_]S{{", .{});
        for (args[5..head], 0..) |v, k| {
            if (k != 0) try self.b(", ", .{});
            try self.renderVal(v, .real);
        }
        try self.b("}})", .{});
    }

    /// §3.2.2 runtime array index, in the shape `Lower.lowerIndex` rewrote it:
    ///
    ///     (lo, i, e_lo … e_hi)
    ///
    /// One `switch`, so the read is ONE dispatch and ONE element evaluation
    /// however wide the array is. A `sel` chain would evaluate every element
    /// and every comparison on every read — `sel` is a mask primitive, not a
    /// branch — which made `for (k…) a[k]` quadratic in the DECLARED extent.
    ///
    /// The `else` arm is element `lo`, which is what the chain's fallback was:
    /// §3.2.2 leaves an out-of-range index undefined, and reproducing the old
    /// answer keeps every existing device bit-identical.
    ///
    /// Each arm is rendered lazily by the switch, so an element that is an
    /// inline expression is evaluated only when it is the one selected. That is
    /// sound because a MIR value is pure; the ones with side effects (`$fopen`,
    /// `$display`) are statements and never reach an array initializer.
    fn emitIdx(self: *Gen, args: []const Mir.Value, want: VTy) Error!void {
        // The dispatch is on one integer, so the CHOICE is lane-uniform — the
        // same reason `emitTable` pins: a lane wanting a different element has
        // no spelling here.
        self.pinLanes(args[1]);
        const lo: i64 = blk: {
            const def = self.mir.valueDef(self.an.rv(args[0]));
            break :blk if (def == .int_const) def.int_const else 0;
        };
        if (args.len < 3) return self.abort("malformed `$idx` call reached codegen", .{});
        try self.b("switch (", .{});
        try self.renderVal(args[1], .int);
        try self.b(") {{", .{});
        for (args[2..], 0..) |v, k| {
            try self.b(" {d} => ", .{lo + @as(i64, @intCast(k))});
            try self.renderVal(v, want);
            try self.b(",", .{});
        }
        try self.b(" else => ", .{});
        try self.renderVal(args[2], want);
        try self.b(" }}", .{});
    }

    /// A structural count lowering put in an argument list as a literal.
    fn intArg(self: *const Gen, args: []const Mir.Value, i: usize) ?usize {
        if (i >= args.len) return null;
        const def = self.mir.valueDef(self.an.rv(args[i]));
        if (def != .int_const or def.int_const < 0) return null;
        return @intCast(def.int_const);
    }

    // ponytail: integer callees infer their type; add a typed variant only for a caller.
    fn intCall2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("{s}(", .{name});
        try self.renderVal(a, .int);
        try self.b(", ", .{});
        try self.renderVal(b2, .int);
        try self.b(")", .{});
    }

    /// §4.2.11 `>>` — a LOGICAL shift over §3.2.1's 32-bit `integer`.
    ///
    /// Narrow to 32 bits, shift as UNSIGNED so the vacated positions fill with
    /// zeroes, widen back. §4.2.11's own worked example is `3 >> 1` giving
    /// "0011 shifted to the right one position and zero-filled"; the arithmetic
    /// shift this replaced made `-16 >> 2` come out as -4 instead of
    /// 0xFFFFFFF0 >> 2 == 1073741820, i.e. it kept the sign the LRM says to drop.
    ///
    /// `zShr` (over `std.math.shr`) does the shifting because it is what
    /// defines an over-wide or negative count as 0 rather than as UB or a
    /// wrong-way shift — §4.2.11's count is unsigned; see the helper.
    ///
    /// `<<` is now narrowed at its own arm above, on §3.2's width rather than
    /// §4.2.11's fill rule — the two are separate clauses that happen to want the
    /// same 32 bits, and `Lower.wrap32` is where that width is written down.
    fn shrLogical(self: *Gen, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("@as(i64, zShr(@as(u32, @bitCast(@as(i32, @truncate(", .{});
        try self.renderVal(a, .int);
        try self.b(")))), ", .{});
        try self.renderVal(b2, .int);
        try self.b("))", .{});
    }

    fn cmpReal(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        self.pinLanes(a);
        self.pinLanes(b2);
        try self.b("@as(i64, @intFromBool((", .{});
        try self.renderVal(a, .real);
        try self.b(").val() {s} (", .{opx});
        try self.renderVal(b2, .real);
        try self.b(").val()))", .{});
    }

    fn cmpInt(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("@as(i64, @intFromBool((", .{});
        try self.renderVal(a, .int);
        try self.b(") {s} (", .{opx});
        try self.renderVal(b2, .int);
        try self.b(")))", .{});
    }

    // =======================================================================
    // Calls: §4.5 analog operators, §4.6 noise, ch9 system functions
    // =======================================================================

    /// A plain-f64 expression for an operator CONTROL argument (delay,
    /// transition time, initial condition, …), or null when the argument is not
    /// one the host can evaluate outside the S domain.
    ///
    /// The `Model` struct IS the parameter set, so a control argument that is an
    /// arithmetic expression over parameters is just that expression with
    /// `model.<p>` leaves — `td = len * sqrt(l * c)` renders as
    /// `model.len * @sqrt(model.l * model.c)`. Real models write the delay of a
    /// transmission line that way (lossy_tline.va:135, coupled_tlines.va:110),
    /// and §4.5.7 permits it: `absdelay(input, td [, maxdelay])` gives td as an
    /// `analog_expression`, and with no `maxdelay` "the value of td when the
    /// absdelay() is first evaluated shall be used and any future changes to td
    /// shall be ignored" — which for a parameter expression is every evaluation.
    ///
    /// `foldConst` first at EVERY node, so a subtree of literals still comes out
    /// as one folded number rather than as rendered arithmetic.
    //
    // ponytail: the op set is arithmetic, min/max, and the whole of Table 4-14
    // and Table 4-15 — every scalar math operator, because §6.3.4 puts no
    // restriction on which ones a dependent parameter's default may use and a
    // missing case is SILENT there (no derive line, the field frozen at the
    // fold-through-defaults value). What is still absent is the control flow a
    // value can carry: `select`, `phi` and `fmod` get a diagnostic, not silence.
    // Ceiling: unlike `foldConst` this never looks through a parameter's
    // DEFAULT, because the host overrides parameters at run time.
    //
    // ponytail: control flow is where the §6.3.4 half stops. `parameter real k
    // = (w > 2) ? 1.5 : 2.5;` lowers to a diamond and a phi, so no `derive()`
    // line is written for it and `k` keeps the value it has under `w`'s
    // DECLARED default even if the host overrides `w`. The value is at least
    // right (`ParamInfo.folded` carries `constEval`'s answer into
    // `paramDefault`); what is missing is that it follows. The upgrade path is
    // to render the diamond here as a Zig `if`, which is a statement and not an
    // expression fragment — so it needs `emitDerive` to take a rendered
    // STATEMENT, not the `[]const u8` expression this returns. No model in the
    // tree asks; the day one does, that is the shape.
    ///
    /// `in_unit` says the expression lands in a UNIT BODY rather than in a
    /// host-side `derive` line or `updateState`, and that changes two things.
    ///
    /// It may name a unit-local temporary — it must, in fact: without that a
    /// shared chain of parameter arithmetic re-renders its whole prefix at
    /// every link, which is quadratic in the chain length and BSIM4's
    /// temperature prep is hundreds of links long.
    ///
    /// And it is restricted to `devSafe` opcodes, because a unit body also
    /// compiles for nvptx, where there is no libm: `@exp`/`@log` on an f64
    /// become "no libcall available for fexp" at PTX assembly time. Those stay
    /// S operations, whose implementation is the host's problem and not this
    /// generator's — which is the same division of labour the whole S protocol
    /// rests on.
    pub fn f64Const(self: *Gen, v0: Mir.Value, depth: u32, in_unit: bool) Error!?[]const u8 {
        if (depth > 32) return null;
        const v = self.an.rv(v0);
        if (in_unit) {
            // Already materialised: NAME it, and never fold past it.
            //
            // `unit_plan` decided this slot was live by walking the MIR, and no
            // rendering choice here can revise that — fold past it and the
            // declaration it already emitted has no reader, which Zig rejects
            // outright ("unused local constant"). Naming it is also the cheaper
            // answer: the temporary holds a dual whose derivative half is a
            // structural zero, so reading the value out beats recomputing the
            // subtree. `depth > 0` because at depth 0 the caller IS this slot's
            // own declaration.
            if (depth > 0 and self.an.dFree(v)) {
                const i = @intFromEnum(v);
                // A precompute field IS the plain f64 — no `.val()` needed.
                if (i < self.an.nv and self.plan.pcHoisted(v)) {
                    self.uses_inst = true;
                    return try std.fmt.allocPrint(self.arena, "inst.pc__{d}", .{self.pc_idx[i]});
                }
                if (i < self.an.nv and self.plan.cached(v))
                    return try std.fmt.allocPrint(self.arena, "c.f{d}.val()", .{self.lo_idx[i]});
                if (i < self.an.nv and self.plan.slot[i] != none_u32) {
                    self.probeUse(self.plan.slot[i]);
                    return try std.fmt.allocPrint(self.arena, "{s}.val()", .{try self.slotRefStr(i)});
                }
            }
            // Folding a whole literal chain to one number is still the right
            // answer where it is available — `foldConst` works in f64, so the
            // number it lands on is the one the hardware would have — but it
            // takes the subtree in ONE step and cannot see the check above.
            // So ask first whether it would swallow a slot.
            if (!self.foldHidesSlot(v, 0)) {
                if (self.an.foldConst(v, 0, false)) |k| return try self.fmtF64(k.f);
            }
        } else if (self.an.foldConst(v0, 0, false)) |k| return try self.fmtF64(k.f);
        switch (self.mir.valueDef(v)) {
            .param_ref => |p| {
                self.uses_model = true;
                return switch (Analysis.tyOfParam(self.lower.params.items[p].ty)) {
                    .real => try std.fmt.allocPrint(self.arena, "model.{s}", .{self.p_names[p]}),
                    .int => try std.fmt.allocPrint(self.arena, "@as(f64, @floatFromInt(model.{s}))", .{self.p_names[p]}),
                    .str => "0.0",
                };
            },
            .inst_result => |inst| {
                const row = self.mir.instRow(inst);
                if (in_unit and !devSafe(row.op)) return null;
                // §9.15 a host-published `$simparam` IS a Model field, so a
                // §3.4 parameter default written over it renders here and
                // `emitDerive` picks it up. Without this the default folded to
                // nothing, `paramDefault` wrote 0 and W1050 fired.
                if (row.op == .call) {
                    const d = self.mir.instData(inst).call;
                    if (!std.mem.eql(u8, d.name, "$simparam")) return null;
                    const f = Lower.simparamHostField(self.strArg(d.args, 0) orelse "") orelse return null;
                    self.uses_model = true;
                    return try std.fmt.allocPrint(self.arena, "model.{s}", .{f});
                }
                switch (Mir.opClass(row.op)) {
                    // Rendered as open/close (and separator) fragments rather
                    // than as a format string per opcode: `allocPrint` wants a
                    // comptime format, and a `{s}`-per-case switch would be the
                    // same table written twice as long.
                    .unary => {
                        const a = try self.f64Const(@enumFromInt(row.a), depth + 1, in_unit) orelse return null;
                        const fix: [2][]const u8 = switch (row.op) {
                            .fneg, .ineg => .{ "-(", ")" },
                            .fabs, .iabs => .{ "@abs(", ")" },
                            .sqrt => .{ "@sqrt(", ")" },
                            // §4.3.1 Table 4-14 and §4.3.2 Table 4-15 in full.
                            // Every one is a pure f64→f64 function of a value
                            // the host already has, so a §6.3.4 default over one
                            // derives exactly as an arithmetic default does —
                            // the clause puts no operator restriction on a
                            // dependent parameter, so neither does this.
                            .exp => .{ "@exp(", ")" },
                            .ln => .{ "@log(", ")" },
                            .log10 => .{ "@log10(", ")" },
                            .expm1 => .{ "std.math.expm1(", ")" },
                            .ln1p => .{ "std.math.log1p(", ")" },
                            .floor => .{ "@floor(", ")" },
                            .ceil => .{ "@ceil(", ")" },
                            .sin => .{ "@sin(", ")" },
                            .cos => .{ "@cos(", ")" },
                            .tan => .{ "@tan(", ")" },
                            .asin => .{ "std.math.asin(", ")" },
                            .acos => .{ "std.math.acos(", ")" },
                            .atan => .{ "std.math.atan(", ")" },
                            .sinh => .{ "std.math.sinh(", ")" },
                            .cosh => .{ "std.math.cosh(", ")" },
                            .tanh => .{ "std.math.tanh(", ")" },
                            .asinh => .{ "std.math.asinh(", ")" },
                            .acosh => .{ "std.math.acosh(", ")" },
                            .atanh => .{ "std.math.atanh(", ")" },
                            // An int→real widening and a reassociation barrier
                            // are both identities in the f64 domain.
                            .if_cast, .opt_barrier => .{ "", "" },
                            else => return null,
                        };
                        return try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ fix[0], a, fix[1] });
                    },
                    .binary => {
                        // Integer ops render in the f64 domain like `foldConst`
                        // folds them there; `idiv` is left out because its
                        // truncation is NOT what `/` does on an f64.
                        const fix: [3][]const u8 = switch (row.op) {
                            .fadd, .iadd => .{ "(", ") + (", ")" },
                            .fsub, .isub => .{ "(", ") - (", ")" },
                            .fmul, .imul => .{ "(", ") * (", ")" },
                            .fdiv => .{ "(", ") / (", ")" },
                            .fmin, .imin => .{ "@min(", ", ", ")" },
                            .fmax, .imax => .{ "@max(", ", ", ")" },
                            .pow => .{ "std.math.pow(f64, ", ", ", ")" },
                            .hypot => .{ "std.math.hypot(", ", ", ")" },
                            .atan2 => .{ "std.math.atan2(", ", ", ")" },
                            else => return null,
                        };
                        const a = try self.f64Const(@enumFromInt(row.a), depth + 1, in_unit) orelse return null;
                        const b2 = try self.f64Const(@enumFromInt(row.b), depth + 1, in_unit) orelse return null;
                        return try std.fmt.allocPrint(self.arena, "{s}{s}{s}{s}{s}", .{
                            fix[0], a, fix[1], b2, fix[2],
                        });
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    /// `f64Const` for a position where the LRM requires one. A control argument
    /// that does not resolve is a SOURCE-LEVEL diagnostic (E0515) plus a refused
    /// unit — never an `@compileError` string pasted into the generated Zig,
    /// which surfaces as "unreachable code" at a line of generated code with
    /// nothing pointing back at the `.va`.
    pub fn f64Expr(self: *Gen, v0: Mir.Value) Error![]const u8 {
        if (try self.f64Const(v0, 0, false)) |s| return s;
        // The argument's own defining expression is the thing to point at; the
        // operator call is the fallback for a leaf with no instruction of its
        // own (a node probe, a phi), which is the common case here.
        const v = self.an.rv(v0);
        const def = self.mir.valueDef(v);
        const tok = if (def == .inst_result) self.mir.instTok(def.inst_result) else Mir.no_tok;
        if (self.diags) |bag| try bag.add(
            .codegen,
            .E0515,
            self.lower.tokenSpan(if (tok == Mir.no_tok) self.ctrl_tok else tok),
            "this argument is computed during the solve; only literals, parameters " ++
                "and arithmetic over them are available where the host evaluates it",
            .{},
        );
        if (self.fatal == null) self.fatal = "LRM 4.5: an analog operator control argument " ++
            "must be a constant or parameter expression";
        return "0.0";
    }

    pub fn argF64(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
        if (i >= args.len) return dflt;
        return self.f64Expr(args[i]);
    }

    /// "the signal crossed zero since the last accepted step, in the direction
    /// argument 1 asks for": `+1` rising, `-1` falling, `0` (or absent) either.
    /// §4.5.10 `last_crossing` and §5.10.3 `cross` take the SAME argument with
    /// the same meaning, so they share the test — `last_crossing` used to fire
    /// on any sign change and report a falling edge to a `(V(p), +1)` call.
    ///
    /// The argument is a `constant_expression` in both grammars — and a
    /// PARAMETER is one, so `resolve_params = false`: folding through the
    /// declared default froze `cross(x, dir)` at the default's direction and
    /// the model card's override was silently ignored. A direction that folds
    /// without parameters still picks its comparison here; a parameter one
    /// becomes a `zCrossDir` call on the model's value, and a genuinely
    /// solve-time one is E0515 out of `f64Expr` (§4.5.14's constant-or-
    /// parameter rule).
    /// `in` is the CURRENT input as a plain `f64` expression: the local
    /// `updateState` binds, or the rendered operand `.val()` in `eval`. Both
    /// spellings compare against the same `__prev`, which holds the last
    /// ACCEPTED input either way.
    fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value, in: []const u8) Error![]const u8 {
        const arg: Mir.Value = if (args.len > 1) args[1] else .zero;
        if (self.an.foldConst(arg, 0, false)) |c| {
            return switch (std.math.lossyCast(i64, c.f)) {
                1 => std.fmt.allocPrint(self.arena, "inst.{0s}__prev <= 0.0 and {1s} > 0.0", .{ n, in }),
                -1 => std.fmt.allocPrint(self.arena, "inst.{0s}__prev >= 0.0 and {1s} < 0.0", .{ n, in }),
                else => std.fmt.allocPrint(
                    self.arena,
                    "(inst.{0s}__prev <= 0.0 and {1s} > 0.0) or (inst.{0s}__prev >= 0.0 and {1s} < 0.0)",
                    .{ n, in },
                ),
            };
        }
        return std.fmt.allocPrint(self.arena, "zCrossDir({s}, inst.{s}__prev, {s})", .{
            try self.f64Expr(arg), n, in,
        });
    }

    /// §5.10.3.1/§5.10.3.2/§5.10.3.3, one sentence repeated verbatim for
    /// `cross`, `above` and `timer`: "If enable argument is specified and it is
    /// zero, then <op>() is inactive, meaning that it does not generate an
    /// event". Absent means active, so an operator without the argument gets a
    /// literal `true` and the emitted `and` folds away.
    ///
    /// The enable is the ONE operator argument that is a live expression rather
    /// than a codegen-time constant — `enableArgIdx` is what makes `UnitPlan`
    /// give it a slot, so a `cross(…, enable)` whose enable is a variable
    /// assigned in the block renders as that variable and not as its phi's zero.
    fn enableTest(self: *Gen, name: []const u8, args: []const Mir.Value) Error![]const u8 {
        const i = enableArgIdx(name) orelse return "true";
        if (i >= args.len) return "true";
        const at = self.out.items.len;
        try self.renderCond(args[i]);
        const s = try self.arena.dupe(u8, self.out.items[at..]);
        self.out.shrinkRetainingCapacity(at);
        return s;
    }

    /// §5.10 the `held_vars` index a `$held_*` call carries as its only
    /// argument. Always a literal `Lower` emitted, so the fold cannot fail.
    fn heldIdx(self: *const Gen, args: []const Mir.Value) usize {
        const c = self.an.foldConst(if (args.len != 0) args[0] else .zero, 0, false) orelse return 0;
        const i: usize = @intFromFloat(c.f);
        return @min(i, self.held_names.len -| 1);
    }

    /// System/environment and operator calls. LRM ch9, §4.5, §4.6.
    fn emitCall(self: *Gen, inst: Mir.Inst) Error!void {
        const d = self.mir.instData(inst).call;
        const name = d.name;
        const k = opKind(name);
        // Lane accounting for the batch differential gate. ddt/idt and the
        // §4.5.11/§4.5.12 filters stay lane-exact: their helpers branch only
        // on `dt` (lane-uniform) and are otherwise S-linear over shared f64
        // state, so evaluating N points against one Instance is exactly N
        // scalar evaluations. Every other operator either steers on a
        // `.val()` of its x-dependent input (events, transition, slew) or
        // collapses it (delays), so it pins.
        switch (k) {
            .none, .ddt, .idt, .laplace, .zi, .bound_step, .discontinuity => {},
            else => for (d.args) |arg| self.pinLanes(arg),
        }
        if (k != .none) return self.emitOperator(inst, d.args, k);

        // §4.5.13 limexp — user-invoked only; the engine never inserts it.
        // Pins: zLimexp branches on its argument's `.val()`.
        if (std.mem.eql(u8, name, "limexp")) {
            if (d.args.len > 0) self.pinLanes(d.args[0]);
            return self.helper1("zLimexp", if (d.args.len > 0) d.args[0] else .f_zero);
        }

        // §4.5.14 ddx(f, V(node)) — the unknown index came through as an int.
        // Pins: `.ddxAt` reads one scalar partial, which a value-form batch S
        // does not carry.
        if (std.mem.eql(u8, name, "ddx")) {
            if (d.args.len > 0) self.pinLanes(d.args[0]);
            const u = if (d.args.len > 1) self.an.foldConst(d.args[1], 0, true) else null;
            try self.b("S.con((", .{});
            try self.renderVal(if (d.args.len > 0) d.args[0] else .f_zero, .real);
            // The index is a literal lowering minted, but the cast is still
            // saturating: a compiler panic is never the answer to bad MIR.
            try self.b(").ddxAt({d}))", .{if (u) |x| std.math.lossyCast(i64, x.f) else 0});
            return;
        }

        // §5.2.1 the `analog initial` guard. Its own flag and not
        // `is_initial_step`: §5.2.1 re-executes the block for each SUB-TASK of a
        // parameter sweep, and Table 5-1's initial_step is the first point of the
        // whole analysis. See `Lower.lowerModule`.
        if (std.mem.eql(u8, name, "analog_initial")) {
            self.uses_inst = true;
            try self.b("S.con(if (inst.is_analog_initial) 1.0 else 0.0)", .{});
            return;
        }

        // §5.10.2 global events.
        if (std.mem.eql(u8, name, "initial_step") or std.mem.eql(u8, name, "final_step")) {
            self.uses_inst = true;
            const flag = if (name[0] == 'i') "is_initial_step" else "is_final_step";
            try self.b("S.con(if (inst.{s}", .{flag});
            if (d.args.len != 0) {
                try self.b(" and (", .{});
                try self.analysisMatch(d.args);
                try self.b(")", .{});
            }
            try self.b(") 1.0 else 0.0)", .{});
            return;
        }

        // §4.6.1 analysis("dc"|"tran"|…).
        if (std.mem.eql(u8, name, "analysis")) {
            self.uses_inst = true;
            try self.b("S.con(if (", .{});
            try self.analysisMatch(d.args);
            try self.b(") 1.0 else 0.0)", .{});
            return;
        }

        // §4.6.4 noise sources contribute in a small-signal noise analysis only;
        // their residual contribution is identically zero. The generator
        // topology is exported through `noise_gens` and the PSD — which IS the
        // call's argument, not anything derivable from the residual — through
        // `noisePsd`, whose core fields the argument slice already holds.
        const noise = [_][]const u8{ "white_noise", "flicker_noise", "noise_table", "noise_table_log" };
        for (noise) |n| {
            if (std.mem.eql(u8, name, n)) return self.b("S.con(0.0)", .{});
        }
        // §4.6.3 ac_stim(analysis_name, mag, phase) is NOT a noise source: it
        // is a small-signal stimulus. "The AC stimulus function returns zero
        // (0) during large-signal analyses (such as DC and transient) as well
        // as on all small-signal analyses using names which do not match
        // analysis_name" — so the whole function is one conditional on the
        // analysis in force, with the §4.6.1 name comparison `analysis()`
        // already spells. The name defaults to "ac", mag to 1.0, phase to 0.0.
        //
        // ponytail: the residual is REAL, so a matching analysis contributes
        // the phasor's real part, mag·cos(phase). The quadrature component is
        // dropped, which costs nothing for the phase = 0 form every model in
        // the suite writes and is wrong by cos for the rest. Upgrade path is
        // an `ac_gens` export beside `noise_gens`, carrying (mag, phase) for a
        // host that solves a complex system — the same shape §4.6.4 uses, and
        // the reason this is a conditional rather than an export today is that
        // the contract has no complex side to hand it to.
        if (std.mem.eql(u8, name, "ac_stim")) {
            self.uses_inst = true;
            const mag = try self.argF64(d.args, 1, "1.0");
            const phase = try self.argF64(d.args, 2, "0.0");
            try self.b("S.con(if (", .{});
            if (d.args.len == 0)
                try self.b("inst.analysis_kind == .ac", .{})
            else
                try self.analysisMatch(d.args[0..1]);
            try self.b(") ({s}) * @cos({s}) else 0.0)", .{ mag, phase });
            return;
        }

        if (name.len != 0 and name[0] == '$') return self.emitSysCall(name, d.args, inst);

        return self.abort("VerA: unhandled call `{s}`", .{name});
    }

    pub fn abort(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.fatal == null) self.fatal = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.b("S.con(0.0)", .{});
    }

    /// §4.6.1 the analysis-name arguments are string constants; the comparison
    /// against the runtime pass is what the host answers.
    fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void {
        var first = true;
        for (args) |a| {
            const def = self.mir.valueDef(self.an.rv(a));
            if (def != .str_const) continue;
            if (!first) try self.b(" or ", .{});
            first = false;
            const s = def.str_const;
            if (std.mem.eql(u8, s, "static")) {
                // §4.6.1 "static" is true in any analysis that computes a DC
                // operating point.
                try self.b("(inst.analysis_kind == .static or inst.analysis_kind == .ic or " ++
                    "inst.analysis_kind == .nodeset or inst.analysis_kind == .dc)", .{});
            } else if (std.mem.eql(u8, s, "tran")) {
                // §4.6.1 "tran" is true during "the initial DC and time-sweep
                // phases of a transient" — the ic phase counts. This is what
                // lets a source spell ngspice's TRANOP/DCOP split: the
                // transient's own operating point evaluates waveform(0) while
                // .op/.dc/.ac bias at the DC value
                // (`analysis("static") && !analysis("tran")`).
                try self.b("(inst.analysis_kind == .tran or inst.analysis_kind == .ic)", .{});
            } else if (isAnalysisName(s)) {
                try self.b("inst.analysis_kind == .{s}", .{s});
            } else {
                try self.b("false", .{});
            }
        }
        if (first) try self.b("false", .{});
    }

    /// `inst` is the call's own MIR instruction, and it is here for exactly one
    /// reason: §9.5.3's formatter needs storage for the bytes it produces that
    /// outlives the expression (a string slot is a `[]const u8`), and the
    /// instruction id is the per-call-site name `zSBuf` keys that storage by.
    fn emitSysCall(self: *Gen, name: []const u8, args: []const Mir.Value, inst: Mir.Inst) Error!void {
        const eq = std.mem.eql;
        // §9.4/§9.7.3 — only when the caller asked for a printing artifact. In a
        // device they fall through to `void_tasks` below.
        if (self.display == .emit and Lower.isDisplayTask(name))
            return cg_display.emitDisplayTask(self, name, args);
        // §9.7.1/§9.7.2 — same gate: in the printing artifact the run ends at
        // the call's position among the prints; in a device the call is dead
        // (`Lower.isSimCtlTask` calls join the display chain and nothing else,
        // so under `.drop` nothing ever renders one — the fall-through to
        // `void_tasks` below is for a model that reads the void result).
        if (self.display == .emit and Lower.isSimCtlTask(name))
            return cg_display.emitSimCtl(self, name, args);
        // §9.5 the descriptor family. Real kernels only in the display unit (see
        // `emitting_display`); rendered but discarded in any other unit of the
        // same artifact, so the slice `callArgIsValue` asked for is consumed.
        //
        // NOT gated on the display mode, and that is the point: `buildJobs`
        // queues a display unit only under `.emit`, so `emitting_display` is
        // already false throughout a `.drop` build and every §9.5 name lands in
        // `emitFileCallDropped` — the one place that answers with the type
        // `Analysis.callTy` gave the call. Gating here instead sent them to
        // `void_tasks`' blanket `S.con(0.0)`, which put an `S` in the `i64` slot
        // §9.5.1 says a descriptor is: `const t0: i64 = S.con(0.0);`, `--emit-zig`
        // exit 0, and the failure deferred to whoever compiled the device.
        if (Lower.isFileCall(name)) {
            if (!self.emitting_display) return self.emitFileCallDropped(name, args);
            return cg_display.emitFileCall(self, name, args, @intFromEnum(inst));
        }
        // §9.10 environment.
        if (eq(u8, name, "$temperature")) {
            self.uses_inst = true;
            return self.b("S.con(inst.temperature)", .{});
        }
        if (eq(u8, name, "$vt")) {
            // k/q = 8.617333262e-5 V/K (§9.10 $vt = kT/q).
            if (args.len == 0) {
                self.uses_inst = true;
                return self.b("S.con(inst.temperature * 8.617333262145179e-5)", .{});
            }
            try self.b("(", .{});
            try self.renderVal(args[0], .real);
            return self.b(").scale(8.617333262145179e-5)", .{});
        }
        if (eq(u8, name, "$abstime") or eq(u8, name, "$realtime")) {
            self.uses_inst = true;
            return self.b("S.con(inst.abstime)", .{});
        }
        // §5.10 the retained value of an event-assigned variable. `Lower` put
        // this in the entry block in place of the declared initializer, so
        // reading the variable before the event has ever fired reads the
        // `Instance` default and after it the last accepted value.
        if (eq(u8, name, "$held_real") or eq(u8, name, "$held_int")) {
            self.uses_inst = true;
            const f = self.held_names[self.heldIdx(args)];
            return if (eq(u8, name, "$held_int"))
                self.b("inst.{s}", .{f})
            else
                self.b("S.con(inst.{s})", .{f});
        }
        if (eq(u8, name, "$mfactor")) { // §6.3.6
            self.uses_inst = true;
            return self.b("S.con(inst.mfactor)", .{});
        }
        // §9.18 Table 9-29 hierarchical system parameters. Their value is the
        // top-level value combined down the instantiation hierarchy; VerA
        // elaborates exactly ONE flat module, so the device IS the top level
        // and the table's "Top-Level Value" column is exact — not a substitute.
        // ($mfactor is the exception above: the host scales the whole stamp by
        // it, so it stays a settable Instance field.)
        if (eq(u8, name, "$xposition") or eq(u8, name, "$yposition"))
            return self.b("S.con(0.0)", .{}); // 0.0 m
        if (eq(u8, name, "$angle"))
            return self.b("S.con(0.0)", .{}); // 0 degrees
        if (eq(u8, name, "$hflip") or eq(u8, name, "$vflip"))
            return self.b("S.con(1.0)", .{}); // +1
        // §9.15 $simparam(name [, fallback]), in the clause's own order: the
        // KNOWN value first, the fallback only for a name this engine does not
        // have ("its value is returned IF param_name is not known"). The list
        // and the values are `Lower.simparamValue`, so the name that reaches
        // here answered is the same set that escaped E0811 at lowering.
        if (eq(u8, name, "$simparam")) {
            const nm = self.strArg(args, 0) orelse "";
            // Host-published first: `simparamValue` also answers `tnom`, but
            // only as the DECLARED default (`Lower.simparamHostField`).
            if (Lower.simparamHostField(nm)) |f| {
                self.uses_model = true;
                return self.b("S.con(model.{s})", .{f});
            }
            if (self.lower.simparamValue(nm)) |v| return self.b("S.con({s})", .{try self.fmtF64(v)});
            if (args.len > 1) return self.b("S.con({s})", .{try self.f64Expr(args[1])});
            // Unknown, no fallback: E0811 already refused this compile unless
            // the name was not a literal, in which case zero is the only answer
            // available and the model asked for a name nothing could resolve.
            return self.b("S.con(0.0)", .{});
        }
        // §9.15 "Table 9-28 gives a list of simulation string parameter names
        // that shall be supported by $simparam$str" — no "if they support the
        // parameter" escape, unlike Table 9-27's numeric side, so the two names
        // this engine actually knows are answered. The rest ("cwd", "instance",
        // "path") describe the host's filesystem and instantiation hierarchy,
        // which a flat elaborated device has no view of: "" is the honest answer
        // there, an invented path is not.
        if (eq(u8, name, "$simparam$str")) {
            const nm = self.strArg(args, 0) orelse "";
            // §4.6.1's analysis names ARE the `AnalysisKind` tag spellings, so
            // the enum is the table — no second list to drift out of step.
            if (eq(u8, nm, "analysis_type")) {
                self.uses_inst = true;
                return self.b("@tagName(inst.analysis_kind)", .{});
            }
            if (eq(u8, nm, "module")) return self.b("\"{f}\"", .{std.zig.fmtString(self.mir.name)});
            return self.b("\"\"", .{});
        }
        // §9.19 $param_given / $port_connected.
        if (eq(u8, name, "$param_given")) {
            const def = if (args.len > 0) self.mir.valueDef(self.an.rv(args[0])) else Mir.Def.undef;
            if (def == .param_ref) {
                self.uses_model = true;
                return self.b("@as(i64, @intFromBool(model.{s}__given))", .{self.p_names[def.param_ref]});
            }
            return self.b("@as(i64, 0)", .{});
        }
        if (eq(u8, name, "$port_connected")) {
            // Every port of an elaborated device instance is connected; an
            // unconnected one is the host's business (§6.5.6).
            return self.b("@as(i64, 1)", .{});
        }
        // §9.20 node aliases. Every §9.20 validity rule was decided at lowering
        // (E0812), so what is left here is the RETURN: "one (1) if the
        // hierarchical_reference_string points to a valid continuous node and
        // zero (0) otherwise". This engine elaborates ONE FLAT MODULE, so there
        // is no instance hierarchy for such a string to resolve into — no
        // reference is valid, the answer is zero for every call, and there is no
        // second matrix position to merge the named node with. That is why the
        // topology edit itself is absent rather than stubbed: a wrong merge
        // corrupts the solution silently, and a reference that cannot resolve is
        // not an error but this value (tests/fixtures/ch09_system_tasks/105).
        if (eq(u8, name, "$analog_node_alias") or eq(u8, name, "$analog_port_alias"))
            return self.b("@as(i64, 0)", .{});
        // §9.12 command-line plusargs: absent.
        if (eq(u8, name, "$test$plusargs") or eq(u8, name, "$value$plusargs"))
            return self.b("@as(i64, 0)", .{});
        // §9.22/§9.23 driver & receiver access do NOT appear here. They used to,
        // answering the constant 0 (and -1.0 for $driver_delay's no-pending-value
        // sentinel) on the argument that a flat analog device has no digital
        // drivers so zero is the true count. The argument is wrong at the first
        // step: §9.22 paragraph 3 says "Driver access functions can only be
        // called from connect modules", so the call itself is illegal in every
        // module VerA can compile and there is no result to render. Refused at
        // lowering now (E0818, `isConnectModuleOnlySysFunc`), which is where the
        // call site is known — so this backend never sees one of these names.
        // §4.5.15 $limit: the limiting ALGORITHM is a convergence aid the host
        // owns (contract `limit`); the LRM lets a simulator that does not apply
        // it return the access function unchanged, which is what happens here.
        // §9.17.3 the USER-FUNCTION form. `lower.lowerLimitUser` has already
        // inlined the function body and latched its return into the site's
        // `LimitSlot`; what is left is the one thing only the backend can
        // spell — the returned value carries the ACCESS FUNCTION's derivative,
        // not the limiter's, so the clamp lands as a constant shift on the
        // probe. args = (vnew, vlim). See `zLimitUf`.
        if (eq(u8, name, "$limit$uf") and args.len == 2) {
            // `.val()` on two x-dependent carriers: a vector S would collapse
            // per lane, so this pins them for the same reason `zPow` does.
            self.pinLanes(args[0]);
            self.pinLanes(args[1]);
            return self.helper2("zLimitUf", args[0], args[1]);
        }
        if (eq(u8, name, "$limit"))
            return self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
        if (eq(u8, name, "$clog2"))
            return self.intCall1("zClog2", if (args.len > 0) args[0] else .zero);
        // §9.11 conversions. `$rtoi` truncates (Table 9-7); the saturation is
        // ours — the clause is silent on overflow and `@intFromFloat` is UB in
        // the ReleaseFast artifact a host actually links.
        if (eq(u8, name, "$rtoi")) {
            if (args.len > 0) self.pinLanes(args[0]); // scalar collapse
            try self.b("std.math.lossyCast(i64, @trunc((", .{});
            try self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val()))", .{});
        }
        if (eq(u8, name, "$itor")) {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try self.renderVal(if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        }
        // §9.11 Table 9-8 $realtobits/$bitstoreal: the IEEE-754 bit pattern of
        // the real, verbatim. Exactly representable in the i64 that lowering
        // gives integers, so this is the spec function, not an approximation.
        if (eq(u8, name, "$realtobits")) {
            if (args.len > 0) self.pinLanes(args[0]); // scalar collapse
            try self.b("@as(i64, @bitCast((", .{});
            try self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val()))", .{});
        }
        if (eq(u8, name, "$bitstoreal")) {
            try self.b("S.con(@as(f64, @bitCast(", .{});
            try self.renderVal(if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        }
        // §9.5.3 `$swrite`/`$sformat`, arriving as the synthetic `$sformat` whose
        // operands are the format and its arguments — the destination is gone,
        // because lowering made this call the right-hand side of an assignment to
        // it. The text goes into this call site's own scratch row.
        if (eq(u8, name, "$sformat"))
            return cg_display.emitStringFormat(self, args, @intFromEnum(inst));
        // §9.5.4.2 `$sscanf`: the count, and the three item flavours lowering
        // picks from the destination's declared type. All four are pure functions
        // of the same two strings, so nothing here has to sequence them.
        //
        // ponytail: an item the scan never reached reads as zero. C — and
        // §9.5.4.2, which inherits C's formatter — leaves such a destination
        // UNTOUCHED, which would need the assignment to become a select on a
        // per-item `found` flag. Reading a destination past the returned count is
        // the only way to observe the difference.
        if (eq(u8, name, "$table_model")) return self.emitTable(args); // §9.21
        // §3.2.2 runtime array index — one switch, see `emitIdx`.
        if (eq(u8, name, "$idx")) return self.emitIdx(args, .real);
        if (eq(u8, name, "$idx$int")) return self.emitIdx(args, .int);
        if (eq(u8, name, "$idx$str")) return self.emitIdx(args, .str);
        // §9.13 Table 9-10, in the shape `Lower.lowerRandom` rewrote it: the
        // seed's incoming value, then the distribution's parameters. Every one is
        // a pure function of that seed and carries no derivative — a variate is a
        // constant of the operating point, which is what makes it admissible in a
        // residual at all (see `rng_kernels.zig`).
        if (std.mem.startsWith(u8, name, "$rng$")) return self.emitRng(name, args);
        if (eq(u8, name, "$sscanf")) return self.emitScan("zScanN", args, .int);
        if (eq(u8, name, "$sscanf$int")) return self.emitScan("zScanI", args, .int);
        if (eq(u8, name, "$sscanf$real")) return self.emitScan("zScanR", args, .real);
        if (eq(u8, name, "$sscanf$str")) return self.emitScan("zScanS", args, .str);
        // §9.4/§9.7 display and control tasks: void. Lowering keeps them as
        // calls; their result is never read, so this only fires if a model
        // assigns one — and every one of these is real-valued (`Analysis.callTy`
        // types nothing here `.int`), which is what makes ONE answer correct for
        // the whole list.
        //
        // The §9.5 descriptor family is NOT here. It used to be, for the case
        // where a device carries no host file table — but that answer is
        // `emitFileCallDropped`'s, which reads `callTy` and returns `@as(i64, 0)`
        // for the eight integer-valued names §9.5.1 defines a descriptor as. The
        // blanket `S.con(0.0)` below typed them real and the two disagreed.
        // `Lower.isFileCall` above now claims every §9.5 spelling in BOTH display
        // modes, so nothing in that family reaches this list.
        const void_tasks = [_][]const u8{
            "$display",       "$displayb",  "$displayo",   "$displayh",
            "$write",         "$writeb",    "$writeo",     "$writeh",
            "$strobe",        "$strobeb",   "$strobeo",    "$strobeh",
            "$monitor",       "$monitoron", "$monitoroff", "$debug",
            "$finish",        "$stop",      "$fatal",      "$error",
            "$warning",       "$info",
            "$discontinuity", "$bound_step",
        };
        for (void_tasks) |t| {
            if (eq(u8, name, t)) return self.b("S.con(0.0)", .{});
        }
        // IEEE 1364 §17.11 math functions, carried into Verilog-AMS: `$ln`,
        // `$exp`, `$pow`, … are the same functions as their bare spellings.
        const bare = name[1..];
        if (mathOpByName(bare)) |op| {
            if (Mir.opClass(op) == .unary and args.len >= 1) return self.renderOp(op, args[0], .f_zero, .real);
            if (Mir.opClass(op) == .binary and args.len >= 2) return self.renderOp(op, args[0], args[1], .real);
        }
        if (eq(u8, bare, "abs") and args.len >= 1) return self.method1(args[0], "abs");
        if ((eq(u8, bare, "min") or eq(u8, bare, "max")) and args.len >= 2)
            return self.method2(args[0], if (bare[1] == 'i') "min" else "max", args[1]);

        // Nothing above claimed the name, so it is not a Chapter 9 function, not
        // an Annex D macro and not a §4.5 operator: it is an UNREGISTERED system
        // function. §2.8.3 makes `$name` grammatical and lists "defined using the
        // VPI as described in Clause 11 and Clause 12" as one of its definition
        // sites; §12.32's vpi_register_analog_systf() hands the APPLICATION a
        // compiletf routine, so what an unknown systf means is the host's
        // decision and not this compiler's. §12.32.3's own sampnhold listing
        // puts one in a contribution. No clause makes the source an error, so it
        // may not be rejected — see W0852.
        //
        // THE SET THAT ARRIVES HERE IS ACTUALLY EMPTY OF LRM NAMES, which is
        // what makes the answer below safe rather than a blanket amnesty: every
        // Chapter 9 name is either implemented above or diagnosed by a RULE
        // before codegen (E0806 for a digital-only row of the §9.2 tables, E0808
        // for the retired v1.0 `$limexp`, E0812, E0813, E0815, E0816). Probing
        // the whole of ch9 by hand, the only names that reach this line are ones
        // Verilog-AMS defines nowhere — `$countdrivers`, `$rose`, `$fell`, and a
        // typo. Add an unimplemented LRM function above, not here.
        //
        // WHY THIS IS NOT THE SILENT-ZERO THE REST OF THIS FILE REFUSES. Every
        // `abort` here stands where the LRM fixes a number and a substitute
        // would contradict it (E0515's control arguments, a filter VerA cannot
        // build). This name has no such number: the language defines no value
        // for an unregistered systf at all — §12.32.3 never initializes
        // sampler->value before the first update callback and returns that field
        // through vpi_put_value() — so there is nothing to be wrong about, only
        // an absent host. The compromise is that it is LOUD: one warning per
        // call site, `--deny=W0852` restores the refusal for anyone who wants a
        // host-less build to fail instead.
        if (self.diags) |bag| try bag.add(
            .codegen,
            .W0852,
            self.lower.tokenSpan(self.mir.instTok(inst)),
            "`{s}` is not a system function this compiler defines, so it is exported in " ++
                "`systf_calls` for a VPI application to supply; a host that binds none " ++
                "will not build",
            .{name},
        );
        // A systf crosses to the host through concrete f64s (`.val()` per
        // argument, partials written back) — a per-lane crossing does not
        // exist, so it pins regardless of what the host computes.
        self.lane_pinned = self.lane_pinned or !self.emitting_display;
        return self.emitSystfCall(name, args);
    }

    /// §2.8.3/§12.32: hand one unresolved `$name` to the host's VPI application.
    ///
    /// WHY THIS IS NOT A CALL THROUGH A `fn (args: []S) S` POINTER, which is what
    /// every other hook in the contract would look like. `eval` is generic over
    /// S and is instantiated at least twice — a plain f64 for the residual, a
    /// derivative-carrying dual for the Jacobian — and a function POINTER cannot
    /// be generic over S. So the boundary is concrete: the host returns the
    /// value and writes the partials, and this rebuilds the dual.
    ///
    /// The reassembly is the whole trick. `arg.addC(-arg.val())` has VALUE zero
    /// and DERIVATIVE d(arg), so `.scale(p)` makes a term that contributes p·d(arg)
    /// to the derivative and nothing at all to the value. Summed onto `S.con(v)`
    /// the result carries the host's value with the host's partials grafted on —
    /// and on the plain-f64 instantiation every one of those terms is exactly
    /// zero, so the residual reads `v` and nothing else. That is §12.22.1's
    /// `derivtf` arrived at from the other side, and it is what keeps `eval` a
    /// pure function of x, which the host's own Newton iteration depends on.
    ///
    /// The arguments are bound to `const`s first rather than rendered twice:
    /// each is needed once for its value and once for its derivative, and an
    /// argument expression can be an arbitrary subtree.
    fn emitSystfCall(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
        const k = for (self.systf_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) break i;
        } else blk: {
            try self.systf_names.append(self.arena, name);
            break :blk self.systf_names.items.len - 1;
        };
        // `inst` is the generated device's own parameter, and `emitUnit` patches
        // it to `_` when nothing read it. This reads it.
        self.uses_inst = true;

        const label = self.systf_sites;
        self.systf_sites += 1;
        try self.b("zs{d}: {{\n", .{label});
        for (args, 0..) |a, j| {
            try self.b("        const zs{d}a{d} = ", .{ label, j });
            try self.renderVal(a, .real);
            try self.b(";\n", .{});
        }
        // `validateHost` is what makes this unwrap safe, and it is the reason
        // the check exists: with no application bound there is no value here,
        // not a wrong one — §12.32.3 never initializes its sampler's value
        // before the first callback, so the language fixes no default to fall
        // back to. Refusing the HOST's build is the only outcome that cannot be
        // mistaken for a working device.
        try self.b("        const zsh = inst.systf.?;\n", .{});
        try self.b("        const zsv = [_]f64{{", .{});
        for (args, 0..) |_, j| try self.b("{s} zs{d}a{d}.val()", .{ if (j == 0) "" else ",", label, j });
        try self.b(" }};\n", .{});
        try self.b("        var zsp: [{d}]f64 = undefined;\n", .{args.len});
        try self.b("        var zsr = S.con(zsh.call(zsh.ctx, {d}, &zsv, &zsp));\n", .{k});
        for (args, 0..) |_, j|
            try self.b("        zsr = zsr.add(zs{d}a{d}.addC(-zsv[{d}]).scale(zsp[{d}]));\n", .{ label, j, j, j });
        try self.b("        break :zs{d} zsr;\n    }}", .{label});
    }

    /// The `$name`s this device leaves to a VPI application. Emitted after the
    /// units because that is when the set is known — nothing before `renderCall`
    /// can say which names it will fail to resolve without repeating all of it.
    fn emitSystfTable(self: *Gen) Error!void {
        if (self.systf_names.items.len == 0) return;
        try self.w(
            \\/// §2.8.3 `$name`s this device leaves to a VPI application
            \\/// (§12.32 `vpi_register_analog_systf`). Position k is the `k` the
            \\/// device passes to `Instance.systf.?.call`. A host linking this
            \\/// device shall bind them — see `contract.validateHost`.
            \\pub const systf_calls = [_]contract.Systf{{
            \\
        , .{});
        for (self.systf_names.items) |n| try self.w("    .{{ .name = \"{s}\" }},\n", .{n});
        try self.w("}};\n\n", .{});
    }

    /// A §9.5 call in a unit that is NOT the display unit: the descriptor answers
    /// what §9.5.1 says a device with no file table has to answer, and the
    /// operands are consumed rather than dropped.
    ///
    /// Consumed, because `callArgIsValue` said they were live and the slice
    /// therefore declared them — an unused local is a hard error in Zig, so the
    /// two have to agree. The alternative, teaching `callArgIsValue` which unit it
    /// is being asked about, would thread the display flag through `UnitPlan`'s
    /// whole marking pass to save four characters of generated text.
    ///
    /// The whole of a `display == .drop` build is "not the display unit", so this
    /// is also every §9.5 call in a device. `callArgIsValue` marks nothing live
    /// there, which agrees the other way round: no slot is declared, and there is
    /// nothing to consume. What matters in both modes is the TYPE below — the
    /// caller's slot is `Analysis.callTy`'s, and §9.5's descriptors are integers.
    fn emitFileCallDropped(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
        _ = args; // `UnitPlan.dispHere` did not mark them: there is nothing here to read them
        // §9.5.1 reserves 0 for `$fopen`'s failure, §9.5.4.1 for "an error occurs
        // reading", §9.5.8 for "no EOF has been detected" and §9.5.7 for "the most
        // recent operation did not result in an error" — so zero is the right
        // answer here and not a stub. §9.5.5's positioning family is the one
        // exception: its error return is EOF, but `$ftell` on a descriptor that
        // was never opened has no offset to report either way.
        try self.b("{s}", .{switch (Analysis.callTy(name)) {
            .real => "S.con(0.0)",
            .int => "@as(i64, 0)",
            .str => "\"\"",
        }});
    }

    pub fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8 {
        if (i >= args.len) return null;
        const def = self.mir.valueDef(self.an.rv(args[i]));
        return if (def == .str_const) def.str_const else null;
    }

    /// §4.5 stateful analog operators. The operator's INPUT is a named unit of
    /// its own, so the state field and `updateState`'s read of the input share
    /// one stable key and adding an unrelated operator renumbers nothing.
    fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void {
        self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
        const unit = self.op_unit[@intFromEnum(inst)];
        if (unit == none_u32) return self.b("S.con(0.0)", .{});
        const n = self.unit_names[unit];
        // Only the operators whose kernel needs the CURRENT input read it; the
        // pure-history ones answer from `Instance` alone. Rendering the input
        // for one of those would set `uses_x`/`uses_model` for text that is
        // never emitted, and `patchParam` would then leave a named parameter
        // nothing references — which Zig rejects.
        const needs_in = opNeedsInput(k);
        // The input is a `Mir.Value` of the body being rendered, not a call to a
        // declaration of its own: `planCommon` makes every operator input a
        // field of the core, so inside the core it is the local that already
        // holds it and inside the §9.4 `display` unit it is a cache read.
        // `callArgIsValue` still returns false for an operator argument — the
        // value is live because it is a core target, not because this call
        // marked it, which is what keeps the §4.5.2 one-evaluation-per-step rule.
        const in = if (needs_in)
            try self.renderToArena(if (args.len == 0) .f_zero else args[0], .real)
        else
            "";
        self.uses_inst = true;
        switch (k) {
            // §4.5.11 the cascade reads its sections from Model on every
            // evaluation and is LINEAR in the current input, so the Jacobian
            // `b0/a0` it hands the solver is exact.
            .laplace => {
                const p = try cg_filters.filterPlan(self, inst, args);
                if (p.err) |m| return self.abort("{s}", .{m});
                // `__sec` takes a `*const Model` whatever its coefficients read,
                // so the call site is a use of `model` even when `filterPlan`
                // saw no Model read — without this the enclosing unit's
                // parameter gets patched to `_` and the device does not compile.
                self.uses_model = true;
                try self.b("zLaplace(S, {d}, {d}, {s}, {s}__sec(model), inst.dt, &inst.{s}__u, &inst.{s}__y)", .{
                    p.ns, p.deg, in, n, n, n,
                });
            },
            // §4.5.12 "acts like a simple sample-and-hold which samples every T
            // seconds": between samples the output does not depend on the
            // current unknowns, so it enters the residual as a constant — the
            // same companion model `absdelay` uses.
            .zi => {
                const p = try cg_filters.filterPlan(self, inst, args);
                if (p.err) |m| return self.abort("{s}", .{m});
                // Same reason `.laplace` above forces it: `__sec` takes a
                // `*const Model` whatever its coefficients read.
                self.uses_model = true;
                try self.b("zZiHold(S, {d}, {d}, {s}, {s}__sec(model), inst.dt, inst.{s}__out)", .{
                    p.ns, p.deg, in, n, n,
                });
            },
            .ddt => try self.b("zDdt(S, {s}, inst.{s}__prev, inst.dt)", .{ in, n }),
            // §4.5.4 `idt(expr, ic, assert)`: "idt() returns the initial
            // conditions during DC and IC analyses, and whenever assert is
            // nonzero. Once assert becomes zero, idt() returns the integral of
            // the argument starting from the last instant where assert was
            // nonzero." The reset is a plain select on the accumulator, which
            // `updateState` holds at `ic` for as long as assert is nonzero.
            .idt => if (args.len >= 3) try self.b(
                "zIdtReset(S, {s}, inst.{s}__acc, inst.dt, {s}, {s})",
                .{ in, n, try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0") },
            ) else try self.b("zIdt(S, {s}, inst.{s}__acc, inst.dt, {s})", .{
                in, n, try self.argF64(args, 1, "0.0"),
            }),
            .idtmod => try self.b("zIdtmod(S, {s}, inst.{s}__acc, inst.dt, {s}, {s}, {s})", .{
                in,                              n,
                try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0"),
                try self.argF64(args, 3, "0.0"),
            }),
            .absdelay => try self.b(
                "zAbsdelay(S, {s}, &inst.{s}__t, &inst.{s}__v, inst.{s}__head, inst.abstime, inst.dt, {s})",
                .{ in, n, n, n, try self.argF64(args, 1, "0.0") },
            ),
            // §4.5.8 the ramp reads its ORIGIN out of `Instance` — where the
            // output was when the current excursion began, and when that was —
            // and takes its TARGET from the current input, so the companion
            // model is linear in the unknowns with slope `(t-t0)/tt`. That is
            // the derivative of the piecewise-linear function itself, not an
            // approximation of it.
            .transition => {
                const t = try self.transitionTimes(args);
                try self.b("zTransition(S, {s}, inst.{s}__from, inst.{s}__t0, inst.abstime, inst.dt, {s}, {s})", .{
                    in, n, n, t[0], t[1],
                });
            },
            .slew => {
                const r = try self.slewRates(args);
                try self.b("zSlew(S, {s}, inst.{s}__prev, inst.dt, {s}, @abs({s}))", .{
                    in, n, r[0], r[1],
                });
            },
            .last_crossing => try self.b("S.con(inst.{s}__t_last)", .{n}),
            // §5.10.3 THE EVENT IS DECIDED HERE, not in `updateState`. The flag
            // used to be read out of `Instance`, and `updateState` runs on the
            // ACCEPTED solution — after this point has been evaluated — so every
            // cross()/timer() event was observed one timepoint late, the exact
            // mirror of "at that time point, the event evaluates to True".
            // `updateState` now only advances `__prev`/`__next`.
            // §5.10.3.1 "The cross() function will not generate events for
            // non-transient analyses, such as ac, dc, or noise analyses … it can
            // only generate an event after the simulation time has advanced from
            // zero." Both halves are the guard: the analysis has to be a
            // transient AND a step has to have been taken, which is what a
            // positive `dt` means everywhere else in this file. (§5.10.3.2
            // `above` is the operator that is explicitly exempt from both.)
            .cross => try self.b("S.con(if (inst.analysis_kind == .tran and inst.dt > 0.0 and ({s}) and ({s})) 1.0 else 0.0)", .{
                try self.crossTest(n, args, try std.fmt.allocPrint(self.arena, "({s}).val()", .{in})),
                try self.enableTest("cross", args),
            }),
            // §5.10.3.3 fires at `start_time` and every `period` after it.
            // `__next` carries the schedule, but it initialises to 0.0 and is
            // only clamped up to `start_time` by `updateState`, so the clamp is
            // repeated here — without it a `timer(1n, …)` fires at t = 0.
            .timer => try self.b("S.con(if (inst.abstime >= @max(inst.{s}__next, ({s}).val()) and ({s})) 1.0 else 0.0)", .{
                n, in, try self.enableTest("timer", args),
            }),
            // §5.10.3.2 "above() generates a monitored analog event to detect
            // threshold crossings in analog signals when the expression crosses
            // zero (0) from below". CROSSES, not "is above": the test is
            // edge-triggered against the last accepted value, exactly like
            // `cross`, and it was a bare `expr > 0.0` — which re-fires on every
            // solution while the expression stays positive, so a `@(above(x))`
            // latch tracked its probe instead of holding the value it sampled.
            //
            // No `.tran and dt > 0.0` guard, unlike `cross`: above() is the
            // operator §5.10.3.2 explicitly exempts from both restrictions
            // ("can generate an event during initialization", "during a dc
            // sweep, the above() function shall also generate an event when the
            // expression crosses zero from below"). The initialisation case is
            // the `__prev = 0.0` initialiser — see `emitInstance`.
            .above => try self.b("S.con(if (inst.{0s}__prev <= 0.0 and ({1s}).val() > 0.0 and ({2s})) 1.0 else 0.0)", .{
                n, in, try self.enableTest("above", args),
            }),
            // §9.17 tasks return no value ("It does not return a value").
            // Unreachable in practice — lowering never leaves one in an eval
            // expression — but a void task read as a value is a zero, not a
            // crash.
            .bound_step, .discontinuity => try self.b("S.con(0.0)", .{}),
            .none => unreachable,
        }
    }

    /// §4.5.8 `transition(expr, td, rise_time, fall_time)`: the two times, as
    /// emitted f64 expressions, in that order.
    ///
    /// TWO, not one. This used to return a single first-order lag constant
    /// `(rise + fall)*0.5/2.2`, which made `transition(V, 0, 4n, 8n)` and
    /// `transition(V, 0, 8n, 4n)` the same filter — while §4.5.8 says the
    /// output "forces all positive transitions of expr to occur over rise_time
    /// and all negative transitions to occur in fall_time". Averaging them is
    /// not an approximation of that sentence, it is a different filter.
    ///
    /// §4.5.8's defaulting is a two-step fall-through and both steps are here:
    ///
    ///   "If only a positive rise_time value is specified, the simulator uses
    ///    it for both rise and fall times."  → `fall` defaults to `rise`.
    ///   "If neither rise_time nor fall_time are specified OR ARE EQUAL TO ZERO
    ///    (0.0), the rise and fall time default to the value defined by
    ///    `default_transition."  → and §10.3 scopes that to the directive
    ///    "which immediately precedes the transition filter".
    ///
    /// Zero is spelled as absent by the clause itself, which is why the fold is
    /// consulted and not just the argument count: `transition(x, 0, 0.0)` takes
    /// the directive exactly as `transition(x)` does. A time that is not
    /// foldable is left alone — it is a parameter expression, and the clause
    /// conditions on the VALUE, which is a run-time fact there.
    fn transitionTimes(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
        const dflt = try self.defaultTransition();
        const rise = try self.transitionTime(args, 2, dflt orelse "0.0");
        const fall = try self.transitionTime(args, 3, dflt orelse rise);
        return .{ rise, fall };
    }

    fn transitionTime(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
        if (i >= args.len) return dflt;
        // `resolve_params = false`: a zero through the DECLARED default is not
        // a zero — `transition(x, 0, tr)` with `tr` defaulting to 0.0 but
        // overridden on the model card used to take `default_transition
        // forever. Only a time that is zero WITHOUT parameters is spelled-
        // absent at compile time.
        if (self.an.foldConst(args[i], 0, false)) |c| {
            if (c.f == 0.0) return dflt;
            return self.f64Expr(args[i]); // a known-nonzero literal, as before
        }
        const e = try self.f64Expr(args[i]);
        // §4.5.8 conditions on the VALUE ("… or are equal to zero (0.0)"),
        // which for a parameter time is a run-time fact — so the fall-through
        // to `dflt` is emitted as a select. Skipped when `dflt` is the bare
        // 0.0 fallback: `zTransFrac` already reads a non-positive time as the
        // simulator's own default (an instantaneous edge), so the select would
        // choose between two spellings of the same thing.
        if (std.mem.eql(u8, dflt, "0.0")) return e;
        return std.fmt.allocPrint(self.arena, "(if (({s}) != 0.0) ({s}) else ({s}))", .{ e, e, dflt });
    }

    /// §10.3 the `` `default_transition `` in force AT THE CALL BEING EMITTED,
    /// as an emitted f64 literal, or null when no directive precedes it.
    ///
    /// Positional, because the clause is: "the default rise and fall times for
    /// a transition filter are derived from the transition_time value of the
    /// directive which IMMEDIATELY PRECEDES the transition filter." So the walk
    /// is backwards from the call's own token offset and stops at the first
    /// directive at or before it — which is what makes a second directive
    /// supersede a first rather than being ignored by a latched value.
    ///
    /// `ctrl_tok` is the operator call's token, set by `emitOperator` and by
    /// the `updateState` loop before either asks for the times, so both sides
    /// of the operator resolve the same directive.
    fn defaultTransition(self: *Gen) Error!?[]const u8 {
        const list = self.lower.default_transitions;
        if (list.len == 0) return null;
        if (self.ctrl_tok == Mir.no_tok or self.ctrl_tok >= self.lower.tok_starts.len) return null;
        const at = self.lower.tok_starts[self.ctrl_tok];
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (list[i].at <= at) return try self.fmtF64(list[i].time);
        }
        return null;
    }

    /// §4.5.9's two rate limits, for the two places that emit a `zSlew` call.
    ///
    /// "If the max_neg_slew_rate is not specified, it defaults to the opposite
    /// of the max_pos_slew_rate." The kernel takes `@abs` of the negative limit,
    /// so "the opposite" is spelled by reusing the positive expression verbatim.
    /// The old default of `1e300` left every falling edge UNLIMITED while the
    /// rising edge was held — an asymmetry the source never asked for, and one
    /// that only showed up in a transient.
    fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
        const pos = try self.argF64(args, 1, "1e300");
        return .{ pos, try self.argF64(args, 2, pos) };
    }

    // =======================================================================
    // Dispatchers — §5.6 residual assembly, §1.3.1.2 reference directions
    // =======================================================================

    fn emitDispatchers(self: *Gen) Error!void {
        self.pat[0] = try self.arena.alloc(u64, self.n_u);
        self.pat[1] = try self.arena.alloc(u64, self.n_u);
        @memset(self.pat[0], 0);
        @memset(self.pat[1], 0);
        self.rows = .{ 0, 0 };

        try self.emitResidual(false);
        var any_q = false;
        for (self.lower.contributions.items) |c| {
            if (self.an.rv(c.react_val) != .f_zero) any_q = true;
        }
        if (any_q) {
            try self.emitResidual(true);
            try self.emitFused();
        }
        // AFTER the dispatchers: the pattern is what they emitted, accumulated
        // row by row as each was written. Zig has no declaration order, so the
        // constant reading last in the file is the one written last.
        try self.emitPattern(any_q);
        try self.emitDisplay();
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
    fn emitPattern(self: *Gen, any_q: bool) Error!void {
        if (self.n_u > 64) return;
        try self.w(
            \\/// §5.6 structural Jacobian: bit `cu` of `jac_pattern[ru]` is set
            \\/// when `∂eval(x)[ru]/∂x[cu]` can be nonzero. A clear bit is a
            \\/// stamp with no physics behind it, and the host may drop it at
            \\/// compile time. Over-approximate: a set bit costs a stamp that
            \\/// happens to be zero, never a missing matrix entry.
            \\
        , .{});
        try self.emitPatternRows("jac_pattern", self.pat[0]);
        try self.emitWrittenRows("jac_rows", "eval", self.rows[0]);
        if (!any_q) return;
        try self.w("/// Same, for `q`'s reactive residual (`dQ/dx`).\n", .{});
        try self.emitPatternRows("q_pattern", self.pat[1]);
        try self.emitWrittenRows("q_rows", "q", self.rows[1]);
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
        for (rows, 0..) |m, i| try self.w("    0x{x:0>16}, // {s}\n", .{ m, self.u_names[i] });
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
    fn emitDisplay(self: *Gen) Error!void {
        if (self.display_name.len == 0) return;
        try self.w(
            \\/// §9.4 run this module's display tasks once, in source order.
            \\pub fn display(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) void {{
            \\    _ = {s}(S, x, model, inst);
            \\}}
            \\
            \\
        , .{self.display_name});
    }

    fn emitResidual(self: *Gen, react: bool) Error!void {
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
        try self.w("inst: *const Instance, _: f64) [n_u]S {{\n    ", .{});
        const at_mut = self.out.items.len;
        try self.w("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
        const stamps = try self.emitStamps(react);

        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
        try self.w("    return res;\n}}\n\n", .{});
    }

    /// The §5.6 stamp rows for one residual half, into a `res` the caller has
    /// already declared. Accumulates `uses_x`/`uses_model`/`uses_inst` and
    /// returns the row count, so the caller can back-patch its own signature.
    ///
    /// Split out of `emitResidual` so `emitFused` can emit BOTH halves against
    /// one `core` call without restating any of this.
    fn emitStamps(self: *Gen, react: bool) Error!u32 {
        var stamps: u32 = 0;
        // Which half `patRow` accumulates into. `eval`/`q` and `evalQ` emit the
        // same rows, so the second pass ORs in bits the first already set.
        self.pat_react = react;
        // ONE core evaluation per residual, not one per contribution. LLVM does
        // not recover this by itself — measured, see `planCommon`'s header — so
        // the number of times the model runs is decided here, in the emitter.
        var opened = false;

        for (self.lower.contributions.items, 0..) |c, i| {
            const val = if (react) self.an.rv(c.react_val) else self.an.rv(c.resist_val);
            // §5.6.1.3 a `.flow` entry whose branch row is runtime-selected is
            // consumed BY that row (`I_b − value`); its KCL current is the ±I_b
            // the potential entry already stamps. Stamping the value here too
            // would inject it twice — once through the unknown, once directly.
            if (c.kind == .direct and c.access == .flow and self.flowIsMerged(i)) continue;
            // §5.6.1.3's three-way rule is decided per cycle. `.on`/`.off` fold
            // to today's static behaviour; `.runtime` keeps the row alive in
            // EVERY case, because the open-circuit form (`res[u] = I_b`) is
            // what pins the branch current when nothing is retained.
            const run_pot: ?Retention = if (c.kind == .direct and c.access == .potential) ret: {
                const r = self.retention(c);
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
                const j = self.switchFlowOf(i) orelse break :blk .f_zero;
                break :blk self.an.rv(self.lower.contributions.items[j].react_val);
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
                        try self.b("const m = core(S, x, model, inst);\n", .{});
                    }
                }
            }
            stamps += 1;
            try self.ind(1);
            try self.b("{{\n", .{});
            try self.ind(2);
            // `.f_zero` is rendered inline, never planned into `core` (see
            // `planCommon`), so there is no `m.f<k>` to read for it.
            if (val == .f_zero)
                try self.b("const c = S.con(0.0);\n", .{})
            else
                try self.b("const c = m.f{d};\n", .{self.lo_idx[@intFromEnum(val)]});
            if (c.kind == .indirect) {
                // §5.6.7 nullor: `out` is driven by a source whose current is
                // the unknown `ib`, and the row is the CONSTRAINT alone —
                // `<probe> − <equation>`. There is deliberately no V(hi,lo)
                // term: "the source voltage needs to be adjusted so that the
                // given equation is satisfied", so the branch voltage is free.
                // The ib column is filled only by the two KCL stamps, which
                // makes the local 2x2 block off-diagonal.
                const u = self.branch_u[i];
                assert(!react); // splitContribution never runs on an indirect
                try self.ind(2);
                try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.u_names[u]});
                try self.stamp(2, c.hi, "add", "ib", uBit(u));
                try self.stamp(2, c.lo, "sub", "ib", uBit(u));
                try self.ind(2);
                self.patRow(@intCast(u), self.an.unknownDeps(val));
                try self.b("res[@intFromEnum(U.{s})] = c;\n", .{self.u_names[u]});
                try self.ind(1);
                try self.b("}}\n", .{});
                continue;
            }
            switch (c.access) {
                .flow => if (self.flowOnlySignalFlowNet(c)) |n| {
                    // §1.3.4.2 a flow signal-flow net has no potential, so its
                    // one unknown IS its flow and the contribution is that
                    // unknown's defining equation. Stamping KCL here instead
                    // would write a row with no `x` in it at all — `e = 0` —
                    // because the quantity the row is about is not a potential
                    // difference. See `flowOnlySignalFlowNet`.
                    if (!react) {
                        try self.ind(2);
                        self.patRow(n, uBit(n) | self.an.unknownDeps(val));
                        try self.b("res[@intFromEnum(U.{0s})] = x[@intFromEnum(U.{0s})].sub(c);\n", .{self.u_names[n]});
                    } else {
                        try self.ind(2);
                        self.patRow(n, self.an.unknownDeps(val));
                        try self.b("res[@intFromEnum(U.{s})] = c.neg();\n", .{self.u_names[n]});
                    }
                } else {
                    // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                    try self.stamp(2, c.hi, "add", "c", self.an.unknownDeps(val));
                    try self.stamp(2, c.lo, "sub", "c", self.an.unknownDeps(val));
                },
                .potential => {
                    // §5.6 branch relation: the branch current is its own
                    // unknown; its row carries V(hi,lo) − <value>.
                    if (run_pot) |ret| {
                        try self.emitSwitchRow(i, c, ret.runtime, react);
                    } else if (!react) {
                        const u = self.branch_u[i];
                        try self.ind(2);
                        try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.u_names[u]});
                        try self.stamp(2, c.hi, "add", "ib", uBit(u));
                        try self.stamp(2, c.lo, "sub", "ib", uBit(u));
                        try self.ind(2);
                        self.patRow(@intCast(u), nodeBit(c.hi) | nodeBit(c.lo) | self.an.unknownDeps(val));
                        try self.b("res[@intFromEnum(U.{s})] = ", .{self.u_names[u]});
                        try self.nodeVoltage(c.hi);
                        try self.b(".sub(", .{});
                        try self.nodeVoltage(c.lo);
                        try self.b(").sub(c);\n", .{});
                    } else {
                        const u = self.branch_u[i];
                        // §5.6.1.2 the reactive part of a branch relation is a
                        // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                        try self.ind(2);
                        self.patRow(@intCast(u), self.an.unknownDeps(val));
                        try self.b("res[@intFromEnum(U.{s})] = c.neg();\n", .{self.u_names[u]});
                    }
                },
            }
            try self.ind(1);
            try self.b("}}\n", .{});
        }

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
        for (self.lower.port_probes.items) |pp| {
            self.uses_x = true;
            stamps += 1;
            try self.ind(1);
            // Reads the FINISHED res[port], so this row's columns are that
            // row's — already accumulated by the contribution loop above.
            self.patRow(pp.u, self.patOf(pp.port) | (if (react) 0 else uBit(pp.u)));
            if (react) {
                try self.b("res[@intFromEnum(U.{s})] = res[@intFromEnum(U.{s})].neg();\n", .{
                    self.u_names[pp.u], self.u_names[pp.port],
                });
            } else {
                try self.b("res[@intFromEnum(U.{0s})] = x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})]);\n", .{
                    self.u_names[pp.u], self.u_names[pp.port],
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
    /// `planCommon` already put every shared subexpression in one core whose
    /// returned struct carries BOTH halves' targets (see its header), and the
    /// two dispatchers just read different fields of it. Measured on a host
    /// SPICE: `<module>__common__core` appeared twice per instance evaluation
    /// with identical inclusive cost, against device evaluation that was ~90%
    /// of a transient. Halving it needs no new analysis, only this entry point.
    ///
    /// Additive on purpose. `eval` and `q` are unchanged and still the §3.1
    /// contract; DC wants the resistive half alone and should keep calling
    /// `eval`. `evalQ` exists only when there IS a reactive half.
    fn emitFused(self: *Gen) Error!void {
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
        try self.w("inst: *const Instance, _: f64) struct {{ res: [n_u]S, q: [n_u]S }} {{\n", .{});
        // Reserved: the hoisted `core` line is INSERTED here afterwards, once
        // both halves have said whether either wants one. Every offset taken
        // above is before this point, so none of them move.
        const at_core = self.out.items.len;

        for ([2]bool{ false, true }) |react| {
            try self.ind(1);
            try self.b("const {s} = blk: {{\n", .{if (react) "qq" else "rr"});
            try self.ind(2);
            const at_mut = self.out.items.len;
            try self.b("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
            self.ind_base = 1;
            const stamps = try self.emitStamps(react);
            self.ind_base = 0;
            if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
            try self.ind(2);
            try self.b("break :blk res;\n", .{});
            try self.ind(1);
            try self.b("}};\n", .{});
        }
        try self.w("    return .{{ .res = rr, .q = qq }};\n}}\n\n", .{});

        // `core_wanted` implies all three are used: `emitStamps` sets `uses_x`
        // for every live row and `uses_model`/`uses_inst` on the same branch
        // that opens the core, so this can never reference a patched-out `_`.
        if (self.core_wanted)
            try self.out.insertSlice(self.gpa, at_core, "    const m = core(S, x, model, inst);\n");

        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
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
    fn emitSwitchRow(self: *Gen, i: usize, c: Lower.Contribution, flag: Mir.Value, react: bool) Error!void {
        const u = self.branch_u[i];
        const partner = self.switchFlowOf(i);
        const split = self.collapsible(i);
        const d: u32 = if (split) 4 else 2;
        if (split) {
            try self.ind(2);
            try self.b("if (", .{});
            try self.coreRef(flag);
            if (self.an.vty[@intFromEnum(self.an.rv(flag))] == .int)
                try self.b(" != 0) {{\n", .{})
            else
                try self.b(".val() != 0.0) {{\n", .{});
            try self.ind(3);
            try self.b("if (comptime !(@hasDecl(S, \"collapse_applied\") and S.collapse_applied)) {{\n", .{});
        }
        if (!react) {
            try self.ind(d);
            try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.u_names[u]});
            try self.stamp(d, c.hi, "add", "ib", uBit(u));
            try self.stamp(d, c.lo, "sub", "ib", uBit(u));
            try self.ind(d);
            self.patRow(@intCast(u), uBit(u) | nodeBit(c.hi) | nodeBit(c.lo) | self.switchRowDeps(i, c, react));
            try self.b("res[@intFromEnum(U.{s})] = S.sel(", .{self.u_names[u]});
            try self.coreRef(flag);
            try self.b(", ", .{});
            try self.nodeVoltage(c.hi);
            try self.b(".sub(", .{});
            try self.nodeVoltage(c.lo);
            try self.b(").sub(c), ", .{});
            try self.switchElse(partner, react);
            try self.b(");\n", .{});
        } else {
            try self.ind(d);
            self.patRow(@intCast(u), uBit(u) | self.switchRowDeps(i, c, react));
            try self.b("res[@intFromEnum(U.{s})] = S.sel(", .{self.u_names[u]});
            try self.coreRef(flag);
            try self.b(", c.neg(), ", .{});
            try self.switchElse(partner, react);
            try self.b(");\n", .{});
        }
        if (split) {
            try self.ind(3);
            try self.b("}}\n", .{});
            try self.ind(2);
            try self.b("}} else {{\n", .{});
            try self.ind(3);
            try self.b("const flow = ", .{});
            try self.switchOpen(partner, react);
            try self.b(";\n", .{});
            const bits = self.switchRowDeps(i, c, react);
            try self.stamp(3, c.hi, "add", "flow", bits);
            try self.stamp(3, c.lo, "sub", "flow", bits);
            try self.ind(2);
            try self.b("}}\n", .{});
        }
    }

    /// Is potential contribution `i` one `collapse` aliases away? Keyed on the
    /// branch-flow unknown, which `contribIndex` makes unique per branch.
    fn collapsible(self: *const Gen, i: usize) bool {
        const u = self.branch_u[i];
        if (u == none_u32) return false;
        for (self.cpairs) |p| if (p.flow_u == u) return true;
        return false;
    }

    /// The value the branch row would have PINNED I_b to, for the arm where
    /// I_b no longer exists: the partner's retained flow, or zero when nothing
    /// is retained (§5.6.1.3's open circuit). `switchElse` writes the same
    /// three cases as a residual — `I_b − c` and `−φ` — and this is that
    /// residual solved for I_b, so the signs are the plain `.flow` stamp's.
    fn switchOpen(self: *Gen, partner: ?usize, react: bool) Error!void {
        const j = partner orelse return self.b("S.con(0.0)", .{});
        const f = self.lower.contributions.items[j];
        const fv = self.an.rv(if (react) f.react_val else f.resist_val);
        switch (self.retention(f)) {
            .off => try self.b("S.con(0.0)", .{}),
            .on => try self.coreRef(fv),
            .runtime => |fw| {
                try self.b("S.sel(", .{});
                try self.coreRef(fw);
                try self.b(", ", .{});
                try self.coreRef(fv);
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
        const f = self.lower.contributions.items[j];
        const fv = self.an.rv(if (react) f.react_val else f.resist_val);
        switch (self.retention(f)) {
            // Discarded on every path: the partner entry is dead and the else
            // case is §5.6.1.3's open circuit.
            .off => try self.b("{s}", .{open}),
            // Unreachable by construction (a runtime potential flag implies a
            // conditional discard of the partner), but the general form is
            // correct if lowering ever changes: the flow is always retained.
            .on => if (react) {
                try self.coreRef(fv);
                try self.b(".neg()", .{});
            } else {
                try self.b("ib.sub(", .{});
                try self.coreRef(fv);
                try self.b(")", .{});
            },
            .runtime => |fw| {
                try self.b("S.sel(", .{});
                try self.coreRef(fw);
                if (react) {
                    try self.b(", ", .{});
                    try self.coreRef(fv);
                    try self.b(".neg(), {s})", .{open});
                } else {
                    try self.b(", ib.sub(", .{});
                    try self.coreRef(fv);
                    try self.b("), {s})", .{open});
                }
            },
        }
    }

    /// One value as the residual reads it: a core field, or the inline zero
    /// `planCommon` never plans (`.f_zero` has no `m.f<k>`).
    fn coreRef(self: *Gen, v: Mir.Value) Error!void {
        if (v == .f_zero) return self.b("S.con(0.0)", .{});
        try self.b("m.f{d}", .{self.lo_idx[@intFromEnum(v)]});
    }

    fn stamp(self: *Gen, depth: u32, node: u16, opx: []const u8, val: []const u8, bits: u64) Error!void {
        if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
        self.patRow(node, bits);
        try self.ind(depth);
        try self.b("res[@intFromEnum(U.{0s})] = res[@intFromEnum(U.{0s})].{1s}({2s});\n", .{
            self.u_names[node], opx, val,
        });
    }

    /// Row `node` gained a term whose derivative lives in `bits`. Ground has no
    /// equation, so it has no row and no pattern. `pat_react` is set by the
    /// residual half currently emitting, so every writer of `res[...]` records
    /// its columns with one call beside the line that emits them — and, in
    /// `rows`, the fact that it wrote the row at all, whatever the columns are.
    fn patRow(self: *Gen, node: u16, bits: u64) void {
        if (node == Lower.ground) return;
        if (self.pat[@intFromBool(self.pat_react)].len == 0) return;
        self.pat[@intFromBool(self.pat_react)][node] |= bits;
        self.rows[@intFromBool(self.pat_react)] |= uBit(node);
    }

    /// The column bit of one unknown. Out of `u64` range answers "every
    /// column", which is the dense fallback `emitPattern` also takes.
    fn uBit(u: u32) u64 {
        return if (u >= 64) std.math.maxInt(u64) else @as(u64, 1) << @intCast(u);
    }

    /// Same, for a node that may be ground (no unknown, no column).
    fn nodeBit(node: u16) u64 {
        return if (node == Lower.ground) 0 else uBit(node);
    }

    /// The columns accumulated so far on row `u` of the half being emitted.
    fn patOf(self: *const Gen, u: u32) u64 {
        const half = self.pat[@intFromBool(self.pat_react)];
        return if (half.len == 0) std.math.maxInt(u64) else half[u];
    }

    /// Columns of the row `emitSwitchRow` emits. Which arm the `S.sel` takes is
    /// a runtime decision, so the row carries EVERY arm's columns: its own
    /// value, the switch partner's, and `ib` — the open circuit and both flow
    /// forms all name it.
    fn switchRowDeps(self: *const Gen, i: usize, c: Lower.Contribution, react: bool) u64 {
        var acc = uBit(self.branch_u[i]) |
            self.an.unknownDeps(if (react) c.react_val else c.resist_val);
        if (self.switchFlowOf(i)) |j| {
            const f = self.lower.contributions.items[j];
            acc |= self.an.unknownDeps(if (react) f.react_val else f.resist_val);
        }
        return acc;
    }

    fn nodeVoltage(self: *Gen, node: u16) Error!void {
        if (node == Lower.ground) return self.b("S.con(0.0)", .{});
        try self.b("x[@intFromEnum(U.{s})]", .{self.u_names[node]});
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
    /// Two §4.6.4 shapes are deliberately NOT in this table, and TODO.md §3
    /// carries them rather than leaving them to be rediscovered: §4.6.4.3/.4
    /// `noise_table`/`noise_table_log` are piecewise PSD-vs-frequency, which
    /// neither `NoiseGen.kind` nor `PsdTerm`'s `white + flicker/f^ef` can
    /// state; and a generator on a ground-ground branch has no row or column
    /// to name (§1.3.1.1).
    fn emitNoiseTable(self: *Gen) Error!void {
        if (self.noise_rows.len == 0) return;
        try self.w("/// §4.6.4 noise sources declared by the model.\npub const noise_gens = [_]contract.NoiseGen(Self){{\n", .{});
        for (self.noise_rows) |nr| {
            try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .kind = .{s}, .source = {d} }},\n", .{
                self.u_names[nr.row], self.u_names[nr.col], @tagName(nr.kind), nr.source,
            });
        }
        try self.w("}};\n\n", .{});

        // §4.6.4.1/.2 the PSDs, positionally. One `core(R, …)` sweep at the
        // caller's state vector, exactly like `updateState` — a generator
        // whose declaring statement did not execute at this bias reads back
        // the zero `probeBody` seeds a conditional live-out with, which is
        // also its physical answer.
        try self.w(
            \\/// §4.6.4.1/.2 each generator's PSD at `x`: S(f) = white + flicker/f^ef.
            \\/// Position k belongs to `noise_gens[k]`.
            \\pub fn noisePsd(
        , .{});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]f64, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance) [noise_gens.len]contract.PsdTerm {{\n", .{});
        const uses_core = for (self.noise_rows) |nr| {
            if (self.coreIdx(nr.pwr) != null or self.coreIdx(nr.exp) != null) break true;
        } else false;
        if (uses_core) {
            try self.w("    var xr: [n_u]R = undefined;\n", .{});
            try self.w("    for (x, 0..) |xv, i| xr[i] = R.con(xv);\n", .{});
            try self.w("    const m = core(R, xr, model, inst);\n", .{});
        } else {
            self.patchParam(at_x, "x".len);
            self.patchParam(at_model, "model".len);
            self.patchParam(at_inst, "inst".len);
        }
        try self.w("    return .{{\n", .{});
        for (self.noise_rows) |nr| {
            const pwr = try self.psdRef(nr.pwr, false);
            if (nr.kind == .flicker) {
                try self.w("        .{{ .white = 0, .flicker = {s}, .ef = {s} }},\n", .{ pwr, try self.psdRef(nr.exp, true) });
            } else {
                try self.w("        .{{ .white = {s} }},\n", .{pwr});
            }
        }
        try self.w("    }};\n}}\n\n", .{});
    }

    /// The core field holding `v`, or null when `v` is rendered inline —
    /// structurally zero, or a constant `planCommon` never had to carry.
    fn coreIdx(self: *const Gen, v: Mir.Value) ?u32 {
        if (v == .f_zero) return null;
        const k = self.lo_idx[@intFromEnum(v)];
        return if (k == none_u32) null else k;
    }

    /// `v` as a compile-time f64, or null when only the core can answer.
    fn psdConst(self: *const Gen, v: Mir.Value) ?f64 {
        return switch (self.mir.valueDef(v)) {
            .float_const => |x| x,
            .int_const => |x| @floatFromInt(x),
            else => null,
        };
    }

    /// One PSD argument as an `f64` expression in `noisePsd`'s body. `is_exp`
    /// allows the inline-constant shortcut — see `buildJobs` for why only the
    /// exponent may take it.
    fn psdRef(self: *Gen, v: Mir.Value, is_exp: bool) Error![]const u8 {
        if (v == .f_zero) return "0";
        if (is_exp) if (self.psdConst(v)) |c| return try std.fmt.allocPrint(self.arena, "{d}", .{c});
        const k = self.lo_idx[@intFromEnum(v)];
        // A live-out the planner dropped cannot happen (`buildJobs` queued it),
        // but a zero is the one answer that cannot invent noise.
        if (k == none_u32) return "0";
        return try std.fmt.allocPrint(self.arena, "m.f{d}.v", .{k});
    }

    // =======================================================================
    // §4.5.2 the analog-operator state machine
    // =======================================================================

    /// Advance every stateful operator once the step is accepted. State lives in
    /// `Instance` (eval reads it); `State` only carries the bookkeeping the
    /// contract wants in its own struct.
    fn emitStateMachine(self: *Gen) Error!void {
        var uses_dt = false;
        var uses_core = false;
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const k = opKind(u.target);
            uses_dt = uses_dt or switch (k) {
                .idt, .idtmod, .transition, .slew, .last_crossing, .laplace => true,
                else => false,
            };
            if (!opHasState(k)) continue;
            uses_core = uses_core or self.opInputIdx(@intCast(i)) != none_u32;
        }
        for (self.held_idx) |k| uses_core = uses_core or k != none_u32;
        uses_core = uses_core or self.pathLatches();
        try self.w(
            \\/// §4.5.2 accepted-step bookkeeping for the analog operators.
            \\pub const State = struct {{
            \\    t_prev: f64 = 0.0,
            \\}};
            \\
            \\pub fn initState(_: *const Model, _: *Instance) State {{
            \\    return .{{}};
            \\}}
            \\
            \\pub fn updateState({0s}: *const Model, inst: *Instance, {1s}: [n_u]f64, state: *State) contract.UpdateResult {{
            \\
        , .{
            // Both go unread when the only accepted-step work is §9.13.1's
            // internal-seed advance, which is a function of the seed alone.
            if (uses_core) "model" else "_",
            if (uses_core) "x" else "_",
        });
        if (uses_core) try self.w(
            \\    var xr: [n_u]R = undefined;
            \\    for (x, 0..) |xv, i| xr[i] = R.con(xv);
            \\
        , .{});
        // ONE core evaluation for every operator's input, not one per operator:
        // the inputs are fields of the same struct, so the accepted-step sweep
        // costs exactly one model evaluation however many operators there are.
        // `model` is always live because that call reads it. `dt` is not.
        if (uses_core) try self.w("    const m = core(R, xr, model, inst);\n", .{});
        // §5.6.1.2 stage this iterate's path-latch operands. They become the
        // committed base ONLY at stateCtl(.commit): a rejected attempt leaves
        // pb/pq untouched, so the retry reopens on the accepted charge with a
        // zero α·Δq residual.
        for (self.prev_lo, 0..) |lo, k| {
            try self.w("    inst.wb__{d} = m.f{d}.v; // path_prev staging\n", .{ k, lo });
        }
        for (self.acc_lo, 0..) |lo, k| {
            try self.w("    inst.wq__{d} = m.f{d}.v; // path_acc staging\n", .{ k, lo });
        }
        if (uses_dt) try self.w("    const dt = inst.abstime - state.t_prev;\n", .{});
        // §9.17 reset FIRST, unconditionally: a `$bound_step` that only fired on
        // one arm of an `if` last step must not keep bounding this one, and the
        // reset value is also the right answer for a model that never calls the
        // task at all.
        try self.w(
            \\    inst.bound_step = std.math.inf(f64); // §9.17.2
            \\    inst.discontinuity_order = -1; // §9.17.1
            \\
        , .{});
        // §9.13.1 the internal seed advances HERE and nowhere else: this is the
        // accepted-step boundary, so a stream moves once per solved point and the
        // residual it feeds is fixed for the whole Newton loop that produced it.
        if (self.lower.rng_auto_sites != 0) try self.w(
            \\    // §9.13.1 "this internal seed gets updated every time the call
            \\    // to $arandom is made" — once per ACCEPTED point, per call site.
            \\    for (&inst.rng_auto) |*rs| rs.* = @intFromFloat(zRngNext(rs.*));
            \\
        , .{});
        for (self.units, 0..) |u, i| {
            const k = opKind(u.target);
            if (u.role != .analog_op or !opHasState(k)) continue;
            const n = self.unit_names[i];
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
            const args = self.mir.instData(inst).call.args;
            const lo = self.opInputIdx(@intCast(i));
            if (lo == none_u32) {
                try self.w("    {{\n        const in: f64 = 0.0;\n", .{});
            } else {
                try self.w("    {{\n        const in = m.f{d}.v;\n", .{lo});
            }
            switch (k) {
                .ddt => try self.w("        inst.{s}__prev = in;\n", .{n}),
                // §4.5.4 with `assert`: "Once assert becomes zero, idt()
                // returns the integral of the argument starting from the last
                // instant where assert was nonzero" — so while assert is
                // nonzero the accumulator is PINNED at ic, and integration
                // resumes from there.
                .idt => if (args.len >= 3) try self.w(
                    "        inst.{s}__acc = if (({s}) != 0.0) ({s}) else zIdtAcc(in, inst.{s}__acc, dt, {s});\n",
                    .{
                        n,                               try self.argF64(args, 2, "0.0"),
                        try self.argF64(args, 1, "0.0"), n,
                        try self.argF64(args, 1, "0.0"),
                    },
                ) else try self.w("        inst.{s}__acc = zIdtAcc(in, inst.{s}__acc, dt, {s});\n", .{
                    n, n, try self.argF64(args, 1, "0.0"),
                }),
                .idtmod => try self.w("        inst.{s}__acc = zWrap(zIdtAcc(in, inst.{s}__acc, dt, {s}), {s}, {s});\n", .{
                    n,                               n,
                    try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0"),
                    try self.argF64(args, 3, "0.0"),
                }),
                .absdelay => {
                    try self.w("        zHistPush(&inst.{s}__t, &inst.{s}__v, &inst.{s}__head, inst.abstime, in);\n", .{ n, n, n });
                    // §9.17.2 the same self-defence the §4.5.12 filter mounts
                    // with its period: ask the host to keep the step at or
                    // under td, or a wide step flattens the delay to
                    // `zAbsdelay`'s short-side interpolation and the 32-sample
                    // ring records nothing finer than the steps taken. `td`
                    // may be a model expression (a parameter's overridden
                    // value), so the bound is computed at run time; only a
                    // positive one binds — `@min` with 0 would stop time.
                    try self.w(
                        "        const zad_td = {s};\n        if (zad_td > 0.0) inst.bound_step = @min(inst.bound_step, zad_td);\n",
                        .{try self.argF64(args, 1, "0.0")},
                    );
                },
                .transition => {
                    const t = try self.transitionTimes(args);
                    try self.w(
                        "        zTransStep(in, &inst.{s}__from, &inst.{s}__t0, inst.abstime, dt, {s}, {s});\n",
                        .{ n, n, t[0], t[1] },
                    );
                },
                .slew => {
                    const r = try self.slewRates(args);
                    try self.w("        inst.{s}__prev = zSlew(R, R.con(in), inst.{s}__prev, dt, {s}, @abs({s})).v;\n", .{
                        n, n, r[0], r[1],
                    });
                },
                // §4.5.10 `last_crossing(expr, direction)`. The direction is the
                // SAME closed argument as §5.10.3 `cross`'s — +1 rising, -1
                // falling, 0 either — so it is decoded and honoured the same
                // way; a bare sign change would report a falling edge to a
                // `last_crossing(V(p), +1)`.
                //
                // `dt > 0.0` is not an optimisation, it is the SEEDING rule.
                // `__prev` initialises to 0.0, which is a value the signal was
                // never at, so on the very first accepted step the sign test
                // compares against a sample that does not exist — a signal
                // sitting at -1 V read as a falling crossing of zero, reported
                // at `state.t_prev + f*dt` = 0.0, which is not the "negative
                // value" §4.5.10's last sentence requires before the first real
                // crossing. A crossing needs an INTERVAL, and the DC point
                // (dt = 0) is not one: it only seeds the history.
                .last_crossing => try self.w(
                    \\        if (dt > 0.0 and ({1s})) {{
                    \\            const f = inst.{0s}__prev / (inst.{0s}__prev - in);
                    \\            inst.{0s}__t_last = state.t_prev + f * dt;
                    \\        }}
                    \\        inst.{0s}__prev = in;
                    \\
                , .{ n, try self.crossTest(n, args, "in") }),
                // §5.10.3 only the HISTORY moves here; `eval` raises the event
                // (see `emitOperator`), so nothing an accepted step writes can
                // still be read one timepoint later than it happened. The
                // `enable` is not consulted: it gates the EVENT, not the record
                // of where the signal was, and a disabled operator that later
                // re-enables must not compare against a stale sample.
                // §5.10.3.2 same history, same reason: `eval` raises the event
                // and this only records where the signal was on the ACCEPTED
                // step, so a re-arm cannot be observed one timepoint late.
                .cross, .above => try self.w("        inst.{s}__prev = in;\n", .{n}),
                // §5.10.3.3 the schedule is absolute — "at start_time, and every
                // period after that" — so it advances past the accepted time
                // whether or not the enable let the event through.
                .timer => try self.w(
                    \\        if (inst.{0s}__next < in) inst.{0s}__next = in;
                    \\        if (inst.abstime >= inst.{0s}__next) {{
                    \\            const period = {1s};
                    \\            inst.{0s}__next = if (period > 0.0) inst.{0s}__next + period else std.math.inf(f64);
                    \\        }}
                    \\
                , .{ n, try self.argF64(args, 1, "0.0") }),
                // §9.17.2 "the next time step taken is no larger than the
                // smallest $bound_step() argument currently ACTIVE". `in` is
                // already the running minimum over every `$bound_step` that
                // executed (lower.zig accumulates it through the CFG); the
                // `@min` folds it against the §4.5.12 sampling periods, which
                // are equally active and may be written by an earlier block.
                .bound_step => try self.w("        inst.bound_step = @min(inst.bound_step, in);\n", .{}),
                // §9.17.1 same, and `inf` means "no announcement": the degree is
                // a non-negative constant_expression, so a finite `in` is exact.
                // `lossyCast` because "finite" is not "fits an i32", and the
                // artifact is built ReleaseFast — a huge degree saturates
                // instead of being UB.
                .discontinuity => try self.w(
                    "        inst.discontinuity_order = if (std.math.isFinite(in)) std.math.lossyCast(i32, in) else -1;\n",
                    .{},
                ),
                // §4.5.11 advance the cascade on the accepted solution.
                .laplace => {
                    const p = try cg_filters.filterPlan(self, inst, args);
                    if (p.err == null) try self.w(
                        "        zLaplaceStep({d}, {d}, in, {s}__sec(model), dt, &inst.{s}__u, &inst.{s}__y);\n",
                        .{ p.ns, p.deg, n, n, n },
                    );
                },
                // §4.5.12 the filter runs on ITS OWN timebase: sample when the
                // accepted time reaches the next multiple of T, hold in
                // between. Same shape as the §5.10.3 `timer` block above, and
                // the step bound is what keeps the solver from stepping over a
                // sample and aliasing the filter.
                .zi => {
                    const p = try cg_filters.filterPlan(self, inst, args);
                    if (p.err == null) try self.w(
                        \\        const period = {1s};
                        \\        if (period > 0.0 and inst.abstime >= inst.{0s}__next) {{
                        \\            // §4.5.12: "T specifies the sampling period of the filter".
                        \\            // The recurrence runs once per T of SIMULATED TIME, so a step
                        \\            // that crosses k sample instants runs it k times. Stepping it
                        \\            // ONCE per evaluation — which is what this did — makes the
                        \\            // output a function of how densely the host happened to place
                        \\            // its timepoints, and the same filter at the same T returned
                        \\            // bit-identical values for 20 us and 200 us of elapsed time.
                        \\            var zn = @floor((inst.abstime - inst.{0s}__next) / period) + 1.0;
                        \\            // ponytail: a ceiling, and `bound_step` below is the reason it
                        \\            // is almost never reached — the filter ASKS the host to keep
                        \\            // the step at or under T, so the honouring host always has
                        \\            // zn == 1. A host that ignores it far enough to need more than
                        \\            // this has already aliased the filter beyond what replaying
                        \\            // the held input could recover.
                        \\            if (zn > 4096.0) zn = 4096.0;
                        \\            var zi_k: u32 = @intFromFloat(zn);
                        \\            while (zi_k > 0) : (zi_k -= 1)
                        \\                inst.{0s}__out = zZiStep({2d}, {3d}, in, {0s}__sec(model), &inst.{0s}__u, &inst.{0s}__y);
                        \\            // Re-armed on the sample GRID, not from the accepted time.
                        \\            // `abstime + period` lost the phase: it made every sample land
                        \\            // wherever the host last stopped, so the instants drifted with
                        \\            // the timestep. Advancing by zn*T cannot leave the clock
                        \\            // behind either, since zn is chosen to pass abstime.
                        \\            inst.{0s}__next += zn * period;
                        \\            inst.discontinuity_order = 0; // §9.17.1 the held output steps
                        \\        }}
                        \\        inst.bound_step = @min(inst.bound_step, period);
                        \\
                    , .{ n, p.period orelse "0.0", p.ns, p.deg });
                },
                .none => {},
            }
            try self.w("    }}\n", .{});
        }
        // §5.10 store every held variable back. HERE and nowhere else: this
        // function runs on the ACCEPTED solution, once per step, exactly like
        // the operator history above — writing it from `eval` would latch a
        // Newton iterate that the solver goes on to throw away.
        for (self.lower.held_vars.items, 0..) |h, i| {
            const k = self.held_idx[i];
            const n = self.held_names[i];
            if (k == none_u32) {
                // The value folded away entirely (never assigned outside the
                // §5.10 body on any reachable path, and the body's value is a
                // literal zero); nothing to carry.
                try self.w("    inst.{s} = 0;\n", .{n});
            } else if (h.ty == .integer) {
                try self.w("    inst.{s} = m.f{d};\n", .{ n, k });
            } else {
                try self.w("    inst.{s} = m.f{d}.v;\n", .{ n, k });
            }
        }
        try self.w(
            \\    state.t_prev = inst.abstime;
            \\    return .ok;
            \\}}
            \\
            \\
        , .{});
        if (self.emitsStateCtl()) try self.emitStateCtl();
    }

    /// §5.10.5 `timer(start_time, period)` — the host's `nextBreakpoint` hook.
    ///
    /// WHY THIS OPERATOR AND NO OTHER. `nextBreakpoint` asks "at what time must
    /// the transient loop PLACE a timepoint", so a discontinuity lands on a step
    /// instead of being smeared across one. Nothing else in Verilog-A says that:
    /// §9.17.2 `$bound_step` bounds step SIZE (a bound, not a location) and
    /// §9.17.1 `$discontinuity` only announces one after the fact. §5.10.5 is the
    /// exact wording — "the timer function schedules an event at `start_time`,
    /// and every `period` after that" — so the fire times ARE the breakpoints.
    ///
    /// The signature `contract.zig` fixes is `fn (*const Model, f64) ?f64`: no
    /// `Instance`, so the live `__next` counter the state machine advances is out
    /// of reach and the schedule has to be RECOMPUTED from `(model, t)`. That is
    /// possible because §4.5.14 makes an analog-operator control argument a
    /// constant or parameter expression, which is exactly what `f64Const`
    /// renders — `model.<p>` leaves and arithmetic over them.
    ///
    /// ALL OR NOTHING. If any one timer's arguments do not render, the whole
    /// function is dropped rather than emitted covering the others. A missing
    /// hook only costs accuracy (the host falls back to LTE step control, as it
    /// does for every device today); a hook that silently reports a SUBSET reads
    /// to the host as "this device wants no other timepoints", which is a claim
    /// this code would not be entitled to make.
    ///
    // ponytail: the §5.10.3.3 `enable` is honoured here only where it folds
    // WITHOUT parameters (a genuinely-constant zero: that timer never fires,
    // so proposing its fire times would be a lie about where a discontinuity
    // is) or renders over the Model (a parameter enable: the guard is emitted
    // and evaluated at run time — folding it through the DECLARED default
    // used to veto a timer whose enable the model card overrode to nonzero).
    // A timer whose enable is a solved quantity keeps its breakpoints, because
    // this hook has no `Instance` to evaluate one against and an extra timepoint
    // costs a step, never an answer.
    // ---------------------------------------------- zero-parasitic collapse

    /// One collapsible §5.6.5 switch branch: when `flag` (a §5.6.1.3
    /// retention flag, carried as a core field) is nonzero at build time,
    /// the host aliases unknown `victim` and the branch-flow unknown
    /// `flow_u` onto unknown `target`. Indices are node_order/U-enum space.
    const CollapsePair = struct { victim: u32, target: u32, flow_u: u32, flag: Mir.Value };

    /// Is `v` a constant of the whole simulation — a function of Model and
    /// Instance-at-build and nothing else? Stricter than `Analysis.dFree`,
    /// which admits x-steered selects between constants (its ternary/phi
    /// rule ignores the condition); a collapse decision taken once at build
    /// must not. Calls are ALLOWLISTED for the same reason: `$abstime`, rng
    /// draws, `$held_*` seeds and `analysis()` all change between
    /// evaluations, so a new operator is unsound here until shown otherwise.
    ///
    /// The phi rule leans on lowering's structured CFGs: the branch at the
    /// join's immediate dominator is what steers a diamond's phi, and any
    /// NESTED x-dependent steering surfaces as an inner phi in the incoming
    /// values, which recursion refuses. Loop-carried phis are refused
    /// outright.
    fn buildFree(self: *const Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 64) return false;
        const v = self.an.rv(v0);
        switch (self.mir.valueDef(v)) {
            .undef, .float_const, .int_const, .str_const, .param_ref => return true,
            .block_param => return false, // §4.4 probe: x by definition
            .inst_result => |inst| {
                const row = self.mir.instRow(inst);
                switch (Mir.opClass(row.op)) {
                    .branch, .jump => return false,
                    .unary => return self.buildFree(@enumFromInt(row.a), depth + 1),
                    .binary => return self.buildFree(@enumFromInt(row.a), depth + 1) and
                        self.buildFree(@enumFromInt(row.b), depth + 1),
                    .ternary => return self.buildFree(@enumFromInt(row.a), depth + 1) and
                        self.buildFree(@enumFromInt(row.b), depth + 1) and
                        self.buildFree(@enumFromInt(row.c), depth + 1),
                    .call => {
                        const d = self.mir.instData(inst).call;
                        const ok = std.StaticStringMap(void).initComptime(.{
                            .{ "$temperature", {} },
                            .{ "$vt", {} },
                            .{ "$mfactor", {} },
                            .{ "$param_given", {} },
                        });
                        if (!ok.has(d.name)) return false;
                        for (d.args) |arg| {
                            if (!self.buildFree(arg, depth + 1)) return false;
                        }
                        return true;
                    },
                    .phi => {
                        const blk = self.an.def_block[@intFromEnum(v)];
                        if (blk == none_u32 or self.an.inLoop(blk)) return false;
                        const id = self.an.idom[blk];
                        if (id == none_u32) return false;
                        const ti = self.an.term[id];
                        if (ti == .none) return false;
                        const t = self.mir.instData(ti);
                        if (t != .branch) return false;
                        if (!self.buildFree(t.branch.cond, depth + 1)) return false;
                        const d = self.mir.instData(inst).phi;
                        for (0..d.count) |k| {
                            if (!self.buildFree(self.mir.phiPair(inst, @intCast(k)).value, depth + 1)) return false;
                        }
                        return true;
                    },
                }
            },
        }
    }

    /// Is `v` zero on EVERY path — `.f_zero`, a fold to 0.0, or a phi all of
    /// whose arms are? The accumulator of a §5.6.5 potential arm contributing
    /// `<+ 0.0` is exactly this shape: entry-seeded 0, `discardOpposite`'s 0
    /// on the flow arm, `0 + 0.0` on its own.
    fn zeroOnEveryPath(self: *const Gen, v0: Mir.Value, depth: u32) bool {
        if (depth > 16) return false;
        const v = self.an.rv(v0);
        if (v == .f_zero) return true;
        if (self.an.foldConst(v, 0, false)) |k| return k.f == 0.0;
        const def = self.mir.valueDef(v);
        if (def == .inst_result and self.mir.instRow(def.inst_result).op == .phi) {
            const d = self.mir.instData(def.inst_result).phi;
            for (0..d.count) |k| {
                if (!self.zeroOnEveryPath(self.mir.phiPair(def.inst_result, @intCast(k)).value, depth + 1)) return false;
            }
            return true;
        }
        return false;
    }

    /// The §5.6.5 switch branches this model can COLLAPSE: runtime-selected
    /// potential rows whose retained value is the constant 0 V (and 0 flux —
    /// a selected nonzero source is a real source, not a short) and whose
    /// retention flag is fixed at build time (`buildFree`). ngspice does the
    /// same in every setup routine (DIOsetup: `posPrimeNode = posNode` when
    /// RS == 0); keeping the pair apart behind a selected 0 V short costs the
    /// host an unknown, a branch row, and catastrophic cancellation when its
    /// LU eliminates the short.
    fn collapsePairs(self: *Gen) Error![]CollapsePair {
        var out: std.ArrayList(CollapsePair) = .empty;
        const np: u32 = @intCast(self.lower.num_ports);
        for (self.lower.contributions.items, 0..) |c, i| {
            if (c.kind != .direct or c.access != .potential) continue;
            const ret = self.retention(c);
            if (ret != .runtime) continue;
            if (!self.buildFree(ret.runtime, 0)) continue;
            if (!self.zeroOnEveryPath(c.resist_val, 0)) continue;
            if (!self.zeroOnEveryPath(c.react_val, 0)) continue;
            const fu = self.branch_u[i];
            if (fu == none_u32) continue;
            // Only a non-port internal node is the host's to move, and only
            // onto a real unknown (§1.3.1.1 ground has none). The host
            // resolves aliases in ascending unknown order, so the target
            // must precede both movers.
            const hi_free = c.hi != Lower.ground and c.hi >= np;
            const lo_free = c.lo != Lower.ground and c.lo >= np;
            if (!hi_free and !lo_free) continue;
            const victim: u32 = if (hi_free and lo_free) @max(c.hi, c.lo) else if (hi_free) c.hi else c.lo;
            const target: u32 = if (hi_free and lo_free) @min(c.hi, c.lo) else if (hi_free) c.lo else c.hi;
            if (target == Lower.ground) continue;
            if (target >= victim or target >= fu) continue;
            try out.append(self.arena, .{ .victim = victim, .target = target, .flow_u = fu, .flag = ret.runtime });
        }
        return out.items;
    }

    /// The host-side collapse hook — `seed`'s twin: it runs the core once at
    /// x = 0 (exact, since every admitted flag is `buildFree`) and reads the
    /// same §5.6.1.3 retention flags `eval` selects the branch row on. Flag
    /// set ⇒ the 0 V potential arm is retained ⇒ the branch is a dead short:
    /// the host aliases the internal node and the branch-flow unknown onto
    /// the far node, every stamp of the pair lands on one matrix slot and
    /// cancels exactly, and the LU never sees the short.
    ///
    /// Consulted ONCE, at build — ngspice's own semantics (setup runs before
    /// the first load), and why `buildFree` refuses anything that can change
    /// between evaluations.
    fn emitCollapse(self: *Gen, pairs: []const CollapsePair) Error!void {
        if (pairs.len == 0) return;
        try self.w(
            \\/// Zero-parasitic node collapse (ngspice setup: DIOsetup's
            \\/// `posPrimeNode = posNode` when RS == 0). Applied by the host before
            \\/// matrix build; the flags read here are the §5.6.1.3 retention flags
            \\/// `eval` selects the branch rows on, evaluated at x = 0 like `seed` —
            \\/// sound because codegen admits only build-time-constant flags.
            \\///
            \\/// Dead shorts form CHAINS (BSIM4's rgateMod=0 retains both V(g,gm)=0
            \\/// and V(gm,gi)=0, sharing gm), so aliases are resolved by union-find:
            \\/// every member of a merged set lands on ONE root and each stamp of
            \\/// the set cancels on a single slot. Last-write-wins aliasing left the
            \\/// chain's first link dangling — its KVL row landed on a KCL row as
            \\/// ±1 garbage stamps and the "solution" violated the model equations.
            \\pub fn collapse(model: *const Model, inst: *const Instance) [n_u]?u8 {{
            \\    var xr: [n_u]R = undefined;
            \\    for (&xr) |*p| p.* = R.con(0.0);
            \\    // SEEDS ITS OWN PRECOMPUTE, on a local copy. `collapse` decides
            \\    // TOPOLOGY, so a host must call it while building the matrix —
            \\    // before the batch exists and therefore before the batch runs
            \\    // `precompute`. But it answers by evaluating `core` at x = 0, and
            \\    // `core` reads `Instance.pc__*`: without this the retention flags
            \\    // are read off unwritten zeros and a device collapses (or fails to)
            \\    // on garbage. `precompute` is a pure function of (model, instance),
            \\    // so computing it here is the same answer the batch will compute
            \\    // later, and the copy keeps the caller's Instance untouched.
            \\{s}    const m = core(R, xr, model, {s});
            \\    var parent: [n_u]u8 = undefined;
            \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
            \\
        , .{
            // The hoisted core prefix rides the same seeding: without it the
            // local copy's `hp_ok` is 0, the region runs, and the answer is the
            // same — but `precompute` is what makes the flags agree with the
            // batch's, and it is the only writer of `hp_*`.
            if (self.pc_vals.len != 0 or self.hp_vals.len != 0)
                "    var pin = inst.*;\n    precompute(&pin, model);\n"
            else
                "",
            if (self.pc_vals.len != 0 or self.hp_vals.len != 0) "&pin" else "inst",
        });
        for (pairs, 0..) |p, pi| {
            const fi = @intFromEnum(self.an.rv(p.flag));
            const k = self.lo_idx[fi];
            assert(k != none_u32); // `buildJobs` queues every runtime retention flag
            if (self.an.vty[fi] == .int)
                try self.w("    const a{d} = (m.f{d} != 0);", .{ pi, k })
            else
                try self.w("    const a{d} = (m.f{d}.v != 0.0);", .{ pi, k });
            try self.w(" // 0 V arm retained: dead short\n", .{});
            try self.w("    if (a{d}) zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
                pi, self.u_names[p.victim], self.u_names[p.target],
            });
        }
        try self.w(
            \\    var out: [n_u]?u8 = .{{null}} ** n_u;
            \\    for (0..n_u) |u| {{
            \\        const r = zCollapseRoot(&parent, @intCast(u));
            \\        if (r != u) out[u] = r;
            \\    }}
            \\
        , .{});
        // UNCONDITIONAL, unlike the union above. The flag decides whether the
        // two NODES merge; the branch-flow unknown goes either way. Short
        // taken: it is part of the merged set. Short not taken: the branch is
        // `I(hi,lo) <+ <conductance>`, which wants no current row at all —
        // `emitSwitchRow`'s else arm stamps it straight into KCL. Guarding this
        // line on the flag cost the host one unknown and one matrix row per
        // RETAINED parasitic, for a row the physics never writes.
        for (pairs) |p| {
            try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
                self.u_names[p.flow_u], self.u_names[p.target],
            });
        }
        try self.w("    return out;\n}}\n\n", .{});
        try self.w(
            \\fn zCollapseRoot(parent: *const [n_u]u8, start: u8) u8 {{
            \\    var u = start;
            \\    while (parent[u] != u) u = parent[u];
            \\    return u;
            \\}}
            \\
            \\/// Min-index root wins, so a set's root is always its lowest unknown —
            \\/// the host resolves aliases in ascending order and needs the target
            \\/// resolved before every mover.
            \\fn zCollapseUnion(parent: *[n_u]u8, a: u8, b: u8) void {{
            \\    const ra = zCollapseRoot(parent, a);
            \\    const rb = zCollapseRoot(parent, b);
            \\    if (ra == rb) return;
            \\    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
            \\}}
            \\
            \\
        , .{});
        try self.emitCollapseFull(pairs);
    }

    /// `collapse` with EVERY retention flag set — the maximal collapse, at
    /// comptime.
    ///
    /// `collapse` itself can only answer per instance, because the flags are
    /// parameters. A host that wants to SPECIALISE the fully collapsed
    /// instances needs the alias map before any instance exists: it sizes a
    /// reduced derivative basis (the merged set is ONE unknown, so it needs
    /// one seed lane and one Jacobian column, not |set| of each) and that is a
    /// type, not a value. So the two halves are split — this const is the
    /// shape, `collapse` is the per-instance test, and an instance qualifies
    /// for the narrow basis exactly when the two arrays are equal.
    ///
    /// Every union below is unconditional here, which is the only difference
    /// from `collapse`: a flag that is clear at runtime merges strictly less,
    /// so `collapse(m, i) == collapse_full` is the honest "maximal" predicate
    /// and every other outcome falls back to the full width.
    fn emitCollapseFull(self: *Gen, pairs: []const CollapsePair) Error!void {
        try self.w(
            \\/// The MAXIMAL collapse: `collapse` with every §5.6.1.3 retention
            \\/// flag set. Comptime, so a host can size a reduced derivative
            \\/// basis for the instances whose runtime `collapse` equals this;
            \\/// any other outcome merges strictly less and must use full width.
            \\pub const collapse_full: [n_u]?u8 = blk: {{
            \\    var parent: [n_u]u8 = undefined;
            \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
            \\
        , .{});
        for (pairs) |p| {
            try self.w("    zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
                self.u_names[p.victim], self.u_names[p.target],
            });
        }
        try self.w(
            \\    var out: [n_u]?u8 = .{{null}} ** n_u;
            \\    for (0..n_u) |u| {{
            \\        const r = zCollapseRoot(&parent, @intCast(u));
            \\        if (r != u) out[u] = r;
            \\    }}
            \\
        , .{});
        for (pairs) |p| {
            try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
                self.u_names[p.flow_u], self.u_names[p.target],
            });
        }
        try self.w("    break :blk out;\n}};\n\n", .{});
    }

    /// §4.5.7 the per-site transport delays, model-frame like
    /// `nextBreakpoint` above — a delay argument is a §4.5.14
    /// constant/parameter expression, so it renders over `Model` alone.
    /// The host's transient uses these two ways (ngspice traload's habit):
    /// a landed breakpoint re-emits one echo at t + td so the ARRIVING
    /// wavefront gets its own timepoint instead of being smeared across a
    /// step, and dt_max is clamped under the shortest delay. A site whose
    /// delay is a solved quantity is skipped — no claim beats a wrong one.
    fn emitDelays(self: *Gen) Error!void {
        const saved = self.uses_model;
        defer self.uses_model = saved;
        self.uses_model = false;
        var tds: std.ArrayList([]const u8) = .empty;
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op or opKind(u.target) != .absdelay) continue;
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            const args = self.mir.instData(inst).call.args;
            if (args.len < 2) continue;
            const td = try self.f64Const(args[1], 0, false) orelse continue;
            try tds.append(self.arena, td);
        }
        if (tds.items.len == 0) return;
        try self.w(
            \\/// §4.5.7 transport delays, one per absdelay site. The host lands
            \\/// wavefront breakpoints at corner + td and bounds dt_max under the
            \\/// shortest delay (engine minDelay -> tran echo machinery).
            \\pub fn delays({s}: *const Model) [{d}]f64 {{
            \\    return .{{
        , .{ if (self.uses_model) "model" else "_", tds.items.len });
        for (tds.items, 0..) |td, k| try self.w("{s} {s}", .{ if (k == 0) "" else ",", td });
        try self.w(" }};\n}}\n\n\n", .{});
    }

    fn emitNextBreakpoint(self: *Gen) Error!void {
        if (!self.usesOp(.timer)) return;

        // Render FIRST, emit second: `f64Const` is what sets `uses_model`, and
        // an unused `model` parameter does not compile.
        const saved = self.uses_model;
        defer self.uses_model = saved;
        self.uses_model = false;

        var timers: std.ArrayList([3]?[]const u8) = .empty;
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op or opKind(u.target) != .timer) continue;
            const inst = self.opInstOf(@intCast(i)) orelse return;
            const args = self.mir.instData(inst).call.args;
            // §5.10.3.3 "if enable is specified and it is zero, then timer() is
            // inactive": a constant-zero enable means this timer never fires, so
            // it contributes no breakpoint — and it must not veto the others.
            var guard: ?[]const u8 = null;
            if (enableArgIdx("timer")) |ei| {
                if (ei < args.len) {
                    if (self.an.foldConst(args[ei], 0, false)) |c| {
                        if (c.f == 0.0) continue;
                    } else if (try self.f64Const(args[ei], 0, false)) |e| {
                        guard = e;
                    }
                }
            }
            // No diagnostic: `f64Expr` already fired one for the period if it is
            // unrenderable, and a start_time that is a solved quantity is legal
            // Verilog-A that this hook simply cannot describe.
            const start = try self.f64Const(if (args.len > 0) args[0] else .zero, 0, false) orelse return;
            const period = try self.f64Const(if (args.len > 1) args[1] else .zero, 0, false) orelse return;
            try timers.append(self.arena, .{ start, period, guard });
        }
        if (timers.items.len == 0) return;

        try self.w(
            \\/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host
            \\/// puts a timepoint ON the discontinuity instead of across it.
            \\pub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{
            \\    var best = std.math.inf(f64);
            \\
        , .{if (self.uses_model) "model" else "_"});
        for (timers.items) |tm| {
            if (tm[2]) |g| try self.w("    if (({s}) != 0.0)\n    ", .{g});
            try self.w("    if (zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ tm[0].?, tm[1].? });
        }
        try self.w(
            \\    return if (best == std.math.inf(f64)) null else best;
            \\}}
            \\
            \\
        , .{});
    }
};

/// LRM Table 4-14/4-15 by name, including the `log10` spelling that the `$`
/// (IEEE 1364 §17.11) form uses. Reuses lowering's tables — one source of truth.
fn mathOpByName(name: []const u8) ?Mir.Opcode {
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

fn isAnalysisName(s: []const u8) bool {
    const names = [_][]const u8{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" };
    for (names) |n| {
        if (std.mem.eql(u8, s, n)) return true;
    }
    return false;
}

/// Length of the §4.5.7 absdelay history ring.
// ponytail: fixed 512 samples with linear interpolation. The floor is set by
// SPICE canon, not by the model: maxstep = min(tstep, span/50), so a fixture
// like `T TD=2n` under `.tran 20p` legitimately runs td/dt = 100 accepted
// steps per delay — at 32 the whole lookback fell off the ring and the line
// transported with ZERO delay (devices/tline read its far port half an edge
// early for the entire run). Edge-resolving LTE shrinkage pushes the worst
// case a few times higher, hence 512. A query older than the ring clamps to
// the OLDEST sample (see zHistAt) — bounded staleness, never a time machine.
// Upgrade path if a fixture still underruns: host-owned growable history
// (the engine's dormant HistoryBuffer channel), which is what ngspice does.
const hist_len: usize = 512;

fn unitComment(c: Lower.Contribution, react: bool) []const u8 {
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
fn devSafe(op: Mir.Opcode) bool {
    return switch (op) {
        .fadd, .fsub, .fmul, .fdiv, .fneg => true,
        .fabs, .fmin, .fmax => true,
        // sqrt/floor/ceil are sqrt.rn.f64 and cvt.rmi/rpi.f64.f64 — instructions.
        .sqrt, .floor, .ceil => true,
        .opt_barrier => true,
        else => false,
    };
}

/// with `naming.isStatefulAnalogOp`: that predicate decides which calls get a
/// unit, and this one decides which get Instance state — they are the same set.
pub const OpKind = enum {
    none,
    ddt, // §4.5.3
    idt, // §4.5.4
    idtmod, // §4.5.5
    absdelay, // §4.5.7
    transition, // §4.5.8
    slew, // §4.5.9
    last_crossing, // §4.5.10
    laplace, // §4.5.11
    zi, // §4.5.12
    cross, // §5.10.3
    above, // §5.10.3
    timer, // §5.10.3
    bound_step, // §9.17.2
    discontinuity, // §9.17.1
};

pub fn opKind(name: []const u8) OpKind {
    const map = std.StaticStringMap(OpKind).initComptime(.{
        .{ "ddt", .ddt },
        .{ "idt", .idt },
        .{ "idtmod", .idtmod },
        .{ "absdelay", .absdelay },
        .{ "transition", .transition },
        .{ "slew", .slew },
        .{ "last_crossing", .last_crossing },
        .{ "laplace_zd", .laplace },
        .{ "laplace_zp", .laplace },
        .{ "laplace_nd", .laplace },
        .{ "laplace_np", .laplace },
        .{ "zi_zd", .zi },
        .{ "zi_zp", .zi },
        .{ "zi_nd", .zi },
        .{ "zi_np", .zi },
        .{ "cross", .cross },
        .{ "above", .above },
        .{ "timer", .timer },
        // §9.17 — both spellings: the MIR callee keeps the `$`, the unit target
        // naming.zig builds does not (see `enumerateUnits`).
        .{ "$bound_step", .bound_step },
        .{ "bound_step", .bound_step },
        .{ "$discontinuity", .discontinuity },
        .{ "discontinuity", .discontinuity },
    });
    return map.get(name) orelse .none;
}

/// Does this operator need `updateState` to advance anything?
///
/// `above` joined the set when §5.10.3.2's event became edge-triggered: it now
/// owns a `__prev` like `cross` does, and a history nobody advances is a
/// one-shot event.
fn opHasState(k: OpKind) bool {
    return switch (k) {
        .none => false,
        else => true,
    };
}

/// Does this operator's kernel read the CURRENT input? The pure-history ones
/// answer from `Instance` alone, and rendering an input they never emit would
/// leave the unit claiming a parameter (or a cache) nothing references.
/// `emitOperator` renders `in` exactly for these; `planSlots` has to agree,
/// which is why the set lives here and not in either of them.
pub fn opNeedsInput(k: OpKind) bool {
    return switch (k) {
        // `cross` and `timer` joined this set when the §5.10.3 event moved into
        // `eval`: the hit test compares the CURRENT input against `__prev`
        // (`timer`'s "input" being its `start_time`), so the operand has to be
        // rendered there and not only in `updateState`. `zi` joined it for the
        // §4.5.12 static branch, which is a gain on the input, not a held value.
        // `absdelay` joined for `zAbsdelay`'s two input-valued edges: the §4.5.7
        // DC pass-through, and a delay shorter than the accepted step, whose
        // only covering data is the in-flight value.
        .ddt, .idt, .idtmod, .transition, .slew, .above, .laplace, .cross, .timer, .zi, .absdelay => true,
        else => false,
    };
}

/// §5.10.3.1/.2/.3 where each event operator carries its `enable` — the one
/// argument of an analog operator that is a runtime expression, so `UnitPlan`
/// has to keep it live (see `callArgIsValue`) while every other control
/// argument is folded at codegen time.
pub fn enableArgIdx(name: []const u8) ?usize {
    return switch (opKind(name)) {
        .cross => 4, // cross(expr, dir, time_tol, expr_tol, enable)
        .above, .timer => 3, // above(expr, time_tol, expr_tol, enable) / timer(start, period, time_tol, enable)
        else => null,
    };
}

// ===========================================================================
// Fixed emitted text
// ===========================================================================

const header_txt =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\// The model is ONE declaration; its name is the structural key from
    \\// naming.zig, so an unchanged model is byte-identical across rebuilds and
    \\// `zig -fincremental` skips it.
    \\
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\const Self = @This();
    \\
    \\
;

/// LRM Tables 4-14 / 4-15 in VALUE FORM: every function the scalar interface S
/// does not provide natively is composed out of the ones it does, so forward-mode
/// autodiff propagates the ANALYTIC derivative instead of a finite difference.
/// S provides: con addC scale add sub neg mul div exp log sqrt pow(a,f64)
/// sin cos tanh sinh cosh atan abs minC maxC min max val.
///
/// These are FILE-scope helpers, so they run in the default (strict) float
/// mode; `@setFloatMode` is per-unit and does not cross a call. That is the
/// conservative direction — a `.optimized` unit loses fast-math inside a helper,
/// it never gains unsound fast-math.
const math_txt =
    \\// ---- §4.3 math, value form (derivative propagates by composition) ----
    \\
    \\/// Device-routed f64 transcendentals for the SCALAR paths (`R`, the
    \\/// §4.5.15 limiters, zLimexp's clamp constant). Generated devices also
    \\/// compile for NVPTX/AMDGCN (the engine's GPU eval and StateKernel), and
    \\/// those targets have no libm — `@exp`/`@log` on an f64 die at PTX
    \\/// assembly with "no libcall available for fexp". `contract.gm`'s host
    \\/// branch IS the builtin, so host emission is numerically unchanged; its
    \\/// device branch is a self-contained soft port. sin/cos joined when the
    \\/// bjt reached tan through the StateKernel's scalar core (`fsin` cannot
    \\/// select on NVPTX); expm1/log1p/atan stay on std.math (pure Zig).
    \\inline fn zDevExp(x: f64) f64 {
    \\    return contract.gm.exp(x);
    \\}
    \\inline fn zDevLog(x: f64) f64 {
    \\    return contract.gm.log(x);
    \\}
    \\inline fn zDevPow(x: f64, y: f64) f64 {
    \\    return contract.gm.pow(x, y);
    \\}
    \\inline fn zDevSin(x: f64) f64 {
    \\    return contract.gm.sin(x);
    \\}
    \\inline fn zDevCos(x: f64) f64 {
    \\    return contract.gm.cos(x);
    \\}
    \\inline fn zDevTanh(x: f64) f64 {
    \\    return contract.gm.tanh(x);
    \\}
    \\inline fn zDevSinh(x: f64) f64 {
    \\    return contract.gm.sinh(x);
    \\}
    \\inline fn zDevCosh(x: f64) f64 {
    \\    return contract.gm.cosh(x);
    \\}
    \\
    \\fn zTan(comptime S: type, a: S) S { // §4.3.2 tan = sin/cos
    \\    return a.sin().div(a.cos());
    \\}
    \\fn zLog10(comptime S: type, a: S) S { // §4.3.1 log() is base 10
    \\    return a.log().scale(0.4342944819032518);
    \\}
    \\/// §4.3.1 Table 4-14 hypot names the C library function, which is
    \\/// overflow-free — a²+b² composed in S overflowed for legs ≳1e154. The
    \\/// value is the libm one; the derivative (a/h)·da + (b/h)·db is grafted on
    \\/// through zero-valued carriers, `a.addC(-av)` being an S whose VALUE is
    \\/// exactly 0 and whose derivative is da — the same idiom the §12.32 systf
    \\/// reassembly uses. Guarded: at h = 0 hypot has no derivative (a cone tip),
    \\/// and a non-finite h has no slope worth propagating.
    \\fn zHypot(comptime S: type, a: S, b: S) S {
    \\    const av = a.val();
    \\    const bv = b.val();
    \\    const h = std.math.hypot(av, bv);
    \\    var r = S.con(h);
    \\    if (h != 0.0 and std.math.isFinite(h))
    \\        r = r.add(a.addC(-av).scale(av / h)).add(b.addC(-bv).scale(bv / h));
    \\    return r;
    \\}
    \\fn zAsin(comptime S: type, a: S) S { // §4.3.2 asin = atan(x/sqrt(1-x^2))
    \\    return a.div(a.mul(a).neg().addC(1.0).sqrt()).atan();
    \\}
    \\fn zAcos(comptime S: type, a: S) S { // §4.3.2
    \\    return S.con(1.5707963267948966).sub(zAsin(S, a));
    \\}
    \\fn zAsinh(comptime S: type, a: S) S { // §4.3.2 ln(x + sqrt(x^2+1))
    \\    return a.add(a.mul(a).addC(1.0).sqrt()).log();
    \\}
    \\fn zAcosh(comptime S: type, a: S) S { // §4.3.2 ln(x + sqrt(x^2-1))
    \\    return a.add(a.mul(a).addC(-1.0).sqrt()).log();
    \\}
    \\fn zAtanh(comptime S: type, a: S) S { // §4.3.2 0.5*ln((1+x)/(1-x))
    \\    return a.addC(1.0).div(a.neg().addC(1.0)).log().scale(0.5);
    \\}
    \\fn zAtan2(comptime S: type, y: S, x: S) S { // §4.3.2
    \\    // Value-level branch only: every arm is atan(y/x) plus a CONSTANT, so
    \\    // each arm carries the exact derivative of atan2 on its quadrant.
    \\    const xv = x.val();
    \\    if (xv > 0.0) return y.div(x).atan();
    \\    if (xv < 0.0) {
    \\        const c: f64 = if (y.val() >= 0.0) 3.141592653589793 else -3.141592653589793;
    \\        return y.div(x).atan().addC(c);
    \\    }
    \\    const yv = y.val();
    \\    return S.con(if (yv > 0.0) 1.5707963267948966 else if (yv < 0.0) -1.5707963267948966 else 0.0);
    \\}
    \\fn zFloor(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@floor(a.val()));
    \\}
    \\fn zCeil(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@ceil(a.val()));
    \\}
    \\/// §4.2.4 `%` keeps the sign of the first operand — C's fmod, which `@rem`
    \\/// on f64 is, EXACTLY. The composed `a − b·trunc(a/b)` this replaces lost
    \\/// the whole remainder to the subtraction's rounding once |a| ≳ 2^53·|b|.
    \\/// The derivative treatment is unchanged (k = trunc(a/b) is constant a.e.,
    \\/// so d = da − k·db), carried by zero-valued grafts so the exact value
    \\/// survives; a non-finite k (b = 0, or a/b overflowed) has no slope worth
    \\/// propagating and degrades to da alone.
    \\fn zFmod(comptime S: type, a: S, b: S) S {
    \\    const av = a.val();
    \\    const bv = b.val();
    \\    const k = @trunc(av / bv);
    \\    var r = S.con(@rem(av, bv)).add(a.addC(-av));
    \\    if (std.math.isFinite(k)) r = r.sub(b.addC(-bv).scale(k));
    \\    return r;
    \\}
    \\/// §4.3.1 pow with a non-constant exponent. The exp(y·ln x) composition
    \\/// this replaces was NaN on the clause's own legal domain "if x < 0, all
    \\/// integer y". The value is S's own pow, which handles the negative-base
    \\/// integral-y sign itself; the derivatives are grafted on zero-valued
    \\/// carriers:
    \\///   ∂/∂x = y·x^(y−1)  — valid for x > 0 and for integral y of either sign;
    \\///   ∂/∂y = x^y·ln(x)  — only for x > 0. For x ≤ 0 the legal y move in
    \\///   integer steps, so no continuous ∂/∂y exists and 0 is the honest slope.
    \\/// Non-finite slopes (x = 0 with y < 1, domain-error NaNs) are dropped the
    \\/// same way zHypot drops its cone tip.
    \\/// Both transcendentals go through `S.con(x)`, not `std.math.pow` and
    \\/// `@log`, for the reason `devSafe` exists: a unit body also compiles
    \\/// for nvptx, which has no libm, and a raw one is "no libcall available
    \\/// for flog/fexp" at PTX assembly. On a host S it is the same libm call,
    \\/// bit for bit, and the zero-derivative carriers fold away.
    \\fn zPow(comptime S: type, a: S, b: S, comptime varying_exponent: bool) S {
    \\    const x = a.val();
    \\    const y = b.val();
    \\    const v = S.con(x).pow(y).val();
    \\    // y·x^(y−1) = y·v/x — algebraically exact for x != 0, the negative-base
    \\    // integral-y clause included, and ONE pow instead of two. A second
    \\    // `S.con(x).pow(y - 1.0)` was half of the 828k pow calls on
    \\    // tran/fourbitadder and half of the 51% of instructions mos6_inverter
    \\    // spent under pow (callgrind, 2026-09-07): every junction exponent in
    \\    // every SPICE model is a model PARAMETER, so codegen's `.pow` arm sends
    \\    // all of them here rather than down `Dual.pow`'s own c·p/x.
    \\    //
    \\    // x == 0 keeps the second pow, and is NOT a rounding concern: at y == 1
    \\    // the true slope is 1, but v/x is 0/0 = NaN and the gate below would
    \\    // drop the term and flatten the Jacobian row. `mjs` defaults to 0 in
    \\    // bjt.va, so `1 - mjs` is exactly that exponent and the substrate base
    \\    // `1 - v/ps` reaches exactly 0 at v == ps. The branch is never taken on
    \\    // a normal bias point, so the hot path is still one pow, and where it
    \\    // IS taken the expression is the old one character for character.
    \\    // Elsewhere the two forms sit within 6 ulp of a 60-digit reference and
    \\    // neither is uniformly closer; the result is a Jacobian entry, and
    \\    // Newton converges to the accuracy of the RESIDUAL.
    \\    const gx = if (x != 0.0) y * v / x else y * S.con(x).pow(y - 1.0).val();
    \\    const gy: f64 = if (varying_exponent and x > 0.0) v * S.con(x).log().val() else 0.0;
    \\    var r = S.con(v);
    \\    if (std.math.isFinite(gx) and gx != 0.0) r = r.add(a.addC(-x).scale(gx));
    \\    if (std.math.isFinite(gy) and gy != 0.0) r = r.add(b.addC(-y).scale(gy));
    \\    return r;
    \\}
    \\/// §9.17.3 `$limit(access, user_function, args…)`: the value is what the
    \\/// user limiter returned, the DERIVATIVE is the access function's.
    \\///
    \\/// SPICE evaluates the device at the limited bias and stamps
    \\/// `I(vlim) + g(vlim)·(v − vlim)`, so the residual stays linear in the
    \\/// true unknown past the clamp point and the Jacobian entry never
    \\/// vanishes. Differentiating the limiter instead gives dv_lim/dv = 0
    \\/// inside the clamped region — a device contributing no conductance,
    \\/// which is a singular row for a floating internal node. So: shift the
    \\/// probe by the constant the clamp moved it, rather than replace it.
    \\fn zLimitUf(comptime S: type, vnew: S, vlim: S) S {
    \\    return vnew.addC(vlim.val() - vnew.val());
    \\}
    \\fn zIabs(a: i64) i64 { // §4.3.1 integer abs, §3.2's 32-bit result
    \\    return @as(i32, @truncate(if (a < 0) -%a else a));
    \\}
    \\/// §4.2.11 the shift COUNT reads as unsigned: a negative i64 count is a
    \\/// reinterpreted value ≥ 2^63, which vacates every one of §3.2.1's 32 bits
    \\/// — so the answer is 0, exactly like any other over-wide count. Without
    \\/// the guard `std.math.shl`/`shr` take a negative count as "shift the
    \\/// OTHER way" (8 << -1 came out 4, 8 >> -1 came out 16). Positive counts
    \\/// keep the std functions' verified over-wide-is-0 semantics untouched.
    \\fn zShl(a: i64, n: i64) i64 {
    \\    return if (n < 0) 0 else std.math.shl(i64, a, n);
    \\}
    \\fn zShr(a: u32, n: i64) u32 {
    \\    return if (n < 0) 0 else std.math.shr(u32, a, n);
    \\}
    \\fn zClog2(a: i64) i64 { // §9.11 $clog2
    \\    if (a <= 1) return 0;
    \\    const m: u64 = @intCast(a - 1);
    \\    return 64 - @as(i64, @clz(m));
    \\}
    \\fn zStrCmp(a: []const u8, b: []const u8) i64 { // §3.3.1 string relations
    \\    return switch (std.mem.order(u8, a, b)) { .lt => -1, .eq => 0, .gt => 1 };
    \\}
    \\fn zLimexp(comptime S: type, a: S) S { // §4.5.13 — user-invoked ONLY
    \\    const lim = 80.0;
    \\    if (a.val() > lim) return a.addC(1.0 - lim).scale(zDevExp(lim));
    \\    return a.exp();
    \\}
    \\
    \\
;

/// §4.5.2 the operator kernels. All take the CURRENT (S-valued) operator input
/// plus the accepted state, so the Jacobian of the companion model is analytic.
const ops_txt =
    \\// ---- §4.5 analog operator kernels ----
    \\
    \\fn zDdt(comptime S: type, v: S, prev: f64, dt: f64) S { // §4.5.3
    \\    if (dt <= 0.0) return S.con(0.0); // no time derivative in a static analysis
    \\    return v.addC(-prev).scale(1.0 / dt);
    \\}
    \\fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S { // §4.5.4
    \\    if (dt <= 0.0) return S.con(ic); // §4.5.4 DC value is the initial condition
    \\    return v.scale(dt).addC(acc);
    \\}
    \\fn zIdtReset(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, assert_: f64) S { // §4.5.4
    \\    // "idt() returns the initial conditions during DC and IC analyses,
    \\    // and whenever assert is nonzero."
    \\    if (assert_ != 0.0) return S.con(ic);
    \\    return zIdt(S, v, acc, dt, ic);
    \\}
    \\fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64 {
    \\    if (dt <= 0.0) return ic;
    \\    return acc + v * dt;
    \\}
    \\fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S { // §4.5.5
    \\    const raw = zIdt(S, v, acc, dt, ic);
    \\    if (!(m > 0.0)) return raw;
    \\    // The wrap subtracts a piecewise-CONSTANT multiple of the modulus, so
    \\    // the derivative of the wrapped integral is the derivative of the raw one.
    \\    return raw.addC(-m * @floor((raw.val() - o) / m));
    \\}
    \\fn zWrap(x: f64, modulus: f64, offset: f64) f64 { // §4.5.5 idtmod
    \\    if (!(modulus > 0.0)) return x;
    \\    return x - modulus * @floor((x - offset) / modulus);
    \\}
    \\fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S { // §4.5.9
    \\    if (dt <= 0.0) return v;
    \\    return v.minC(prev + rise * dt).maxC(prev - fall * dt);
    \\}
    \\/// §5.10.3.1/§4.5.10 the crossing test for a direction that is a PARAMETER
    \\/// (a constant_expression the model card owns, so codegen cannot pick the
    \\/// comparison at emit time): +1 rising only, -1 falling only, anything
    \\/// else either — the EXACT decode `Gen.crossTest` applies to a folded one,
    \\/// so overriding the parameter to the value the default had changes nothing.
    \\fn zCrossDir(dir: f64, prev: f64, in: f64) bool {
    \\    if (dir == 1.0) return prev <= 0.0 and in > 0.0;
    \\    if (dir == -1.0) return prev >= 0.0 and in < 0.0;
    \\    return (prev <= 0.0 and in > 0.0) or (prev >= 0.0 and in < 0.0);
    \\}
    \\/// §4.5.8 the fraction of the current excursion the ramp has traversed.
    \\/// "transition() forces all positive transitions of expr to occur over
    \\/// rise_time and all negative transitions to occur in fall_time", and the
    \\/// result "describes a piecewise linear function over time" — so the shape
    \\/// is (t - t0)/tt clamped into [0, 1], with tt picked by the DIRECTION of
    \\/// the excursion and t0 the time the excursion began.
    \\///
    \\/// A zero transition time is §4.5.8's own degenerate case ("If neither
    \\/// rise_time nor fall_time are specified or are equal to zero (0.0) …"),
    \\/// left to `default_transition and, with no directive, to the simulator:
    \\/// here that is an instantaneous edge, fraction 1.
    \\fn zTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) f64 {
    \\    const tt = if (target >= from) rise else fall;
    \\    if (!(tt > 0.0)) return 1.0;
    \\    return @min(@max((t - t0) / tt, 0.0), 1.0);
    \\}
    \\fn zTransition(comptime S: type, v: S, from: f64, t0: f64, t: f64, dt: f64, rise: f64, fall: f64) S { // §4.5.8
    \\    // "In DC analysis, transition() passes the value of the expr directly
    \\    // to its output." There is no elapsed time to ramp over.
    \\    if (dt <= 0.0) return v;
    \\    // LINEAR in the current input, so the Jacobian the solver gets is the
    \\    // slope of the ramp itself.
    \\    const f = zTransFrac(v.val(), from, t0, t, rise, fall);
    \\    return v.addC(-from).scale(f).addC(from);
    \\}
    \\/// §4.5.8 accepted-step bookkeeping: move the ramp's origin, or leave it.
    \\///
    \\/// LEAVE IT is the important half. While the output is still climbing
    \\/// towards its input the excursion is the one that started at `from`, and
    \\/// re-arming the origin every step would shrink the remaining distance by
    \\/// the same factor each time — an exponential decay wearing a ramp's
    \\/// coefficients, which is the bug this operator used to have.
    \\fn zTransStep(in: f64, from: *f64, t0: *f64, t: f64, dt: f64, rise: f64, fall: f64) void {
    \\    if (dt <= 0.0) { // the DC point: the output IS the input, so arm here
    \\        from.* = in;
    \\        t0.* = t;
    \\        return;
    \\    }
    \\    const f = zTransFrac(in, from.*, t0.*, t, rise, fall);
    \\    const y = from.* + (in - from.*) * f;
    \\    // Settled — the output has caught up — so the NEXT excursion starts
    \\    // from here, and its rise/fall time is counted from this instant.
    \\    if (f >= 1.0 or y == in) {
    \\        from.* = in;
    \\        t0.* = t;
    \\        return;
    \\    }
    \\    // §4.5.8 says nothing about an input that REVERSES mid-ramp. The
    \\    // reading taken here is the one that keeps the output continuous: the
    \\    // new excursion starts where the output actually is (`y`), and is
    \\    // traversed in the full rise/fall time of its own direction. Detected
    \\    // as the output sitting on the opposite side of the origin from the
    \\    // target, which cannot happen while a single excursion is in progress.
    \\    if ((in - from.*) * (y - from.*) < 0.0) {
    \\        from.* = y;
    \\        t0.* = t;
    \\    }
    \\}
    \\
;

/// §5.10.5 the `nextBreakpoint` kernel. Its own block, gated on `usesOp(.timer)`
/// like the history and filter kernels, so the 36 foundry models — none of which
/// uses `timer` — keep a byte-identical device.zig.
const timer_txt =
    \\// ---- §5.10.5 timer breakpoints ----
    \\
    \\/// The next time a `timer(start, period)` fires, STRICTLY after `t`.
    \\/// The only source in Verilog-A that means "put a timepoint here" — see
    \\/// `emitNextBreakpoint`. Must agree exactly with the `.timer` arm of
    \\/// `updateState`, which is the code that actually raises `__hit`.
    \\fn zNextTimer(start: f64, period: f64, t: f64) ?f64 {
    \\    // `updateState` clamps `__next` UP from its 0.0 initialiser, so a start
    \\    // before the origin fires at the origin — already a timepoint.
    \\    const s = @max(start, 0.0);
    \\    if (s > t) return s;
    \\    if (!(period > 0.0)) return null; // one-shot, and its single fire is behind us
    \\    // Fire k is s + k*period. Take the first k past `t`, then repair the
    \\    // two one-ulp outcomes of the division: landing high SKIPS a fire,
    \\    // landing low returns `t` itself and the transient walk stops advancing.
    \\    var n = @floor((t - s) / period) + 1.0;
    \\    if (n > 1.0 and s + (n - 1.0) * period > t) n -= 1.0;
    \\    if (s + n * period <= t) n += 1.0;
    \\    const next = s + n * period;
    \\    // Strictly `> t`, never `>=`: a host that re-asks from the breakpoint it
    \\    // was just handed (analysis/src/tran/matex.zig walks exactly that way)
    \\    // spins forever on an equal answer. When `period` is so small beside `t`
    \\    // that no later time is representable, "no breakpoint" is the honest —
    \\    // and terminating — answer.
    \\    return if (next > t and std.math.isFinite(next)) next else null;
    \\}
    \\
;

/// §9.5.3/§9.5.4.2 the string formatter's scratch and the scanner, emitted
/// VERBATIM from `str_kernels.zig` for the same reason `filt_txt` is: the rows
/// codegen's tests scan are byte-for-byte the ones the device scans. Only
/// devices that actually call `$sformat`/`$swrite`/`$sscanf` carry them.
const str_txt = "// ---- §9.5.3/§9.5.4.2 string kernels (src/backend/str_kernels.zig) ----\n\n" ++
    @embedFile("str_kernels.zig");

/// §9.13 the probabilistic distribution kernels, emitted VERBATIM from
/// `rng_kernels.zig` on the same terms as `str_txt`: the stream codegen's tests
/// exercise is byte-for-byte the stream the device draws from. Only devices that
/// call one of Table 9-10's 17 names carry it.
const rng_txt = "// ---- §9.13 probabilistic distribution kernels (src/backend/rng_kernels.zig) ----\n\n" ++
    @embedFile("rng_kernels.zig");

/// §9.21 the table-model interpolator, emitted VERBATIM from
/// `table_kernels.zig` on the same terms. Only devices that call
/// `$table_model` carry it.
const table_txt = "// ---- §9.21 table model kernels (src/backend/table_kernels.zig) ----\n\n" ++
    @embedFile("table_kernels.zig");

/// §9.5 the file-descriptor table and its operations, emitted VERBATIM from
/// `file_kernels.zig` on the same terms. Carried ONLY by a device that both calls
/// the family and is built `display == .emit` — the artifact that has a host
/// willing to run side effects. A device compiled for a solver has no `display`
/// decl to sequence them in, so it has no table, so §9.5.1's "a zero is returned
/// for the mcd or fd" is its truthful answer to `$fopen`.
const file_txt = "// ---- §9.5 file descriptor I/O kernels (src/backend/file_kernels.zig) ----\n\n" ++
    @embedFile("file_kernels.zig");

/// §4.5.15 the SPICE limiters, emitted VERBATIM from `limit_kernels.zig` on the
/// same terms. Carried only by a device with an honoured `$limit` call — no unit
/// body can reach them, because `$limit` renders as the identity of its probe
/// there (`cg_limit.zig`'s header says why).
const limit_txt = "// ---- §4.5.15 SPICE limiting kernels (src/backend/limit_kernels.zig) ----\n\n" ++
    @embedFile("limit_kernels.zig");

/// §4.5.11/§4.5.12 the filter kernels, emitted VERBATIM from `filter_kernels.zig`
/// so the numerics codegen's tests exercise are byte-for-byte the numerics the
/// device runs. Only devices that actually use a filter carry them.
const filt_txt = "// ---- §4.5.11/§4.5.12 filter kernels (src/filter_kernels.zig) ----\n\n" ++
    @embedFile("filter_kernels.zig") ++ "\n" ++ zi_hold_txt;

/// §4.5.12 the residual side of a Z-filter, the counterpart of `zZiStep`'s
/// sampling side. It lives here rather than in `filter_kernels.zig` only
/// because it is the piece `emitOperator` calls; the numerics are the same
/// sections `__sec` builds.
const zi_hold_txt =
    \\/// §4.5.12 the Z-filter as the residual sees it. Between samples it "acts
    \\/// like a simple sample-and-hold", so the output is the held constant and
    \\/// carries no derivative. `dt <= 0` is a static analysis: there is no
    \\/// history and no clock, a constant input makes every sample equal, so
    \\/// z = 1 and the filter IS its DC gain H(1) = ∏ Σ_k num[i][k] / Σ_k den[i][k]
    \\/// — the exact value of the transfer function at z = 1, applied to the
    \\/// input so the operating point gets the right Jacobian too. This mirrors
    \\/// `zLaplace`'s H(0) branch; without it every zi_* answered a DC operating
    \\/// point with the 0.0 its `__out` field initialises to.
    \\pub fn zZiHold(
    \\    comptime S: type,
    \\    comptime NS: usize,
    \\    comptime D: usize,
    \\    uin: S,
    \\    sec: [NS][2][D + 1]f64,
    \\    dt: f64,
    \\    out: f64,
    \\) S {
    \\    if (dt > 0.0) return S.con(out);
    \\    var y = uin;
    \\    for (0..NS) |i| {
    \\        var num: f64 = 0.0;
    \\        var den: f64 = 0.0;
    \\        for (sec[i][0]) |c| num += c;
    \\        for (sec[i][1]) |c| den += c;
    \\        y = y.scale(num / den);
    \\    }
    \\    return y;
    \\}
    \\
;

const hist_txt =
    \\/// §4.5.7 the delayed value, as the residual sees it: Output(t) = Input(t − td).
    \\///
    \\/// Two edges are decided HERE rather than by the ring scan below:
    \\///
    \\///  · dt ≤ 0 is a static analysis — "In DC and operating point analyses,
    \\///    absdelay() returns the value of its input" — so `vin` passes through,
    \\///    derivative and all, exactly like `zTransition`'s DC branch.
    \\///  · a td SHORTER than the step the host just took queries past the newest
    \\///    accepted sample. The only data covering (ts[newest], now] is the
    \\///    CURRENT in-flight value, so the answer interpolates between the newest
    \\///    sample and `vin` — the same linear reading `zHistAt` applies inside
    \\///    the history. That keeps the output continuous in t and carries the
    \\///    f·∂vin derivative the td → 0 (identity) limit requires. The scan used
    \\///    to fall through to the newest sample here, which silently stretched
    \\///    every delay shorter than a step to the step itself. (Clamping was the
    \\///    other candidate; it answers a PAST query with a value from the wrong
    \\///    time and keeps the Jacobian blind to an input the output already
    \\///    partially tracks, so interpolation is the sound choice.)
    \\///
    \\/// Inside the history the delayed value has no dependence on the current
    \\/// unknowns, so it is injected as a constant (derivative 0) — the correct
    \\/// companion model for a pure transport delay. The f ≤ 1 clamp covers a
    \\/// runtime-negative td, which lowering rejects where it can fold.
    \\fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u32, now: f64, dt: f64, td: f64) S {
    \\    if (dt <= 0.0) return vin;
    \\    const t = now - td;
    \\    const newest = (head + ts.len - 1) % ts.len;
    \\    if (t > ts[newest]) {
    \\        const span = now - ts[newest];
    \\        if (span <= 0.0) return vin;
    \\        const f = @min((t - ts[newest]) / span, 1.0);
    \\        return vin.scale(f).addC(vs[newest] * (1.0 - f));
    \\    }
    \\    return S.con(zHistAt(ts, vs, head, t));
    \\}
    \\/// §4.5.7 absdelay history: a fixed ring of (t, v) samples, linearly
    \\/// interpolated.
    \\fn zHistAt(ts: []const f64, vs: []const f64, head: u32, t: f64) f64 {
    \\    const n = ts.len;
    \\    // O(1) clamp for a query at/before the oldest sample (ts[head] once the
    \\    // ring is full, which the seeding first push below guarantees) — the
    \\    // scan would walk all n entries to reach the same answer.
    \\    if (t <= ts[head]) return vs[head];
    \\    var i: usize = 0;
    \\    var newer: usize = (head + n - 1) % n;
    \\    while (i < n) : (i += 1) {
    \\        const older = (newer + n - 1) % n;
    \\        if (ts[older] <= t and t <= ts[newer]) {
    \\            const span = ts[newer] - ts[older];
    \\            if (span <= 0.0) return vs[newer];
    \\            const f = (t - ts[older]) / span;
    \\            return vs[older] + (vs[newer] - vs[older]) * f;
    \\        }
    \\        newer = older;
    \\    }
    \\    // Query older than the whole ring: clamp to the OLDEST sample.
    \\    // Returning the newest here (as this once did) collapses the delay
    \\    // to zero — the output tracks the input live, which is maximally
    \\    // wrong for a transport operator. Oldest is bounded staleness.
    \\    return vs[head];
    \\}
    \\fn zHistPush(ts: []f64, vs: []f64, head: *u32, t: f64, v: f64) void {
    \\    // First push seeds the WHOLE ring: before it, every slot is an
    \\    // unwritten 0, so a query older than recorded history (any t < td
    \\    // early in a transient) read 0 V instead of the operating point —
    \\    // the line launched a false transient off a value nothing ever wrote.
    \\    // Full-from-first-push also makes `head` the oldest sample always,
    \\    // which zHistAt's clamps rely on.
    \\    if (head.* == 0 and ts[ts.len - 1] == 0) {
    \\        @memset(ts, t);
    \\        @memset(vs, v);
    \\        head.* = 1;
    \\        return;
    \\    }
    \\    ts[head.*] = t;
    \\    vs[head.*] = v;
    \\    head.* = (head.* + 1) % @as(u32, @intCast(ts.len));
    \\}
    \\
;

// ---- the `u/<key>.zig` file-scope prologue (see `Output.prelude`) ----------
//
// A unit file is a separate Zig FILE, so device.zig's file-scope helpers are
// not in its scope and Zig has no textual include. These blocks ALIAS them —
// one declaration for `zig` to analyse, versus one copy per unit if the helper
// text were re-emitted, which would multiply exactly the AstGen + Sema work the
// split exists to remove. `..` is the work_dir: `u/<key>.zig` sits one level
// under `device.zig`, which is the module root.
//
// They are DERIVED from the helper text by `aliasesOf`, so there is nothing to
// keep in sync: a helper that is emitted is aliased, by construction.

const helpers_head_txt =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\// The §4.3/§4.5 kernels, public so `u/<key>.zig` can alias them. device.zig
    \\// carries the same text privately: it must stay a valid stand-alone device.
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\
    \\
;

const prelude_head_txt =
    \\// GENERATED BY VerA — DO NOT EDIT.
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\const dev = @import("../device.zig");
    \\const h = @import("../h.zig");
    \\const U = dev.U;
    \\const Model = dev.Model;
    \\const Instance = dev.Instance;
    \\const AnalysisKind = dev.AnalysisKind;
    \\const n_u = contract.nU(dev);
    \\
;

/// The `z*` helpers `src` publishes, aliased for a unit file: `const zFoo = h.zFoo;`.
///
/// DERIVED, not written out. The hand-written list this replaces drifted
/// silently: a new `fn zFoo` in `ops_txt` compiles into device.zig and leaves
/// every unit file naming a decl that is not in scope there — and only for the
/// models that happen to use it.
///
/// A line is a top-level declaration by the same predicate `publish` applies
/// (`fn ` or `const `), plus the `pub ` form, because the `@embedFile` blocks
/// (`str_kernels.zig` and friends) arrive already public and `publish` leaves
/// them alone. The name must then be `z` + an UPPERCASE letter: that is the
/// spelling of every helper an emitted body calls, and it is what keeps a
/// kernel's own internals (`zstd`, `zfIo`, `zf_max`, `ZScan`) out of the
/// prologue — none is ever named by generated code, and all four were omitted
/// from the hand list for that reason. Dropping the clause is legal and
/// unreferenced, but it changes the emitted bytes for no gain.
fn aliasesOf(comptime src: []const u8) []const u8 {
    comptime {
        // ponytail: a CEILING, not a measurement — the longest block is
        // file_kernels.zig at ~440 lines and this is two orders above it.
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            const decl = if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line;
            const at: usize = if (std.mem.startsWith(u8, decl, "fn "))
                "fn ".len
            else if (std.mem.startsWith(u8, decl, "const "))
                "const ".len
            else
                continue;
            const rest = decl[at..];
            var n: usize = 0;
            while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) n += 1;
            const name = rest[0..n];
            if (name.len < 2 or name[0] != 'z' or !std.ascii.isUpper(name[1])) continue;
            out = out ++ "const " ++ name ++ " = h." ++ name ++ ";\n";
        }
        return out;
    }
}

const prelude_math_txt = aliasesOf(math_txt ++ ops_txt);
const prelude_timer_txt = aliasesOf(timer_txt);
const prelude_hist_txt = aliasesOf(hist_txt);
const prelude_filt_txt = aliasesOf(filt_txt);

/// §9.4.3 `%<width>d`. Aliased whenever `display_txt` is emitted, which is a
/// printing artifact OR any device that formats into a string (§9.5.3 runs the
/// same formatter, and its call site can be in any unit, not just the display
/// one).
const prelude_display_txt = aliasesOf(display_txt);

/// §9.21. `zTabRes` is a type function, so it is aliased on the same terms as a
/// function — the recursion's return type names it.
const prelude_table_txt = aliasesOf(table_txt);
const prelude_rng_txt = aliasesOf(rng_txt);
const prelude_file_txt = aliasesOf(file_txt);
const prelude_str_txt = aliasesOf(str_txt);

/// Plain-f64 instantiation of the scalar interface. `updateState` has to run a
/// unit body on the accepted solution, where derivatives are meaningless.
/// §9.4.3 support, emitted ONLY into the printing artifact (`display == .emit`).
///
/// `std.fmt` writes `+42` for `{d:>5}`: once a width fixes the field, it spells
/// the sign. §9.4.3 — and C's `%5d`, and every other Verilog tool — writes
/// ` 42`. Padding the rendered DECIMAL rather than the integer gets that back,
/// and `{s:>5}` has no opinion about signs.
///
// ponytail: 24 bytes is i64's widest decimal (20 chars) plus slack, so the
// `catch unreachable` cannot fire. Zero-padding a NEGATIVE number still yields
// `00-42` where C yields `-0042`; nothing in the corpus writes `%05d` on a
// negative, and fixing it means reimplementing the sign placement here.
const display_txt =
    \\fn zPadInt(buf: []u8, v: i64) []const u8 { // §9.4.3 %<width>d
    \\    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
    \\}
    \\
    \\/// §9.7 simulation control: the run ends here. Declared `f64` and not
    \\/// `noreturn` ON PURPOSE: statements after a §9.7.3 `$fatal` are legal
    \\/// dead code (exhaustive/011 writes `$finish; $stop;` after one), and a
    \\/// noreturn-typed call site would make Zig refuse the block for
    \\/// unreachable code. The value is never produced.
    \\fn zHalt(code: u8) f64 {
    \\    std.process.exit(code);
    \\}
    \\
;

const pscalar_txt =
    \\/// Value-only scalar for `precompute`, mirroring the ARPice host Dual's
    \\/// VALUE semantics op for op (gompute.math forwards to the builtins on
    \\/// the host): div is a*(1/b), abs/min/max/minC/maxC branch, expm1/log1p
    \\/// are the Kahan corrections over exp/log. R (plain a/b, std.math.expm1)
    \\/// is deliberately NOT reused: updateState keeps R, so accepted-state
    \\/// bits do not move; eval keeps the host's S, so a field read must
    \\/// reproduce the host chain it replaced bit for bit.
    \\const P = struct {
    \\    v: f64,
    \\    const T = @This();
    \\    pub fn con(c: f64) T { return .{ .v = c }; }
    \\    pub fn val(a: T) f64 { return a.v; }
    \\    pub fn ddxAt(_: T, _: usize) f64 { return 0.0; }
    \\    pub fn add(a: T, b: T) T { return .{ .v = a.v + b.v }; }
    \\    pub fn sub(a: T, b: T) T { return .{ .v = a.v - b.v }; }
    \\    pub fn neg(a: T) T { return .{ .v = -a.v }; }
    \\    pub fn mul(a: T, b: T) T { return .{ .v = a.v * b.v }; }
    \\    pub fn div(a: T, b: T) T { return .{ .v = a.v * (1.0 / b.v) }; }
    \\    pub fn scale(a: T, c: f64) T { return .{ .v = a.v * c }; }
    \\    pub fn addC(a: T, c: f64) T { return .{ .v = a.v + c }; }
    \\    pub fn exp(a: T) T { return .{ .v = @exp(a.v) }; }
    \\    pub fn log(a: T) T { return .{ .v = @log(a.v) }; }
    \\    pub fn expm1(a: T) T {
    \\        const u = @exp(a.v);
    \\        if (u == 1.0) return .{ .v = a.v };
    \\        if (u - 1.0 == -1.0) return .{ .v = -1.0 };
    \\        return .{ .v = (u - 1.0) * a.v / @log(u) };
    \\    }
    \\    pub fn log1p(a: T) T {
    \\        const u = 1.0 + a.v;
    \\        return .{ .v = if (u == 1.0) a.v else @log(u) * (a.v / (u - 1.0)) };
    \\    }
    \\    pub fn sqrt(a: T) T { return .{ .v = @sqrt(a.v) }; }
    \\    pub fn sin(a: T) T { return .{ .v = @sin(a.v) }; }
    \\    pub fn cos(a: T) T { return .{ .v = @cos(a.v) }; }
    \\    pub fn tanh(a: T) T { return .{ .v = std.math.tanh(a.v) }; }
    \\    pub fn sinh(a: T) T { return .{ .v = std.math.sinh(a.v) }; }
    \\    pub fn cosh(a: T) T { return .{ .v = std.math.cosh(a.v) }; }
    \\    pub fn atan(a: T) T { return .{ .v = std.math.atan(a.v) }; }
    \\    pub fn abs(a: T) T { return if (a.v < 0) .{ .v = -a.v } else a; }
    \\    pub fn minC(a: T, c: f64) T { return if (a.v > c) .{ .v = c } else a; }
    \\    pub fn maxC(a: T, c: f64) T { return if (a.v < c) .{ .v = c } else a; }
    \\    pub fn min(a: T, b: T) T { return if (a.v <= b.v) a else b; }
    \\    pub fn max(a: T, b: T) T { return if (a.v >= b.v) a else b; }
    \\    pub fn pow(a: T, c: f64) T { return .{ .v = std.math.pow(f64, a.v, c) }; }
    \\    pub fn lt(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v < b.v)) }; }
    \\    pub fn le(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v <= b.v)) }; }
    \\    pub fn eq(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v == b.v)) }; }
    \\    pub fn sel(c: T, a: T, b: T) T { return if (c.v != 0.0) a else b; }
    \\};
    \\
    \\
;

const rscalar_txt =
    \\/// Value-only scalar: `updateState` runs unit bodies on the accepted
    \\/// solution, where no derivative is wanted.
    \\const R = struct {
    \\    v: f64,
    \\    const T = @This();
    \\    pub fn con(c: f64) T { return .{ .v = c }; }
    \\    pub fn val(a: T) f64 { return a.v; }
    \\    pub fn ddxAt(_: T, _: usize) f64 { return 0.0; }
    \\    pub fn add(a: T, b: T) T { return .{ .v = a.v + b.v }; }
    \\    pub fn sub(a: T, b: T) T { return .{ .v = a.v - b.v }; }
    \\    pub fn neg(a: T) T { return .{ .v = -a.v }; }
    \\    pub fn mul(a: T, b: T) T { return .{ .v = a.v * b.v }; }
    \\    pub fn div(a: T, b: T) T { return .{ .v = a.v / b.v }; }
    \\    pub fn scale(a: T, c: f64) T { return .{ .v = a.v * c }; }
    \\    pub fn addC(a: T, c: f64) T { return .{ .v = a.v + c }; }
    \\    // Transcendentals via zDev* (math_txt): this type also compiles in
    \\    // the GPU StateKernel, where the raw builtins have no libcall. The
    \\    // host branch of each IS the builtin — host output is unchanged.
    \\    pub fn exp(a: T) T { return .{ .v = zDevExp(a.v) }; }
    \\    pub fn log(a: T) T { return .{ .v = zDevLog(a.v) }; }
    \\    pub fn expm1(a: T) T { return .{ .v = std.math.expm1(a.v) }; }
    \\    pub fn log1p(a: T) T { return .{ .v = std.math.log1p(a.v) }; }
    \\    pub fn sqrt(a: T) T { return .{ .v = @sqrt(a.v) }; }
    \\    pub fn sin(a: T) T { return .{ .v = zDevSin(a.v) }; }
    \\    pub fn cos(a: T) T { return .{ .v = zDevCos(a.v) }; }
    \\    pub fn tanh(a: T) T { return .{ .v = zDevTanh(a.v) }; }
    \\    pub fn sinh(a: T) T { return .{ .v = zDevSinh(a.v) }; }
    \\    pub fn cosh(a: T) T { return .{ .v = zDevCosh(a.v) }; }
    \\    pub fn atan(a: T) T { return .{ .v = std.math.atan(a.v) }; }
    \\    pub fn abs(a: T) T { return .{ .v = @abs(a.v) }; }
    \\    pub fn minC(a: T, c: f64) T { return .{ .v = @min(a.v, c) }; }
    \\    pub fn maxC(a: T, c: f64) T { return .{ .v = @max(a.v, c) }; }
    \\    pub fn min(a: T, b: T) T { return .{ .v = @min(a.v, b.v) }; }
    \\    pub fn max(a: T, b: T) T { return .{ .v = @max(a.v, b.v) }; }
    \\    pub fn pow(a: T, c: f64) T { return .{ .v = zDevPow(a.v, c) }; }
    \\    // Contract masks and select (see contract.zig's S notes).
    \\    pub fn lt(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v < b.v)) }; }
    \\    pub fn le(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v <= b.v)) }; }
    \\    pub fn eq(a: T, b: T) T { return .{ .v = @floatFromInt(@intFromBool(a.v == b.v)) }; }
    \\    pub fn sel(c: T, a: T, b: T) T { return .{ .v = if (c.v != 0.0) a.v else b.v }; }
    \\};
    \\
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Ast = @import("../frontend/ast.zig");
const Preprocessor = @import("../frontend/preprocessor.zig");
const Lexer = @import("../frontend/lexer.zig");
const Parser = @import("../frontend/parser.zig");
const ifconv = @import("../ir/ifconv.zig");

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    low: Lower,
    bag: diag.Bag,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .low = undefined,
            .bag = undefined,
        };
        const arena = out.arena_state.allocator();
        // One diagnostic bag threaded through every stage (diag.zig).
        out.bag = diag.Bag.init(arena);
        const text = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        out.file.builtin_modules = Preprocessor.spice_module_count;
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
        try out.low.lowerFile();
    }

    fn gen(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        return (try self.genOut(gpa)).text;
    }

    /// Same, with §9.4 display tasks emitted — the printing artifact.
    fn genDisplay(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        const a = self.arena_state.allocator();
        return (try generate(a, a, &self.mir, &self.low, v, &fatal, .{ .display = .emit })).text;
    }

    fn genOut(self: *Harness, gpa: std.mem.Allocator) !Output {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        // ponytail: the harness hands `generate` its arena as the output gpa, so
        // `deinit` reclaims the result with everything else and no test needs a
        // matching free. Ceiling: these fixtures are kilobytes; the arena regrow
        // cost `generate`'s gpa parameter exists to avoid only bites at MB scale.
        const a = self.arena_state.allocator();
        // The harness bag is arena-lived and never detached, so unlike the
        // driver's it is still the right one to hand codegen.
        return generate(a, a, &self.mir, &self.low, v, &fatal, .{ .diags = &self.bag });
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

const resistor_va =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "codegen: --jac-f32 adds a permission decl and changes not one other byte" {
    // The whole claim of the mixed-precision work, pinned. `eval` is generic
    // over S and reaches it only through primitives that take and return f64
    // (`con`, `scale`, `addC`, `val`), so the WIDTH of the derivative a host
    // carries inside S is the host's choice and no arithmetic here depends on
    // it. If this flag ever starts moving other bytes, that genericity has been
    // broken somewhere and this test is where it shows up.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();

    const v = try proof.prove(std.testing.allocator, &h.mir, &h.low, &h.bag);
    defer v.deinit(std.testing.allocator);
    var fatal = false;
    const a = h.arena_state.allocator();
    const off = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{})).text;
    const on = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .jac_f32 = true })).text;

    try std.testing.expect(std.mem.indexOf(u8, off, "jac_f32") == null);
    const decl = "pub const jac_f32 = true;\n\n";
    const at = std.mem.indexOf(u8, on, decl) orelse return error.NoPermissionDecl;
    // Excise the block the flag added — comment header included — and what is
    // left has to be the default output byte for byte.
    const hdr = std.mem.lastIndexOf(u8, on[0..at], "/// This device permits").?;
    const stripped = try std.mem.concat(a, u8, &.{ on[0..hdr], on[at + decl.len ..] });
    try std.testing.expectEqualStrings(off, stripped);

    // `--jac-f32-host` is the stronger request and emits the permission too:
    // a host width without the permission is the one combination
    // `tools/contract.zig` rejects, so codegen must never produce it.
    const host = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .jac_f32_host = true })).text;
    try std.testing.expect(std.mem.indexOf(u8, host, decl) != null);
    try std.testing.expect(std.mem.indexOf(u8, host, "pub const jac_f32_host = true;") != null);
}

test "codegen: a core that reads analysis()/sim-state carries core_reads_simstate" {
    // A device-resident host republishes t/dt/kind on the HOST Instance only,
    // so a core reading them there evals stale — the decl is how it knows to
    // keep such a device off the device. The resistor must NOT carry it (its
    // updateState epilogue latch, when present, is not a core read).
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, resistor_va, &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "core_reads_simstate") == null);
    }
    {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator,
            \\module ak(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ V(p, n) * (analysis("tran") ? 2.0 : 1.0);
            \\endmodule
        , &h);
        defer h.deinit();
        const src = try h.gen(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, src, "pub const core_reads_simstate = true;") != null);
    }
}

test "codegen: one stably-named declaration for the model, thin dispatcher" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, src, "pub const U = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "r: f64 = 1000.0,") != null);
    // The declaration name is naming.zig's structural key, and it is NOT a MIR
    // index. Since the merge there is ONE of them per model: the per-contribution
    // keys still exist (naming.zig, proof.zig, the `Instance` state fields) but
    // no longer name a declaration.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(comptime S: type,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = core(S, x, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "contract.validate(Self)") != null);
    // no reactive part ⇒ no q()
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
    // NEVER a global MIR value index in a name
    try std.testing.expect(std.mem.indexOf(u8, src, "v12") == null);
}

const shared_va =
    \\module sh(p, n);
    \\  inout p, n;
    \\  electrical p, n, m;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  real g;
    \\  analog begin
    \\    g = exp(V(p, n) / r) * V(p, m);
    \\    I(p, m) <+ g * 2.0;
    \\    I(m, n) <+ g * 3.0;
    \\  end
    \\endmodule
;

test "codegen: two contributions sharing a subexpression evaluate it ONCE" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, shared_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One declaration, named structurally — no MIR index anywhere in it.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn sh__common__core(comptime S: type,") != null);
    // ONE call for the whole residual, not one per contribution. This is the
    // runtime half of the merge: LLVM does not CSE repeated calls to a body of
    // this size (measured — see `planCommon`), so the count here IS the number
    // of times the model runs per Newton iteration.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, src, "const m = core(S, x, model, inst);"),
    );
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    // The costly part — `exp` — is emitted once. That is the whole scaling
    // defect. Counted past the file-scope helpers, several of which spell
    // `.exp()` themselves.
    const decls = src[std.mem.indexOf(u8, src, "// ---- the model, in one declaration ----").?..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, decls, ".exp()"));

    // §4.3: `exp` of an unbounded probe is not provably finite, so both units
    // are `.strict` and the declaration they share must be too — compiling it
    // `.optimized` would assert `ninf` on behalf of a unit that never had it.
    const at = std.mem.indexOf(u8, src, "fn sh__common__core").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], "@setFloatMode(.strict);") != null);
}

test "codegen: one declaration even for a single contribution" {
    // No threshold. A model with one contribution gets the same shape as a model
    // with fifty, because the shape is not an optimisation any more — `eval`
    // reads its targets out of one struct and there is nothing to opt out of.
    // The extra call is free: a one-contribution core is small enough for LLVM
    // to inline, which is exactly what it will not do for a 60 000-line one.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= core(S, x, model, inst);"));
}

test "codegen: --outline-chunk splits the core into noinline chunk fns; off by default" {
    // ~20 slotted statements (each gN is used twice, so it keeps a slot);
    // chunked at 6 the core must come out as a DRIVER (hoist arrays, one
    // `@call(.never_inline, ...)` per chunk, the one return) plus sibling
    // chunk fns. Bit-level equivalence of chunked output is pinned outside
    // the unit tests (bsim4va/hisimhv/bsimsoi f/q/partials, commit message);
    // here we pin the SHAPE and that the default emits none of it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module oc(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  real g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, acc;
        \\  analog begin
        \\    g1 = exp(V(p, n) * 1.0); g2 = exp(V(p, n) * 2.0);
        \\    g3 = exp(V(p, n) * 3.0); g4 = exp(V(p, n) * 4.0);
        \\    g5 = exp(V(p, n) * 5.0); g6 = exp(V(p, n) * 6.0);
        \\    g7 = exp(V(p, n) * 7.0); g8 = exp(V(p, n) * 8.0);
        \\    g9 = exp(V(p, n) * 9.0); g10 = exp(V(p, n) * 10.0);
        \\    acc = g1*g1 + g2*g2 + g3*g3 + g4*g4 + g5*g5
        \\        + g6*g6 + g7*g7 + g8*g8 + g9*g9 + g10*g10;
        \\    I(p, n) <+ acc;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try proof.prove(std.testing.allocator, &h.mir, &h.low, &h.bag);
    defer v.deinit(std.testing.allocator);
    var fatal = false;
    const a = h.arena_state.allocator();
    const off = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{})).text;
    const off0 = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .outline_chunk = 0 })).text;
    const on = (try generate(a, a, &h.mir, &h.low, v, &fatal, .{ .outline_chunk = 6 })).text;

    // Default IS off: measured 1.8-3x slower host eval, so a host opts in
    // per artifact (GPU kernels) rather than paying it everywhere.
    try std.testing.expectEqualStrings(off, off0);
    try std.testing.expect(std.mem.indexOf(u8, off, "__c0(") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "@call(.never_inline") == null);

    // Chunked shape: driver calls every chunk in order, threading the hoist
    // arrays; the value return stays in the driver; chunks are siblings so
    // `writeTree`'s `pub ` splice publishes only the driver.
    try std.testing.expect(std.mem.indexOf(u8, on, "fn oc__common__core__c0(comptime S: type, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "fn oc__common__core__c1(") != null);
    const n_chunks = std.mem.count(u8, on, "fn oc__common__core__c");
    try std.testing.expectEqual(n_chunks, std.mem.count(u8, on, "@call(.never_inline, oc__common__core__c"));
    try std.testing.expect(std.mem.indexOf(u8, on, "var h: [") != null);
    // Every chunk repeats the unit's float mode — @setFloatMode is per-fn.
    try std.testing.expect(std.mem.count(u8, on, "@setFloatMode(") >= n_chunks);
}

test "codegen: the unit ranges tile the emission and each names its own decl" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  parameter real c = 1e-12;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(p, n) <+ ddt(c * V(p, n));
        \\    V(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);

    // The merged core and the §4.5.11 `__sec` coefficient reader derived from
    // the laplace operator — every shape `emitUnits` can still produce for a
    // model with no §9.4 display unit.
    try std.testing.expectEqual(@as(usize, 2), o.names.len);
    for (o.names, o.unit_lo, o.unit_hi, 0..) |name, lo, hi, i| {
        // Tiling — `Output`'s invariant, and what lets the writer rebuild
        // device.zig as prologue ++ imports ++ tail with nothing dropped.
        if (i != 0) try std.testing.expectEqual(o.unit_hi[i - 1], lo);
        const decl = try std.fmt.allocPrint(std.testing.allocator, "fn {s}(", .{name});
        defer std.testing.allocator.free(decl);
        // The range holds the declaration it is named for, and `unit_fn` points
        // at that declaration's keyword — where the writer splices `pub `,
        // without which `@import("u/<key>.zig").<key>` does not resolve.
        try std.testing.expect(std.mem.indexOf(u8, o.text[lo..hi], decl) != null);
        try std.testing.expect(lo <= o.unit_fn[i] and o.unit_fn[i] < hi);
        const at = o.text[o.unit_fn[i]..];
        // `inline` included: splicing `pub ` in front of it gives
        // `pub inline fn`, which is what the merged core is emitted as.
        try std.testing.expect(std.mem.startsWith(u8, at, decl) or
            std.mem.startsWith(u8, at, "pub fn ") or
            std.mem.startsWith(u8, at, "inline fn "));
    }
    // The tail after the last unit is the dispatcher, not more units.
    try std.testing.expect(std.mem.indexOf(u8, o.text[o.unit_hi[o.unit_hi.len - 1]..], "pub fn eval(") != null);
    // The prologue before the first unit carries the types a unit file aliases.
    try std.testing.expect(std.mem.indexOf(u8, o.text[0..o.unit_lo[0]], "pub const Model = struct {") != null);
}

test "codegen: the unit prologue aliases the helper API and not its internals" {
    // "Every emitted helper is aliased" is now true by construction — `aliasesOf`
    // reads the same text `publish` does — so the test that policed it is gone.
    // What is NOT tautological is the `z` + uppercase clause: it is the only
    // thing standing between the prologue and a kernel file's private names, and
    // relaxing it changes the emitted bytes of every unit file. Pin both sides.
    const has = std.mem.indexOf;
    try std.testing.expect(has(u8, prelude_str_txt, "const zScan = h.zScan;\n") != null);
    try std.testing.expect(has(u8, prelude_file_txt, "const zFOpen = h.zFOpen;\n") != null);
    // str_kernels.zig's `pub const ZScan` and `const zstd`, file_kernels.zig's
    // `fn zfIo` and `const zf_max`: public in h.zig, never named by an emitted
    // body, so aliasing them would be legal, unreferenced, and pure noise.
    try std.testing.expect(has(u8, prelude_str_txt, "ZScan") == null);
    try std.testing.expect(has(u8, prelude_str_txt, "zstd") == null);
    try std.testing.expect(has(u8, prelude_file_txt, "zfIo") == null);
    try std.testing.expect(has(u8, prelude_file_txt, "zf_max") == null);
}

test "codegen: identical MIR yields a byte-identical file (determinism)" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h2);
    defer h2.deinit();
    try std.testing.expectEqualStrings(try h1.gen(std.testing.allocator), try h2.gen(std.testing.allocator));
}

test "codegen: adding a contribution appends to the core, it does not renumber" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n, m;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(m, n) <+ V(m, n) / r;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();

    const a = try h1.gen(std.testing.allocator);
    const b2 = try h2.gen(std.testing.allocator);
    // The first contribution is still `f0` and `eval` still stamps it from
    // `m.f0`. That is what `planCommon`'s job-order numbering buys: the field
    // index of an existing target is insert-tolerant in the same sense
    // naming.zig makes a declaration name insert-tolerant, so `zig`'s
    // `TrackedInst` for the dispatcher does not churn on an unrelated edit.
    try std.testing.expect(std.mem.indexOf(u8, a, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "const c = m.f0;") != null);
    const ka = a[std.mem.indexOf(u8, a, "pub fn eval(").?..];
    const kb = b2[std.mem.indexOf(u8, b2, "pub fn eval(").?..];
    const na = std.mem.indexOf(u8, ka, "    }\n").? + 6;
    const nb = std.mem.indexOf(u8, kb, "    }\n").? + 6;
    try std.testing.expectEqualStrings(ka[0..na], kb[0..nb]);
}

test "codegen: §5.6.1.2 reactive split emits q(), §4.2.12 select stays lazy" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(comptime S: type") != null);
    // The reactive half is a SECOND field of the same core, reached by `q` —
    // the split survives the merge as two targets, not two declarations.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn cap__common__core(") != null);
    // §4.2.3/§4.2.12 laziness (proof.zig's CODEGEN OBLIGATION): the `ln` must
    // sit INSIDE the arm, never in a preceding `const`. Matching a bare `if (`
    // is deliberate — `?:` lowers to a CFG diamond (`lowerTernary`) and a
    // `select` renders as the expression `(if (c) a else b)`, and BOTH satisfy
    // the obligation. What must never happen is `.log()` ahead of the guard.
    const unit = src[std.mem.indexOf(u8, src, "fn cap__common__core(").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    const guard = std.mem.indexOf(u8, body, "if (").?;
    const lg = std.mem.indexOf(u8, body, ".log()").?;
    try std.testing.expect(lg > guard);
}

test "codegen: evalQ fuses both residuals onto ONE core call" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) / r;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // `eval` and `q` survive untouched — the fusion is additive.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(comptime S: type") != null);
    const at = std.mem.indexOf(u8, src, "pub fn evalQ(comptime S: type").?;
    const fused = src[at..][0..std.mem.indexOf(u8, src[at..], "\n}\n").?];

    // The whole point: ONE core call for both halves. Two would make `evalQ`
    // exactly the `eval` + `q` it exists to replace.
    try std.testing.expect(std.mem.count(u8, fused, "core(S, x, model, inst)") == 1);
    // ...and it is hoisted ABOVE both blocks, not opened inside one of them.
    try std.testing.expect(std.mem.indexOf(u8, fused, "core(S, x, model, inst)").? <
        std.mem.indexOf(u8, fused, "blk:").?);
    try std.testing.expect(std.mem.indexOf(u8, fused, "struct { res: [n_u]S, q: [n_u]S }") != null);
    try std.testing.expect(std.mem.indexOf(u8, fused, "return .{ .res = rr, .q = qq };") != null);
    // Both halves stamp; a fused function with an empty half is the bug where
    // `emitStamps` wrote into the wrong block.
    try std.testing.expect(std.mem.count(u8, fused, "var   res = [_]S{S.con(0.0)} ** n_u;") == 2);
}

test "codegen: a device with no reactive half gets no evalQ" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1e3 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Pairs with `q`: the contract rejects `evalQ` without one, so codegen
    // must not emit a fused entry point there is nothing to fuse.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn evalQ(") == null);
}

test "codegen: §5.8 control flow reconstructs into structured Zig" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real ron = 1.0 from (0:inf);
        \\  parameter real roff = 1e9 from (0:inf);
        \\  analog begin
        \\    real g;
        \\    g = 0.0;
        \\    if (V(p, n) > 0.5) g = 1.0 / ron; else g = 1.0 / roff;
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "break :B") != null);
}

test "codegen: if-converted diamond emits an eager mask select in a strict unit" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module mix(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real g;
        \\    if (V(p, n) > 0.5) g = 2.0 * V(p, n); else g = 0.5 * V(p, n);
        \\    I(p, n) <+ g * exp(V(p, n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // root.zig runs this between lower and prove; the harness does the same.
    // The MIR is arena-owned, so the pass must append with the same arena.
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    try std.testing.expect(n >= 1);
    const src = try h.gen(std.testing.allocator);
    // exp(unbounded V) forfeits finiteness, so the unit is .strict — the
    // eager-sel license. Arms are plain arithmetic: mask form, no branch.
    try std.testing.expect(std.mem.indexOf(u8, src, ".sel(") != null);
    // Lane-true mask: `V > 0.5` renders in S space as the swapped `lt`, not
    // as a `.val()` i64 round-trip.
    try std.testing.expect(std.mem.indexOf(u8, src, ".lt(") != null);
    // The diamond is gone: nothing left for the relooper to label.
    try std.testing.expect(std.mem.indexOf(u8, src, "break :B") == null);
}

test "codegen: a domain-guarded arm stays lazy through if-conversion" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lg(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\endmodule
    , &h);
    defer h.deinit();
    _ = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    const src = try h.gen(std.testing.allocator);
    // domainOf(ln) != .all blocks the eager path: the select must render as
    // the lazy `(if (...))` with `.log()` inside the guarded arm, and the
    // proof must still accept the model (markSelectArms re-derives the guard).
    // Scoped to the unit body — the emitted math prelude also spells `.log()`.
    const unit = src[std.mem.indexOf(u8, src, "fn lg__").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    const guard = std.mem.indexOf(u8, body, "(if (").?;
    const lg2 = std.mem.indexOf(u8, body, ".log()").?;
    try std.testing.expect(lg2 > guard);
    try std.testing.expect(std.mem.indexOf(u8, body, ".sel(") == null);
}

test "codegen: a multi-use domain op under a guard keeps its CFG diamond" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ml(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real y;
        \\    y = 0.0;
        \\    if (V(p, n) > 0.0) begin
        \\      real t;
        \\      t = ln(V(p, n));
        \\      y = t + 2.0 * t; // t shared: markSelectArms could not guard it
        \\    end
        \\    I(p, n) <+ y * 1.0e-3;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // The guard's evidence only survives conversion on exclusively-owned
    // slices; a shared `ln` result must refuse, or the model silently drops
    // to `.strict` (and an integer `/` in the same shape turns REJECTED).
    const n = try ifconv.run(h.arena_state.allocator(), &h.mir, h.low.contributions.items);
    try std.testing.expectEqual(@as(u32, 0), n);
    // Still compiles and proves through the CFG dominance path.
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, ".log()") != null);
}

test "codegen: a §5.6 potential contribution gets its own branch-current unknown" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module vs(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real dc = 1.0;
        \\  analog V(p, n) <+ dc;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // lowering only allocates `flow(a,b)` where the model PROBES I(a,b), so
    // codegen appends the unknown AFTER node_order — existing indices hold.
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const u_kinds") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
}

test "codegen: §4.6.4 two noise sources on one branch export TWO generators" {
    var h: Harness = undefined;
    // The clause's own shape: "multiple noise contributions to a single branch
    // are combined". `combined/13_noise_temperature_analysis.va` writes exactly
    // this, and a single-valued tag made the flicker statement overwrite the
    // thermal one — deleting from `noise_gens` the ONE generator the documented
    // Jacobian-derived fallback can actually compute.
    try Harness.run(std.testing.allocator,
        \\module rnoise(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1000.0;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / rs;
        \\    I(p, n) <+ white_noise(1.6e-23 / rs, "thermal");
        \\    I(p, n) <+ flicker_noise(1e-20, 1.0, "flicker");
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // §4.6.4.6 each CALL is one generator, so the two rows carry distinct
    // dense `source` ids — two independent sources, not one shared.
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .thermal, .source = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".kind = .flicker, .source = 1 }") != null);
    // §4.6.4.1 before §4.6.4.2 — the sources append in statement order, so the
    // table is stable across builds and a host may index it positionally.
    try std.testing.expect(
        std.mem.indexOf(u8, src, ".kind = .thermal").? <
            std.mem.indexOf(u8, src, ".kind = .flicker").?,
    );
}

test "codegen: §4.6.4 noisePsd is the model's own PSD, and a guarded one reads zero" {
    var h: Harness = undefined;
    // The shape EVERY series resistance in a real model card writes: the
    // generator lives inside `if (r > 0)`, and its power divides by that very
    // `r`. Hoisting `4kT/r` to `precompute` evaluates it at r == 0 — an
    // infinity that becomes a NaN the instant the collapsed branch gives it a
    // zero adjoint gain. It has to stay a core live-out, which `probeBody`
    // seeds `S.con(0.0)` and only the taken branch assigns.
    try Harness.run(std.testing.allocator,
        \\module rn(p, n, m);
        \\  inout p, n, m;
        \\  electrical p, n, m;
        \\  parameter real rs = 0.0;
        \\  parameter real ich = 1e-3;
        \\  analog begin
        \\    I(p, n) <+ white_noise(2.0 * 1.602176634e-19 * abs(ich), "shot");
        \\    if (rs > 0.0) begin
        \\      I(n, m) <+ V(n, m) / rs;
        \\      I(n, m) <+ white_noise(1.6e-23 / rs, "rs");
        \\    end else begin
        \\      V(n, m) <+ 0.0;
        \\    end
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The hook exists and is positional against `noise_gens`.
    const at = std.mem.indexOf(u8, src, "pub fn noisePsd(").?;
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const noise_gens").? < at);
    // Both powers come out of the core, NOT off a Jacobian and NOT inline:
    // §4.6.4.1 states the density as the call's argument, so the shot row is
    // `2q|I|` and the thermal row is `4kT/rs` — the same call, different
    // arguments, and only the model knows which.
    const body = src[at..];
    const ret = std.mem.indexOf(u8, body, "return .{").?;
    try std.testing.expect(std.mem.indexOf(u8, body[0..ret], "core(R, xr, model, inst)") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body[ret .. ret + 120], ".white = m.f"));
    // The guarded power is a live-out seeded zero, never an `inst.pc__` read:
    // a precompute field would have divided by rs == 0 unconditionally.
    var k: usize = ret;
    while (std.mem.indexOfPos(u8, body, k, ".white = m.f")) |i| {
        const f = body[i + ".white = m.f".len ..];
        const end = std.mem.indexOfScalar(u8, f, '.').?;
        const decl = try std.fmt.allocPrint(std.testing.allocator, "    .f{s} = h[", .{f[0..end]});
        defer std.testing.allocator.free(decl);
        try std.testing.expect(std.mem.indexOf(u8, src, decl) != null);
        k = i + 1;
        if (k > ret + 120) break;
    }
}

test "codegen: §5.6.7 indirect contribution is a nullor row, ASYMMETRIC-safe" {
    var h: Harness = undefined;
    // Deliberately asymmetric: probe − equation = V(pin,nin) − 2*V(out).
    // The mirrored row (equation − probe) is invisible on the textbook opamp
    // (`V(pin,nin) == 0`), so the fixture that pins the sign has to be one
    // whose two sides differ.
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog V(out) : V(pin, nin) == 2.0 * V(out);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The source current is a solver unknown; the KCL stamps are its only
    // occurrence outside its own row (a nullor).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28outZ2cgndZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "res[@intFromEnum(U.flowZ28outZ2cgndZ29)] = c;\n") != null);
    // ... and NOT the direct-contribution row `V(hi,lo) − c`.
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") == null);

    // THE trap: the row must be a function of `x`, or the host's dual-number
    // Jacobian has a zero column and Newton can never move the source.
    const key = "fn amp__common__core(comptime S: type, x: [n_u]S";
    try std.testing.expect(std.mem.indexOf(u8, src, key) != null);
    const unit = src[std.mem.indexOf(u8, src, key).?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    // probe − equation, in that order.
    const probe_at = std.mem.indexOf(u8, body, "U.pin").?;
    // `2.0 * V(out)` reaches the constant through `scale`, not through a
    // second dual — the derivative-free side of a product never becomes an S.
    const eqn_at = std.mem.indexOf(u8, body, "scale(2.0)").?;
    try std.testing.expect(std.mem.indexOf(u8, body, ".sub(") != null);
    try std.testing.expect(probe_at < eqn_at);
}

test "codegen: §5.6.7.1 two indirect contributions to one branch get one source each" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n, c1, c2);
        \\  inout p, n, c1, c2;
        \\  electrical p, n, c1, c2;
        \\  analog begin
        \\    V(p, n) : V(c1) == V(p, n);
        \\    V(p, n) : V(c2) == 2.0 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Two sources ⇒ two currents ⇒ two DISTINCT U members (a shared name would
    // be a duplicate enum field, which the Zig parser cannot catch).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29Z231, // branch flow") != null);
    // Two targets ⇒ two distinct core fields ⇒ two rows in `eval`. (The
    // group-local ordinal naming.zig gives the second unit is still what keys
    // its §4.5 state and proof.zig's verdict; it just no longer names a decl.)
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f1;") != null);
}

test "codegen: §5.10.5 only a `timer` module gets a nextBreakpoint hook" {
    // The hook is OPTIONAL in tools/contract.zig, and emitting it
    // for a module with no timer would claim a schedule that does not exist —
    // the host reads "no breakpoints ever" and stops asking. `transition` is the
    // trap case: it is stateful and discontinuity-adjacent, but nothing about it
    // says WHERE a timepoint goes, only how fast the value moves.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §5.10.5 a timer whose start is a solved quantity emits NO hook" {
    // `nextBreakpoint` gets `*const Model` and no `Instance`, so the schedule
    // has to be a function of the parameters. A start_time read off the solution
    // is not, and there is no honest answer to give — a guessed one either hangs
    // the transient walk (an answer at or before `t`) or moves an edge. Silence
    // degrades to LTE step control, which is where every device is today.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fired;
        \\  analog begin
        \\    @(timer(V(p, n), 1e-9)) fired = fired + 1;
        \\    I(p, n) <+ fired;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "__next") != null); // the timer IS compiled
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §4.5 operator state is keyed to the stable unit id" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real td = 1e-9 from (0:inf);
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, td, td);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr__analog_op__transition__from: f64 = 0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr__analog_op__transition__t0: f64 = 0.0") != null);
    // The operator's INPUT is a core field now, not a declaration of its own —
    // but the state field, and therefore `naming.zig`'s key, is untouched.
    try std.testing.expect(std.mem.indexOf(u8, src, "zTransition(S, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = core(R, xr, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const State = struct {") != null);
}

test "codegen: §4.5.11 laplace_nd emits a real filter, not a compile error" {
    // Was: asserted laplace was a LOUD @compileError. It is now implemented,
    // so the assertion is inverted — a stateful filter unit must be emitted.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lp(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "laplace_nd") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    // The cascade's `__sec(model)` call is the ONLY Model read in this module,
    // so the unit's parameter must stay NAMED. Was patched to `_`, which made
    // every filter-in-a-contribution device fail to compile on `model`.
    try std.testing.expect(std.mem.indexOf(u8, src, "__sec(model)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "core(comptime S: type, x: [n_u]S, model: *const Model") != null);
}

test "codegen: a non-const analog-operator control argument is a LOUD compile error" {
    // The invariant the previous test really guarded: unsupported constructs
    // must be loud, never a silent substitute value (a silent 0 corrupts the
    // device residual). §4.5.14 requires control arguments to be constant.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, V(p, n), 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") != null);
}

test "codegen: §5.4.3 I(<p>) is a solver unknown pinned to the KCL sum at p" {
    var h: Harness = undefined;
    // §5.4.3's own diode example shape: the probed port also carries a `ddt`
    // contribution, so a DC-only port current would be silently wrong in tran.
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real cj = 1e-12;
        \\  real m;
        \\  analog begin
        \\    I(a, c) <+ 1e-3 * V(a, c) + ddt(cj * V(a, c));
        \\    m = I(<a>);
        \\    I(a, c) <+ 1e-9 * m;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Its own unknown, appended after the ports so `num_ports` is untouched,
    // and classified a CURRENT by the existing `flow(` predicate.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3caZ3eZ29, // branch flow") != null);

    // SIGN: `I(p,n) <+ c` stamps `+c` at hi, so res[a] is the current leaving
    // node a INTO the module — which is exactly §5.4.3's "flow into a port".
    // Hence `x − res[a]`, not `x + res[a]`.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(res[@intFromEnum(U.a)]);",
    ) != null);
    // THE REACTIVE HALF: q() carries `−q_a` on the same row, so the total
    // residual is x − (I_dc + d/dt q_a).
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = res[@intFromEnum(U.a)].neg();",
    ) != null);
    // The row is emitted AFTER the contribution stamps it reads.
    const stamp_at = std.mem.indexOf(u8, src, "res[@intFromEnum(U.a)].add(c)").?;
    const row_at = std.mem.indexOf(u8, src, "= x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(").?;
    try std.testing.expect(stamp_at < row_at);
}

test "codegen: a port whose only branch goes to ground still gets its unknown" {
    var h: Harness = undefined;
    // The self-referential form: I(p) <+ I(<p>) + V(p). Nothing else drives p.
    try Harness.run(std.testing.allocator,
        \\module g(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ I(<p>) + V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3cpZ3eZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3cpZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3cpZ3eZ29)].sub(res[@intFromEnum(U.p)]);",
    ) != null);
    // No reactive part anywhere ⇒ no q() at all, so no port row is missing.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
}

test "codegen: the `U` block is the SPELLING contract — all four name kinds, verbatim" {
    var h: Harness = undefined;
    // `node_voltages` is one string key space over four different kinds of name,
    // and only one of them has a source spelling. The KEY is lowering's private
    // business, but the spelling is not: it reaches the user three times over —
    // as an emitted `U` member (here), as the identifier a `//! bias`/`//! sweep`
    // line has to write (tb.zig's `unknownName`, pinned in its own test), and as
    // the name every diagnostic over an unknown prints. So it is pinned as the
    // whole block, byte for byte, and not one `indexOf` per kind: an insertion,
    // a reorder or a re-escape is a change to the host's ABI and to every
    // fixture that biases an unknown, and each of those is invisible to a
    // substring search.
    //
    // Ports first, then §3.6.3 internal nets, then §5.4.2/§5.4.3 flows — the
    // order `emitTopology` documents, which is also `num_ports`' meaning.
    // `naming.sanitize` is what makes `b[0]` and `flow(p,n)` legal Zig, and
    // `isValidId` leaves `p` and `n` alone.
    try Harness.run(std.testing.allocator,
        \\module m(p, b);
        \\  inout p;
        \\  inout [0:1] b;
        \\  electrical p, n;
        \\  electrical [0:1] b;
        \\  real x;
        \\  analog begin
        \\    x = I(p, n);
        \\    I(p, n) <+ x + I(<p>);
        \\    I(b[0], b[1]) <+ V(b[0], b[1]);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src,
        \\pub const U = enum(u8) {
        \\    p, // port
        \\    bZ5b0Z5d, // port
        \\    bZ5b1Z5d, // port
        \\    n, // internal
        \\    flowZ28pZ2cnZ29, // branch flow
        \\    flowZ28Z3cpZ3eZ29, // branch flow
        \\};
    ) != null);
}

test "codegen: §5.9 a loop the unit re-runs is not read out of the shared core" {
    var h: Harness = undefined;
    // Two units both slice the loop, so `planCommon` wants to hoist it — but
    // each also has private values inside it, so each re-materializes the loop.
    // Reading the hoisted counter and exit condition there is reading their
    // FINAL values, and the re-materialized loop then runs zero times.
    try Harness.run(std.testing.allocator,
        \\module l(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i;
        \\  real a, b;
        \\  analog begin
        \\    a = 0.0;
        \\    b = 0.0;
        \\    for (i = 1; i <= 5; i = i + 1) begin
        \\      a = a + i;
        \\      b = b + i * 2;
        \\    end
        \\    I(p, n) <+ a * V(p, n);
        \\    I(p) <+ b * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // `genDisplay`, not `gen`: since the merge the RESIDUAL cannot hit this bug
    // at all — there is one body, the loop is emitted where its values are
    // computed, and there is no cache holding a loop-carried value at its exit
    // state. §9.4 `display` is the one declaration that still opens with
    // `const c = core(...)`, so it is the only remaining consumer of the §5.9
    // `loop_recompute` fixpoint and therefore the only place this can regress.
    const src = try h.genDisplay(std.testing.allocator);
    // A body holding `while (true)` while reading `c.f<N>` inside it is the bug.
    var rest = src;
    while (std.mem.indexOf(u8, rest, "L")) |_| {
        const at = std.mem.indexOf(u8, rest, ": while (true)") orelse break;
        const end = std.mem.indexOfPos(u8, rest, at, "\n    }") orelse rest.len;
        try std.testing.expect(std.mem.indexOf(u8, rest[at..end], "c.f") == null);
        rest = rest[end..];
    }
    // The residual half of the guarantee, stated structurally: the merged core
    // reads no cache, so a `c.f` cannot appear in it anywhere, in or out of a
    // loop. This is what makes the hazard impossible rather than merely absent.
    const core_at = std.mem.indexOf(u8, src, "fn l__common__core(").?;
    const core_end = std.mem.indexOfPos(u8, src, core_at, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, src[core_at..core_end], "c.f") == null);
}

test "codegen: §9.4 display tasks are void by default and print on request" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 2.0;
        \\  analog begin
        \\    $strobe("g=%g n=%5d s=%s", g, 42, "x");
        \\    $write("no newline");
        \\    $error("bad");
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // A DEVICE never prints: no sink, nothing that blocks a GPU backend.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, "std.debug.print") == null);
    try std.testing.expect(std.mem.indexOf(u8, dev, "pub fn display(") == null);

    // The EXECUTABLE does, with §9.4.3 conversions translated and the operands
    // sliced in (a missing slice renders every one of them as `S.con(0.0)`).
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, exe, "pub fn display(") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, "g={d} n={s:>5} s={s}\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, "(S.con(model.g)).val()") != null);
    // §9.4.1 `$write` is the one that does not end the line.
    try std.testing.expect(std.mem.indexOf(u8, exe, "\"no newline\"") != null);
    // §9.7.3 the severity is a prefix, not something a reader must infer.
    try std.testing.expect(std.mem.indexOf(u8, exe, "ERROR: bad") != null);
}

test "codegen: §9.5 a descriptor is an i64 in the DEVICE too, not only in the executable" {
    // THE BUG THIS PINS. `emitSysCall`'s §9.5 branch used to be gated on
    // `display == .emit`, so in a device the eight descriptor-RETURNING names
    // fell through to `void_tasks`' blanket `S.con(0.0)` — while
    // `Analysis.callTy` types every one of them `.int` and therefore declared
    // the slot `i64`. The emitted line was `const t0: i64 = S.con(0.0);`,
    // `--emit-zig` exited 0, and the failure landed in the HOST's build as
    // `expected type 'i64', found 'Dual'` against generated Zig in a cache
    // directory. `emitFileCallDropped` already switched on `callTy`; the gate
    // was all that kept it from running.
    //
    // `fd` FEEDS THE RESIDUAL on purpose. A descriptor whose value nothing reads
    // gets no slot, so the wrong type would be merely absent instead of wrong —
    // which is why this is the one shape that observes it.
    //
    // THE SUITE CANNOT GRADE THIS. `tests/torture.zig` compiles every fixture
    // with `.display = .emit` (there is no `//!` directive for the mode), so a
    // `.va` cannot reach the `.drop` path at all. This test is the grader.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module fdev(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fd;
        \\  analog begin
        \\    fd = $fopen("nope.txt");
        \\    I(p, n) <+ V(p, n) * (fd + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // §9.5.1 "a zero is returned for the mcd or fd" — as an INTEGER. A device has
    // no host file table, so zero is the answer and not a stub.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, ": i64 = @as(i64, 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, dev, ": i64 = S.con(") == null);
    // No kernel came with it: `buildPrelude` gates the descriptor table on
    // `display == .emit`, and a call to `zFOpen` here would not resolve.
    try std.testing.expect(std.mem.indexOf(u8, dev, "zFOpen") == null);

    // The printing artifact is unchanged — it still opens the file for real.
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, exe, "zFOpen") != null);
}

test "codegen: §9.4 a display unit that reads an operator input opens the cache" {
    // The display unit is the ONE unit not folded into the core, and an
    // operator's input is not a `mark`ed operand — so a `c.f*` rendered for it
    // used to arrive with no `const c = core(...)` above it and the printing
    // artifact did not compile. Same shape for ddt/transition/slew/laplace.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dop(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    $strobe("y=%g", transition(V(p, n), 0.0, 1n, 1n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.indexOf(u8, exe, "zTransition(S, c.f").?;
    const open = std.mem.lastIndexOf(u8, exe[0..at], "const c = core(S, x, model, inst);");
    const head = std.mem.lastIndexOf(u8, exe[0..at], "\nfn ") orelse 0;
    try std.testing.expect(open != null and open.? > head);
}

test "codegen: §2.6.1 an integer literal keeps all 64 bits" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module big(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer k;
        \\  analog begin
        \\    k = 4607182418800017408;
        \\    I(p, n) <+ V(p, n) * k;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // The integer side of the product carries no derivative, so it folds and
    // arrives as the f64 the multiply needs. `fmtF64` is `{d}`, which is the
    // shortest representation that ROUND-TRIPS — 4607182418800017400.0 parses
    // back to exactly 4607182418800017408, and every literal in every emitted
    // device already rests on that. What must not happen is the value changing.
    try std.testing.expect(std.mem.indexOf(u8, src, "scale(4607182418800017400.0)") != null);
    try std.testing.expectEqual(
        @as(f64, 4607182418800017408),
        try std.fmt.parseFloat(f64, "4607182418800017400.0"),
    );
    // `0.0 * k` would fold the contribution away entirely, which is why the
    // multiplicand here is a probe: the literal has to reach the device.
}

test "codegen: §3.2 the three sites that impose the 32-bit integer width agree" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer big = 2147483647 + 1;
        \\  parameter integer chained = big + 1;
        \\  localparam integer sh = 1 << 31;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) * (big + 1);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Site 1, `Lower.foldBinary`: a §4.2 constant expression, folded before the
    // Model field is written. 2^31 is one step past the top of §3.2's range.
    try std.testing.expect(std.mem.indexOf(u8, src, "big: i64 = -2147483648") != null);
    // §4.2.11 `<<` at the same width — `1 << 31` is the sign bit, not 2^31.
    try std.testing.expect(std.mem.indexOf(u8, src, "sh: i64 = -2147483648") != null);
    // Site 2, `analysis.foldConst`: a §6.3.4 default over another parameter,
    // folded for the field initializer and re-emitted in `derive` for the
    // overridden case. -2^31 + 1, so the two folds have to agree on -2^31 first.
    try std.testing.expect(std.mem.indexOf(u8, src, "chained: i64 = -2147483647") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "model.chained = @as(i32, @truncate(") != null);
    // Site 3, `codegen.intBin32`: the device. `+%` is the 64-bit wrap that keeps
    // the add from panicking; the truncation is §3.2's width. The left operand
    // is a PARAMETER, so neither fold can reach it and the wrap has to survive
    // as emitted code — which is the site this half of the test is about.
    try std.testing.expect(std.mem.indexOf(u8, src, "@as(i32, @truncate(((model.big) +% (@as(i64, 1)))))") != null);
}

test "codegen: a unit whose target is defined in one arm returns a VALUE, not undefined" {
    var h: Harness = undefined;
    // §4.5 the operator's input unit is sliced from the argument, which here is
    // only defined on the taken arm. Returning `undefined` from the other one is
    // undefined behavior in the device AND silently corrupts the operator's
    // history, because `updateState` pushes whatever comes back.
    // The condition is a §3.4 PARAMETER, which §5.8.1 licenses (a `constant_
    // primary` cannot move mid-analysis, so the operator never misses a step)
    // while `elabConst` still refuses to fold it away — a model card overrides
    // it. So the diamond is real and the operator is legal, which is exactly the
    // shape this test needs. A probe condition here would now be E0514.
    try Harness.run(std.testing.allocator,
        \\module g(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  parameter real en = 1.0;
        \\  analog begin
        \\    if (en > 0.5)
        \\      I(p, n) <+ transition(V(p, n), 0, 1n, 1n);
        \\    else
        \\      I(p, n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.indexOf(u8, src, "fn g__common__core(").?;
    // `"\n}\n"`, not `"\n}"`: the core's return type is an anonymous struct
    // written into the signature, and it closes with `\n} {`.
    const end = std.mem.indexOfPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    // Hoisted slots share one `var h: [n]S`, so the carve-out is no longer a
    // property of each declaration — the array itself is declared `undefined`.
    // It is now the pair of facts below: the array is EXACTLY as long as the
    // number of zero-seeds, so no element of it can reach the `return`
    // unwritten. Assert both or the guarantee is not being tested.
    //
    // Targeted, not a blanket memset: the only hoists are the two returned
    // fields (the operator input, defined on one arm only, and the contribution
    // phi). Every other slot is a `const` at its definition, which is what
    // `probeBody` is for — so counting the hoists is counting exactly the values
    // that could reach the `return` without being written.
    try std.testing.expect(std.mem.indexOf(u8, body, "    var h: [2]S = undefined;") != null);
    var hoists: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    h[")) continue;
        hoists += 1;
        try std.testing.expect(std.mem.endsWith(u8, line, "= S.con(0.0);"));
    }
    try std.testing.expectEqual(@as(usize, 2), hoists);
}

test "codegen: §4.5.8/§4.5.9 an omitted rate argument copies the one that was given" {
    // §4.5.8: "If only a positive rise_time value is specified, the simulator
    // uses it for both rise and fall times." §4.5.9: max_neg_slew_rate "defaults
    // to the opposite of the max_pos_slew_rate."
    //
    // Both used to default to a NEUTRAL element instead of to the value that WAS
    // given — `fall = 0.0` and `max_neg = 1e300` — so the short spelling of each
    // operator behaved differently from the long spelling written with the same
    // number: the 3-argument `transition` transitioned twice as fast, and `slew`
    // held the rising edge while letting the falling edge through unlimited.
    //
    // Asserted on the emitted call rather than by diffing the two spellings,
    // because `slew(x, 2e8, -2e8)` renders `@abs(-2e8)` and the short form
    // renders `@abs(2e8)` — the same limit, different text.
    const cases = [_]struct { call: []const u8, want: []const u8 }{
        .{
            // §4.5.8 now passes rise and fall SEPARATELY (the averaged lag
            // constant is gone), so the copy shows up as the same number twice
            // in the last two argument positions of the call.
            //
            // `0.0000000022` and not `0.0000000022000000000000003`: this is the
            // tree's only pin on the §2.6.2 scale-factor decode, and the rule in
            // force is that `2.2n` is ONE `parseFloat` of the joined text
            // `2.2e-9`, not `2.2 * 1e-9`. The two differ by 1 ulp. Asserted as a
            // rule, with its LRM argument, in lexer.zig's "§2.6.2 a scale factor
            // rounds ONCE" test; re-blessed here when the parser stopped
            // carrying a second decoder that double-rounded.
            .call = "transition(V(p, n), 0, 2.2n)",
            .want = "0.0000000022, 0.0000000022)",
        },
        .{
            .call = "slew(V(p, n), 2e8)",
            .want = "inst.dt, 200000000.0, @abs(200000000.0))",
        },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ {s};
            \\endmodule
        , .{c.call});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);

        std.testing.expect(std.mem.indexOf(u8, out, c.want) != null) catch |e| {
            std.debug.print("{s}: expected to emit `{s}`\n", .{ c.call, c.want });
            return e;
        };
    }
}

test "codegen: §5.9.1 a short-circuit loop condition still reaches the loop's branch" {
    // §4.2.7 `&&` splits its expression across blocks, so after lowering the
    // condition of a `while` the CURRENT block is the short-circuit join, not
    // the loop header. `lowerWhile`/`lowerFor` used to emit the loop's own
    // branch into the header regardless: the header ended up with two
    // terminators, the `&&`'s rhs and join blocks lost their predecessor, and
    // codegen — which walks reachable blocks — declared slots for the values
    // defined in them and then never emitted a single assignment. The loop then
    // branched on an `undefined` local. Zig caught it as "unused local
    // variable" on `bsimsoi_va`; without that it is a read of undefined memory.
    //
    // Asserted structurally rather than on one temporary's name: EVERY declared
    // slot must be written somewhere in the body. That is the whole bug class,
    // and it does not move when slot numbering does.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real x, y; integer i;
        \\    x = 1e6; y = V(p, n); i = 0;
        \\    while ((i <= 4) && (abs(y - x) > 1e-12)) begin
        \\      x = y;
        \\      y = 2.0 * y + 1.0;
        \\      i = i + 1;
        \\    end
        \\    I(p, n) <+ y;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The rhs of the `&&` is emitted at all — it used to be dropped entirely.
    try std.testing.expect(std.mem.indexOf(u8, src, ".abs()") != null);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const decl = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, decl, "var t")) continue;
        const name = decl[4 .. std.mem.indexOfScalar(u8, decl, ':') orelse continue];
        var buf: [32]u8 = undefined;
        const store = try std.fmt.bufPrint(&buf, "{s} = ", .{name});
        std.testing.expect(std.mem.indexOf(u8, src, store) != null) catch |e| {
            std.debug.print("slot `{s}` is declared but never assigned\n", .{name});
            return e;
        };
    }
}

test "codegen: §4.5.7 a delay computed from parameters renders as an expression over `model`" {
    // `td = len * sqrt(l * c)` is how every transmission line in the wild
    // spells its delay (devices/models/lossy_tline.va:135,
    // coupled_tlines.va:110). It is not a literal and not a bare parameter, so
    // it used to hit the `else` of `f64Expr` and paste an `@compileError` INTO
    // an expression in the generated Zig — which the Zig compiler then reported
    // as "unreachable code" at a line of generated code, with nothing naming
    // the model.
    //
    // §4.5.7 permits it: `absdelay(input, td [, maxdelay])` takes td as an
    // analog_expression, and with no maxdelay "the value of td when the
    // absdelay() is first evaluated shall be used" — which for an expression
    // over parameters is its value at every evaluation.
    //
    // Also pins the ASSIGNMENT: `td` is a `real` variable, not a parameter, so
    // this only works because the walk runs on SSA values rather than on names.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tl(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real len = 1.0 from (0:inf);
        \\  parameter real l = 250e-9 from (0:inf);
        \\  parameter real c = 100e-12 from (0:inf);
        \\  real td;
        \\  analog begin
        \\    td = len * sqrt(l * c);
        \\    I(p, n) <+ absdelay(V(p, n), td);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "inst.dt, (model.len) * (@sqrt((model.l) * (model.c))))",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
}

test "codegen: §5.6.5 a zero-short switch branch emits a collapse hook" {
    // diode.va's access-resistance idiom: rs > 0 selects a real resistor,
    // rs == 0 a retained 0 V short that ngspice would collapse at setup
    // (DIOsetup: posPrimeNode = posNode).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  parameter real rs = 0.0 from [0:inf);
        \\  branch (a, ai) rsb;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (rs > 0.0) I(rsb) <+ V(rsb) / rs;
        \\    else          V(rsb) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "pub fn collapse(model: *const Model, inst: *const Instance) [n_u]?u8",
    ) != null);
    // The internal node AND the branch-flow unknown both alias onto the port,
    // so the pair's stamps land on one slot and cancel.
    //
    // Asserted through the UNION-FIND emission, which replaced the
    // last-write-wins `out[victim] = target` these rows used to match. That
    // rewrite was the FIX for chained shorts — BSIM4 rgateMod=0 retains both
    // V(g,gm) and V(gm,gi), sharing gm, and last-write-wins left the chain's
    // first link dangling (see `collapse`'s own doc comment). The old spelling
    // is gone, so matching it asserted the bug rather than the fix.
    //
    // `ai` is aliased by the union and then resolved by the `if (r != u)` loop
    // over every unknown, so it is no longer written by name; the branch-flow
    // row still is, because it is not a union member.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "zCollapseUnion(&parent, @intFromEnum(U.ai), @intFromEnum(U.a));",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "out[@intFromEnum(U.flowZ28aZ2caiZ29)] = zCollapseRoot(&parent, @intFromEnum(U.a));",
    ) != null);
    // Min-index root, so `a` — a port at index 0 — is the target and never a
    // mover. That ordering is what lets the host resolve aliases ascending.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (ra < rb) parent[rb] = ra else parent[ra] = rb;",
    ) != null);
}

test "codegen: no collapse hook without the zero-short pattern" {
    // An unconditional resistor has nothing to collapse.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse") == null);
}

test "codegen: an x-steered zero short is NOT collapsed" {
    // The guard reads a probe, so which arm is retained changes per
    // evaluation; a build-time alias would be a lie. `buildFree` refuses it.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c, ai;
        \\  analog begin
        \\    I(ai, c) <+ 1e-3 * V(ai, c);
        \\    if (V(a, c) > 1.0) I(a, ai) <+ 1e3 * V(a, ai);
        \\    else               V(a, ai) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn collapse") == null);
}

test "codegen: §4.5 a control argument that is a solve result is E0515, not generated Zig" {
    // The other half: a delay that genuinely cannot be resolved must be a
    // diagnostic at the `.va` line. An `@compileError` pasted into an
    // expression is not one — it reads as an engine bug in generated code.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  analog I(p, n) <+ absdelay(V(p, n), V(c));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .E0515) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        // The span is the `absdelay` call: a node probe has no instruction of
        // its own to point at, which is what `ctrl_tok` is the fallback for.
        try std.testing.expect(e.span.end > e.span.start);
    }
    try std.testing.expect(found);
    // Refused as a whole unit — an `@compileError` STATEMENT that replaces the
    // body, never one pasted into the middle of an expression (which is what
    // `inst.abstime - (@compileError(…))` was, and what Zig reported as
    // "unreachable code" at a line of generated code).
    try std.testing.expect(std.mem.indexOf(u8, src, "\n    @compileError(\"LRM 4.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "(@compileError") == null);
}

test "codegen: §12.32.3 an unregistered system function is W0852 and a host call, not a refusal" {
    // The other side of the test above, and the distinction the whole W0852
    // ruling rests on: an unregistered `$name` has no value the LRM fixes, so
    // the unit must still compile — but not silently. §12.32.3's own sampnhold
    // listing, which is what puts one of these in a contribution.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sampnhold(out, in);
        \\  inout out, in;
        \\  electrical out, in;
        \\  parameter real period = 1e-3;
        \\  analog V(out) <+ $sampler(V(in), period);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .W0852) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the call, not the file
    }
    try std.testing.expect(found);
    // Compiles. A refusal here would reject legal source (§2.8.3), which is the
    // regression this line exists to catch.
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);

    // §2.8.3/§12.32: the name is EXPORTED for a host to bind, not answered here.
    // The `0.0` this test used to require is gone deliberately — a substitute
    // value is what the seam replaced.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const systf_calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".{ .name = \"$sampler\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "inst.systf.?") != null);
}

test "codegen: a systf call reassembles the host's value and partials into one S" {
    // The shape §12.22.1 forces, and the reason it is forced: `eval` is generic
    // over S and a function POINTER cannot be, so the host returns a value and
    // writes partials and the call site rebuilds the dual. Each graft term is
    // `arg.addC(-arg.val()).scale(p)` — VALUE zero, DERIVATIVE p·d(arg) — so on
    // the plain-f64 instantiation the residual reads the host's value exactly
    // and on the dual one it also carries the host's slope.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module twice(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ $foo(V(p,n)) + $foo(V(p,n)) + $bar(V(p,n));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Deduplicated by NAME, because that is what §12.32 registers: two calls to
    // `$foo` are one table entry and one binding, and `$bar` is the second.
    const tbl = src[std.mem.indexOf(u8, src, "pub const systf_calls").?..];
    try std.testing.expect(std.mem.indexOf(u8, tbl, ".{ .name = \"$foo\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, tbl, ".{ .name = \"$bar\" }") != null);
    try std.testing.expect(std.mem.count(u8, tbl[0..std.mem.indexOf(u8, tbl, "};").?], ".name =") == 2);
    // …and the indices the call sites pass follow the table, not the call order.
    try std.testing.expect(std.mem.count(u8, src, "zsh.call(zsh.ctx, 0,") == 2);
    try std.testing.expect(std.mem.count(u8, src, "zsh.call(zsh.ctx, 1,") == 1);

    // The graft, spelled out. `.val()` feeds the host, `.addC(-...).scale(...)`
    // brings the partial back; dropping either half is the failure this pins.
    try std.testing.expect(std.mem.indexOf(u8, src, ".val() }") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".addC(-zsv[0]).scale(zsp[0])") != null);
}

test "codegen: §3.4 a default with no compile-time value is W1050, a derived one is silent" {
    // The guard on the `0` field initializer, and the line it must NOT cross.
    // `hot` reads §9.18's simulator table, which has no value until the host
    // runs — nothing folds it and nothing derives it, so `Model{}.hot` ships as
    // 0 and the host has to write the field. `warm` is 2*`base`, which §6.3.4
    // makes a `derive()` line; the same `0` initializer is honest there because
    // `derive` overwrites it, so warning about it would be noise on every
    // dependent parameter in the suite.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module pd(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real base = 3.0;
        \\  parameter real warm = 2.0 * base;
        \\  parameter real hot  = $simparam("gmin", 1e-12);
        \\  analog I(p, n) <+ V(p, n) * (warm + hot);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var hits: usize = 0;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .W1050) continue;
        hits += 1;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        try std.testing.expect(e.span.end > e.span.start); // the declaration
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
    // A warning, never a refusal: the device still compiles, because §9.18 says
    // nothing that makes this source illegal.
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
    // And `warm` is the derived half of the claim: initializer 0.0, `derive`
    // writing the §6.3.4 value over it.
    try std.testing.expect(std.mem.indexOf(u8, src, "model.warm = (2.0) * (model.base);") != null);
}

test "codegen: §9.15 $simparam(\"tnom\") is the HOST's nominal temperature" {
    // The defect this fixes: `tnom` folded to the constant 27, so a SPICE deck
    // setting `.options tnom` was silently ignored by every model — and a
    // compact model derives its whole parameter set from the nominal
    // temperature, so 2 K of error moves the I-V curve by percent.
    //
    // ngspice's shape, per model setup (b4set.c:1950): `if (!tnomGiven) tnom =
    // CKTnomTemp`. Here that is the `__given` guard `emitDerive` already writes
    // for every derived parameter, over a Model field the host writes once.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tn(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real tnom  = $simparam("tnom");
        \\  parameter real tnomk = $simparam("tnom") + 273.15;
        \\  analog I(p, n) <+ V(p, n) * (tnom + tnomk);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // ONE host-written field, on Model — `.options tnom` is one number per RUN,
    // so an Instance copy would replicate a global per instance, and two reads
    // of the same simparam must not become two fields.
    try std.testing.expect(std.mem.count(u8, src, "nom_temp__: f64 = 27.0,") == 1);

    // Table 9-27's declared default still IS the field initializer, in Celsius,
    // so `Model{}` — a host that writes nothing — is bit-identical to the old
    // folded constant. That is what keeps every existing fixture unmoved, and
    // `tnomk` pins that `27.0 + 273.15` folds to the literal `300.15` exactly.
    try std.testing.expect(std.mem.indexOf(u8, src, "tnom: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tnomk: f64 = 300.15,") != null);

    // Precedence: the card wins. `__given` is the same flag §9.19 uses, raised
    // by the host's `applyKv` when the model card named the parameter.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!model.tnom__given) model.tnom = model.nom_temp__;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!model.tnomk__given) model.tnomk = (model.nom_temp__) + (273.15);") != null);

    // A default that reads the host's table is no longer W1050: `derive()`
    // overwrites the field, which is that warning's own silence condition.
    for (h.bag.messages()) |mi| try std.testing.expect(h.bag.get(mi).code != .W1050);
}

test "codegen: §9.15 $simparam(\"tnom\") read from the body is the same field" {
    // Not only the §3.4 default position: a model that asks mid-body gets the
    // host's value too, or the two spellings of one question would disagree.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tb(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ V(p, n) * $simparam("tnom");
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "nom_temp__: f64 = 27.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "S.con(model.nom_temp__)") != null);
}

test "codegen: §9.13 the emitted draws are IEEE 1364 §17.9.3's, digit for digit" {
    // Same arrangement as the scanner below: the kernels are `@embedFile`d into
    // every device, so what is checked here is byte-for-byte what runs there.
    //
    // §9.13.3 binds this family to IEEE 1364 §17.9.3's C listing (Table 9-26),
    // so there ARE digits to pin. Every literal below was produced by COMPILING
    // AND RUNNING that listing — the copy in Icarus Verilog's vpi/sys_random.c,
    // cross-checked against Verilator's verilated_probdist.cpp; provenance and
    // URLs in rng_kernels.zig's header — with `zig cc`, never hand-computed.
    // The log/sqrt-free rows (`uniform`, `rtl_dist_uniform`, the LCG steps) are
    // compared EXACTLY: they are pure IEEE-754 mul/add/div and the port must
    // reproduce the C bit for bit. The transcendental rows allow libm-vs-@log
    // ulp drift and nothing more — their SEEDS are still exact, because the
    // seed path is integer arithmetic and admits no drift at all.
    const k = @import("rng_kernels.zig");
    const eps = std.testing.expectApproxEqRel;
    // $random from seed 7 = rtl_dist_uniform(&s, INT_MIN, INT_MAX), twice — the
    // second pair proves the write-back rejoined the reference stream.
    try std.testing.expectEqual(@as(f64, -2146999808), k.zRngRand(7));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngRandNext(7));
    try std.testing.expectEqual(@as(f64, 1181502348), k.zRngRand(483484));
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngRandNext(483484));
    try std.testing.expectEqual(@as(f64, -2144582656), k.zRngRand(42));
    // One plain `uniform()` step, the Instance latch's advance.
    try std.testing.expectEqual(@as(f64, 483484), k.zRngNext(7));
    try std.testing.expectEqual(@as(f64, -483482), k.zRngNext(-7));
    try std.testing.expectEqual(@as(f64, -1844104698), k.zRngNext(0)); // 259341593 escape
    try std.testing.expectEqual(@as(f64, 69070), k.zRngNext(1));
    try std.testing.expectEqual(@as(f64, 2147345511), k.zRngNext(2147483646));
    // Table 9-26 `$rdist_uniform` → `uniform`: exact, mul/add only.
    try std.testing.expectEqual(@as(f64, 0.0011265279204053513), k.zRngUniform(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngUniformNext(7, 0.0, 10.0));
    try std.testing.expectEqual(@as(f64, 7.7508995236036071), k.zRngUniform(483484, 0.0, 10.0));
    // `$dist_uniform` → `rtl_dist_uniform`: an integer on the CLOSED range.
    try std.testing.expectEqual(@as(f64, 0), k.zRngIUniform(7, 0, 10));
    try std.testing.expectEqual(@as(f64, 1), k.zRngIUniform(7, 1, 6));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngIUniformNext(7, 0, 10));
    // The transcendental rows, each with its exact reference seed.
    try eps(@as(f64, 1.151634785351684), k.zRngNormal(7, 0.0, 1.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngNormalNext(7, 0.0, 1.0));
    try eps(@as(f64, 27.273600318905594), k.zRngExponential(7, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, 483484), k.zRngExponentialNext(7, 3.0));
    try std.testing.expectEqual(@as(f64, 0), k.zRngPoisson(7, 3.0));
    try std.testing.expectEqual(@as(f64, 483484), k.zRngPoissonNext(7, 3.0));
    try eps(@as(f64, 18.691952590208434), k.zRngChiSquare(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngChiSquareNext(7, 4.0));
    try eps(@as(f64, 0.53274261066788675), k.zRngT(7, 4.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -1368524349), k.zRngTNext(7, 4.0));
    try eps(@as(f64, 14.018964442656326), k.zRngErlang(7, 2.0, 3.0), 1e-12);
    try std.testing.expectEqual(@as(f64, -965981971), k.zRngErlangNext(7, 2.0, 3.0));
    // §9.13.1's width sentence: "a 32-bit signed integer; it can be positive or
    // negative" — both signs occur along the reference stream, and every draw
    // stays inside the width.
    var neg = false;
    var pos = false;
    var sd: i64 = 1;
    for (0..64) |_| {
        const r = k.zRngRand(sd);
        try std.testing.expect(r >= -2147483648.0 and r <= 2147483647.0);
        try std.testing.expectEqual(r, @round(r));
        if (r < 0) neg = true else pos = true;
        sd = @intFromFloat(k.zRngRandNext(sd));
    }
    try std.testing.expect(neg and pos);
    // Repeatability (§9.13.2 "shall always return the same value given the same
    // seed") and finiteness — which `proof.callAbstract` asserts of the whole
    // family, so a NaN here would be a wrong `.optimized`.
    for ([_]i64{ -2147483647, -7, 0, 1, 7, 42, 2147483646 }) |s| {
        try std.testing.expectEqual(k.zRngNext(s), k.zRngNext(s));
        try std.testing.expect(k.zRngNext(s) != @as(f64, @floatFromInt(s))); // inout: different
        try std.testing.expect(std.math.isFinite(k.zRngT(s, 4.0)));
        try std.testing.expect(std.math.isFinite(k.zRngNormal(s, 0.0, 1.0)));
        try std.testing.expect(std.math.isFinite(k.zRngChiSquare(s, 4.0)));
        try std.testing.expect(k.zRngPoisson(s, 3.0) >= 0.0);
    }
}

test "codegen: §9.5.4.2 the emitted scanner is the one the fixtures assert" {
    // The kernels are `@embedFile`d into every device, so the rows checked here
    // are byte-for-byte the code that runs there — the same arrangement
    // `filter_kernels.zig` has, and the reason both live in real Zig files.
    //
    // Every row below is a sentence of §9.5.4.2, and the numbers are the ones
    // tests/fixtures/ch09_system_tasks/{048,162,09,06} hold VerA to.
    const k = @import("str_kernels.zig");
    // "the number of successfully matched and assigned input items is returned"
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("42", "%d"));
    try std.testing.expectEqual(@as(i64, 42), k.zScanI("42", "%d", 0));
    // A suppressed field is consumed, takes no argument and is not counted.
    try std.testing.expectEqual(@as(i64, 1), k.zScanN("12 34", "%*d %d"));
    try std.testing.expectEqual(@as(i64, 34), k.zScanI("12 34", "%*d %d", 0));
    // "a decimal digit string that specifies an optional numerical maximum
    // field width" — the field ends there, even mid-number.
    try std.testing.expectEqual(@as(i64, 12), k.zScanI("12345", "%2d", 0));
    // "0 in the event of an early matching failure", and EOF (-1) when the
    // input ends before any conversion at all.
    try std.testing.expectEqual(@as(i64, 0), k.zScanN("hello", "%d"));
    try std.testing.expectEqual(@as(i64, -1), k.zScanN("", "%d"));
    // "%s Matches a string" then "%f ... Matches a floating point number".
    try std.testing.expectEqual(@as(i64, 2), k.zScanN("abc 5.5", "%s %f"));
    try std.testing.expectEqualStrings("abc", k.zScanS("abc 5.5", "%s %f", 0));
    try std.testing.expectEqual(@as(f64, 5.5), k.zScanR("abc 5.5", "%s %f", 1));
    // Literal text in the control string must match, and %e reads back what
    // §9.4.3's `%10.4e` wrote (09_string_formatting.va's round trip).
    const txt = try std.fmt.bufPrint(k.zSBuf(0), "value={e:>10.4}", .{0.5});
    try std.testing.expectEqual(@as(f64, 0.5), k.zScanR(txt, "value=%e", 0));
    try std.testing.expectEqual(@as(i64, 0), k.zScanN(txt, "other=%e"));
    // Two call sites, two scratch rows: §9.5.3 gives each writer its own string
    // variable, so one must not overwrite the other's bytes.
    const hex = try std.fmt.bufPrint(k.zSBuf(1), "{x}", .{@as(i64, 4096)});
    try std.testing.expectEqual(@as(i64, 1000), k.zScanI(hex, "%d", 0));
    try std.testing.expectEqualStrings("value= 5.0000e-1", txt);
}

test "codegen: §9.5 the emitted descriptors are the ones the fixtures assert" {
    // Same arrangement as the two above: the kernels are `@embedFile`d into the
    // printing artifact, so what runs here is byte-for-byte what runs there.
    //
    // Every claim below is a sentence of §9.5.1/§9.5.4/§9.5.5/§9.5.7/§9.5.8, and
    // the digits are the ones tests/fixtures/ch09_system_tasks/{07,046,049,050,
    // 051,053,054,158,11} hold VerA to.
    const k = @import("file_kernels.zig");
    // The kernels resolve a path relative to the process cwd — which is exactly
    // what makes `ch09_047_missing.dat` a claim about a DIRECTORY, and why
    // tests/torture.zig runs each fixture in its own — so the name is what has to
    // be unique here.
    const path = ".zig-cache/vera-file-kernels-test.dat";
    const absent = ".zig-cache/vera-file-kernels-absent.dat";

    // §9.5.1 "the most significant bit (bit 31) of a fd is reserved and shall
    // always be set", and "three file descriptors are pre-opened ...
    // 32'h8000_0000, 32'h8000_0001, and 32'h8000_0002", so a fresh channel's
    // small number is greater than 2.
    const w = k.zFOpen(path, "w", false);
    try std.testing.expect(w & 2147483648 != 0);
    try std.testing.expect(w & 2147483647 > 2);
    // §9.5.2's output side at the byte level: four bytes in, four bytes out.
    try std.testing.expectEqual(@as(i64, 4), k.zFPut(w, "abc\n"));
    _ = k.zFClose(w);

    const r = k.zFOpen(path, "r", false);
    try std.testing.expect(r & 2147483648 != 0);
    // §9.5.5 "$ftell ... the offset from the beginning of the file of the current
    // byte" — 0 before any read.
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(r));
    // §9.5.8 "returns zero otherwise": nothing has been read, so no EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFEof(r));
    // §9.5.4.1 "until a newline character is read AND TRANSFERRED to str ... the
    // number of characters read is returned in code" — 4, not the 3 a C `fgets`
    // minus its delimiter gives.
    try std.testing.expectEqual(@as(i64, 4), k.zFGets(r));
    try std.testing.expectEqualStrings("abc\n", k.zFLine(4, r));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(r));
    // The read that runs off the end is the one §9.5.8 promises a nonzero answer
    // for; the first need not have touched EOF.
    try std.testing.expectEqual(@as(i64, 0), k.zFGets(r));
    try std.testing.expect(k.zFEof(r) != 0);
    // §9.5.5 "$fseek ... 2 sets position to EOF plus offset", and the return is a
    // STATUS: "otherwise, code is set to 0".
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(r, 0, 2));
    try std.testing.expectEqual(@as(i64, 4), k.zFTell(r));
    // "$rewind is equivalent to $fseek (fd,0,0)" — in status and in effect.
    try std.testing.expectEqual(@as(i64, 0), k.zFSeek(r, 0, 0));
    try std.testing.expectEqual(@as(i64, 0), k.zFTell(r));
    // §9.5.7 "if the most recent operation did not result in an error, then the
    // value returned shall be zero, and the string variable str shall be empty".
    try std.testing.expectEqual(@as(i64, 0), k.zFError(r));
    try std.testing.expectEqualStrings("", k.zFErrorStr(0, r));
    _ = k.zFClose(r);

    // §9.5.1 "if a file cannot be opened (either the file does not exist and the
    // type specified is r ...) a zero is returned for the mcd or fd", and
    // "applications can call $ferror to determine the cause of the most recent
    // error".
    const bad = k.zFOpen(absent, "r", false);
    try std.testing.expectEqual(@as(i64, 0), bad);
    try std.testing.expect(k.zFError(bad) != 0);
    try std.testing.expect(k.zFErrorStr(k.zFError(bad), bad).len != 0);

    // §9.5.1's other overload: "the multichannel descriptor mcd is a 32-bit
    // integer in which a SINGLE BIT is set", bit 0 "always refers to the standard
    // output", and bit 31 "shall always be CLEARED".
    const mcd = k.zFOpen(path, "", true);
    try std.testing.expect(mcd & 2147483648 == 0);
    try std.testing.expect(mcd != 0 and mcd & (mcd - 1) == 0);
    try std.testing.expect(mcd != 1);
    _ = k.zFClose(mcd);
    // "The $fopen function shall reuse channels that have been closed."
    try std.testing.expectEqual(mcd, k.zFOpen(path, "", true));
    _ = k.zFClose(mcd);
}

test "codegen: §9.21 the emitted table interpolator is the one the fixtures assert" {
    const k = @import("table_kernels.zig");
    // A one-derivative stand-in for the device's scalar: enough of the interface
    // `zTable` uses (`con`/`val`/`add`/`addC`/`scale`) to see the Jacobian, which
    // is the half of the answer no fixture can read.
    const S = struct {
        v: f64,
        d: f64 = 0.0,
        const T = @This();
        pub fn con(c: f64) T {
            return .{ .v = c };
        }
        pub fn val(a: T) f64 {
            return a.v;
        }
        pub fn add(a: T, b: T) T {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn addC(a: T, c: f64) T {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn scale(a: T, c: f64) T {
            return .{ .v = a.v * c, .d = a.d * c };
        }
    };
    // §9.21.1's printed sample set: f(x,y) = 0.5x + y on three isolines of y,
    // laid out `y x f(x,y)` — 12 rows of 3 columns, outermost-first. The same
    // twelve rows 155_table_model_lrm_sample_set.va and ch09_table_model_2d.tbl
    // carry.
    const rows = [_]f64{
        0.0, 1.0, 0.5, 0.0, 2.0, 1.0, 0.0, 3.0, 1.5,
        0.0, 4.0, 2.0, 0.0, 5.0, 2.5, 0.0, 6.0, 3.0,
        0.5, 1.0, 1.0, 0.5, 3.0, 2.0, 0.5, 5.0, 3.0,
        1.0, 1.0, 1.5, 1.0, 2.0, 2.0, 1.0, 4.0, 3.0,
    };
    // Figure 9-2's own lookup and its own answer: bracket y=0.25 by the 0.0/0.5
    // isolines, interpolate each at x=3.5 (1.75 and 2.25), interpolate those in
    // y. Every intermediate is dyadic, so this is exact.
    const f = k.zTable(S, 12, 3, 2, 2, "LLLL", rows, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5, .d = 1.0 } });
    try std.testing.expectEqual(@as(f64, 2.0), f.v);
    // The scheme is piecewise linear and the samples lie on 0.5x + y, so ∂f/∂x
    // is 0.5 — the Jacobian entry a probe in the lookup slot owes the solver.
    try std.testing.expectEqual(@as(f64, 0.5), f.d);

    // §9.21.1 "if the user provides the data in random order the system will
    // sort the data into isolines in each dimension". Same table, rows reversed:
    // without the sort the isolines are shredded and the answer is quietly wrong.
    var back: [36]f64 = undefined;
    for (0..12) |r| for (0..3) |c| {
        back[r * 3 + c] = rows[(11 - r) * 3 + c];
    };
    const g = k.zTable(S, 12, 3, 2, 2, "LLLL", back, [_]S{ .{ .v = 0.25 }, .{ .v = 3.5 } });
    try std.testing.expectEqual(@as(f64, 2.0), g.v);

    // 131_table_model_array_control.va: one dimension, two samples on f(x) = 2x,
    // "1LL;1" — halfway between them.
    const line = [_]f64{ 1.0, 2.0, 3.0, 6.0 };
    const h1 = k.zTable(S, 2, 2, 1, 1, "LL", line, [_]S{.{ .v = 2.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 4.0), h1.v);
    try std.testing.expectEqual(@as(f64, 2.0), h1.d);
    // Table 9-31: linear extrapolation "extends linearly to the requested point
    // from the endpoint using a slope consistent with the selected interpolation
    // method" — so f(0) = 0 and f(5) = 10 off both ends…
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "LL", line, [_]S{.{ .v = 0.0 }}).v);
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "LL", line, [_]S{.{ .v = 5.0 }}).v);
    // …while constant extrapolation "returns the table endpoint value", and the
    // two ends are independent: `"CL"` clamps below 1.0 and still extrapolates
    // above 3.0. A swapped pair would pass every symmetric test there is.
    const cl = k.zTable(S, 2, 2, 1, 1, "CL", line, [_]S{.{ .v = 0.0, .d = 1.0 }});
    try std.testing.expectEqual(@as(f64, 2.0), cl.v);
    try std.testing.expectEqual(@as(f64, 0.0), cl.d); // clamped ⇒ flat
    try std.testing.expectEqual(@as(f64, 10.0), k.zTable(S, 2, 2, 1, 1, "CL", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 6.0), k.zTable(S, 2, 2, 1, 1, "LC", line, [_]S{.{ .v = 5.0 }}).v);
    try std.testing.expectEqual(@as(f64, 0.0), k.zTable(S, 2, 2, 1, 1, "LC", line, [_]S{.{ .v = 0.0 }}).v);
    // §9.21.2's dependent selector picks a COLUMN: two dependents over the same
    // isolines, and `;2` reads the second.
    const two = [_]f64{ 1.0, 2.0, 20.0, 3.0, 6.0, 60.0 };
    try std.testing.expectEqual(@as(f64, 4.0), k.zTable(S, 2, 3, 1, 1, "LL", two, [_]S{.{ .v = 2.0 }}).v);
    try std.testing.expectEqual(@as(f64, 40.0), k.zTable(S, 2, 3, 1, 2, "LL", two, [_]S{.{ .v = 2.0 }}).v);
}

test "codegen: §4.5.11 the bilinear transform is the one the emitted filter runs" {
    // `filter_kernels.zig` is `@embedFile`d, so — like the four kernels above —
    // what is exercised here is byte-for-byte what a device runs. It was the
    // tree's one file reachable by neither import graph AND by no test, which is
    // why this is characterization: a reviewer hand-checked D=2 and D=3 and found
    // the kernel correct, and these rows are that check made runnable.
    const k = @import("filter_kernels.zig");
    // §4.5.11's trapezoidal substitution `s = k(1−z⁻¹)/(1+z⁻¹)`, cleared by
    // `(1+z⁻¹)ᴰ`. Multiplied out for D = 2 that is
    //   q₀ = p₀ + p₁k + p₂k², q₁ = 2p₀ − 2p₂k², q₂ = p₀ − p₁k + p₂k²,
    // and with p = [1,2,3], k = 2 every term is dyadic, so this is exact.
    const q2 = k.zBilin(2, .{ 1.0, 2.0, 3.0 }, 2.0);
    try std.testing.expectEqual([3]f64{ 17.0, -22.0, 9.0 }, q2);

    // The two evaluations of the transform that hold at EVERY degree, and the
    // reason a wrong sign in either inner loop cannot hide:
    //   z = 1  (z⁻¹ = 1)  ⇒ (1−z⁻¹) = 0, so only the i = 0 term lives: Σqⱼ = p₀·2ᴰ.
    //     That is DC gain, and it is what `zLaplace`'s `dt <= 0` arm computes the
    //     other way (`H(0) = num[0]/den[0]`); the two must agree or a filter's
    //     operating point disagrees with its first transient step.
    //   z = −1 (z⁻¹ = −1) ⇒ (1+z⁻¹) = 0, so only i = D lives: Σ(−1)ʲqⱼ = p_D·kᴰ·2ᴰ.
    const p3 = [4]f64{ 1.5, -2.0, 0.25, 4.0 };
    inline for (.{ 1.0, 2.0, 8.0 }) |kk| {
        const q3 = k.zBilin(3, p3, kk);
        var dc: f64 = 0.0;
        var ny: f64 = 0.0;
        for (q3, 0..) |c, j| {
            dc += c;
            ny += if (j % 2 == 0) c else -c;
        }
        try std.testing.expectApproxEqRel(p3[0] * 8.0, dc, 1e-12);
        try std.testing.expectApproxEqRel(p3[3] * kk * kk * kk * 8.0, ny, 1e-12);
    }
    // D = 0 is a bare gain: no substitution to make, nothing to clear.
    try std.testing.expectEqual([1]f64{7.0}, k.zBilin(0, .{7.0}, 3.0));
}

test "codegen: §4.5.15 the emitted limiters are the ones the annex E fixtures assert" {
    // `limit_kernels.zig` is `@embedFile`d into every device with an honoured
    // `$limit`, so the shapes pinned here are the shapes that run there. They
    // need pinning HERE and nowhere else: `tb.zig` generates calls to
    // `updateState`/`display`/`eval`/`q` only, so no fixture ever executes
    // `D.limit`, and until this file existed the limiters were a string literal
    // that nothing in the tree could call.
    //
    // §4.5.15 leaves the algorithm implementation-defined; what the LRM does fix
    // is §9.17.3's "when the simulator has converged, the return value of the
    // $limit() function is the value of the access function reference". Every
    // TRANSPARENCY row below is that sentence, and it is also what makes
    // `cg_limit.emitClamp`'s `if (vl != vn) ok = false;` a truthful convergence
    // flag rather than a permanent `false`. The rest are ngspice `devsup.c`.
    const k = @import("limit_kernels.zig");
    const vt = 0.025852; // kT/q at 300 K, the `$vt` every junction model passes
    const vcrit = 0.6;

    // TRANSPARENCY. A bias below `vcrit` is returned BIT-identically — this is
    // the row `annex_e_spice/limit_pnj.va` asserts through the device.
    try std.testing.expectEqual(@as(f64, 0.3), k.zPnjlim(0.3, 0.3, vt, vcrit));
    // `DEVpnjlim` damps only past `vcrit` AND past a two-`vt` step; the damped
    // answer lands strictly between the two iterates, so the clamp pulls the
    // step back without reversing it. (0.6255 V here, but the bracket is the
    // claim: a sign slip in `vold ± vt*(2+log(…))` leaves it.)
    const damped = k.zPnjlim(1.0, 0.5, vt, vcrit);
    try std.testing.expect(damped > 0.5 and damped < 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6254615), damped, 1e-7);
    // Cold start: `vold <= 0` has no exponential to step back along, so the
    // answer is the logarithmic one, `vt*ln(vnew/vt)` — far below `vnew`.
    try std.testing.expectApproxEqAbs(@as(f64, 0.094499), k.zPnjlim(1.0, 0.0, vt, vcrit), 1e-6);
    // Reverse bias is FLOORED, and the two floors are different formulas:
    // `-vold-1` from a forward-biased previous iterate, `2*vold-1` from a
    // reverse-biased one. A swap passes at vold = -1 and nowhere else.
    try std.testing.expectEqual(@as(f64, -1.5), k.zPnjlim(-5.0, 0.5, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.4), k.zPnjlim(-5.0, -0.2, vt, vcrit));
    try std.testing.expectEqual(@as(f64, -1.0), k.zPnjlim(-1.0, 0.5, vt, vcrit)); // above the floor: transparent

    // TRANSPARENCY, `limit_fet.va`'s digits exactly: vnew = vold = 0.3, vth = 0.7.
    try std.testing.expectEqual(@as(f64, 0.3), k.zFetlim(0.3, 0.3, 0.7));
    // `DEVfetlim` off-region (`vold < vto`): turning on stops at `vto+0.5`,
    // turning off steps by at most `vtsthi = |2(vold-vto)|+2` = 3.4 V here.
    try std.testing.expectEqual(@as(f64, 1.2), k.zFetlim(5.0, 0.0, 0.7));
    try std.testing.expectEqual(@as(f64, -3.4), k.zFetlim(-5.0, 0.0, 0.7));
    // Middle region (`vto <= vold < vto+3.5`): a window of `vto-0.5 … vto+4`.
    // (`vto ± c` is computed, not written, so these two are the only rows here
    // that cannot be spelled as an exact literal.)
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), k.zFetlim(10.0, 1.0, 0.7), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), k.zFetlim(-10.0, 1.0, 0.7), 1e-15);

    // TRANSPARENCY, `limit_vds.va`'s digits: 0.4 V from a cold 0 V is inside
    // both of `DEVlimvds`'s low-`vold` bounds (+4 rising, −0.5 falling).
    try std.testing.expectEqual(@as(f64, 0.4), k.zLimvds(0.4, 0.0));
    try std.testing.expectEqual(@as(f64, 4.0), k.zLimvds(10.0, 0.0));
    try std.testing.expectEqual(@as(f64, -0.5), k.zLimvds(-3.0, 0.0));
    // Past 3.5 V the bound becomes multiplicative going up (`3*vold+2`) and a
    // floor of 2 V coming down — the fixture header's "only a previous iterate
    // at or above 3.5 V would answer max(0.4, 2) = 2".
    try std.testing.expectEqual(@as(f64, 14.0), k.zLimvds(100.0, 4.0));
    try std.testing.expectEqual(@as(f64, 2.0), k.zLimvds(1.0, 4.0));
}

test "codegen: §4.5.15 signed $limit clamps sign*v and seeds sign*vcrit" {
    // The frame-sign extension: `$limit(V(a,b), "pnjlim", vt, vc, type)`.
    // devsup.c limiters assume forward = positive; a PNP passes type = -1 and
    // the emitted clamp must (1) run the kernel on sg·v, (2) hand back
    // sg·result, (3) seed the junction at sign·vcrit. The unsigned spelling
    // must stay byte-identical to what it was — no sg indirection.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  parameter real type = -1.0;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc, type) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The ±1 is recovered ONCE per distinct sign at the top of `limit` and
    // each clamp aliases it — every clamp on a MOSFET reads the same latched
    // `type`, so re-spelling the compare per site cost 8 Ir per instance per
    // Newton iterate for an answer that cannot have changed between them.
    try std.testing.expect(std.mem.indexOf(u8, s, "const zsg__") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, " < 0) -1.0 else 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "const sg: f64 = zsg__") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "sg * zPnjlim(sg * vn, sg * vo") != null);
    // The live sets. The probe is `V(mid)` — mid against §1.3.1.1 ground, not
    // against the port — so `mid` (bit 1) is the only unknown either half
    // touches and `p` (bit 0) stays clear in both.
    try std.testing.expect(std.mem.indexOf(u8, s, "pub const limit_reads: u64 = 0x2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "pub const limit_writes: u64 = 0x2;") != null);
    // Seed picks the branch by the sign's runtime value.
    try std.testing.expect(std.mem.indexOf(u8, s, "s[@intFromEnum(U.mid)] = if (") != null);
    // Convergence verdict unchanged: pnjlim still reports through `ok`.
    try std.testing.expect(std.mem.indexOf(u8, s, "if (vl != vn) ok = false;") != null);

    // Unsigned control: no sg anywhere.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "sg") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "zPnjlim(vn, vo") != null);
}

test "codegen: §4.5.15 a fetlimds pair + limvds emit ngspice's mode ladder" {
    // The mos-family frame swap (mos1load.c:351-373): both gate legs spelled
    // "fetlimds" plus a limvds on the channel emit ONE rung that branches on
    // the sign of the OLD vds, fetlims only the controlling leg, and gives
    // limvds mode-dependent write targets — `di` in normal mode (vgs is
    // preserved, vgd derived), `si` in inverse mode (`vds =
    // -DEVlimvds(-vds,-vdso)`, vgd preserved, vgs derived).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(g, d, s);
        \\  inout g, d, s; electrical g, d, s, di, si;
        \\  parameter real vto = 0.7;
        \\  parameter real type = -1.0;
        \\  real vgs, vgd, vds;
        \\  analog begin
        \\    vgs = type * $limit(V(g, si), "fetlimds", type * vto, type);
        \\    vgd = type * $limit(V(g, di), "fetlimds", type * vto, type);
        \\    vds = type * $limit(V(di, si), "limvds", type);
        \\    I(d, di) <+ (V(d) - V(di)) / 10.0;
        \\    I(s, si) <+ (V(s) - V(si)) / 10.0;
        \\    I(di, si) <+ 1e-3 * (vgs + vgd + vds);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    // The branch condition is the limiter's own memory, in the device frame.
    try std.testing.expect(std.mem.indexOf(u8, s, "const vdso = old[@intFromEnum(U.di)] - old[@intFromEnum(U.si)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "if (sgt * vdso >= 0.0) {") != null);
    // Normal arm: +frame limvds, correction to the drain side.
    try std.testing.expect(std.mem.indexOf(u8, s, "const dl = sgt * zLimvds(sgt * dn, sgt * vdso);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "x[@intFromEnum(U.di)] += dl - dn;") != null);
    // Inverse arm: −frame limvds, correction to the source side.
    try std.testing.expect(std.mem.indexOf(u8, s, "const dl = -sgt * zLimvds(-sgt * dn, -sgt * vdso);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "x[@intFromEnum(U.si)] -= dl - dn;") != null);
    // The limvds site is CLAIMED by the ladder — no standalone clamp shape.
    try std.testing.expect(std.mem.indexOf(u8, s, "zLimvds(sg * vn") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "zLimvds(vn, vo") == null);

    // A dangling fetlimds (no second leg, no limvds) is declined whole, not
    // half-honoured as a static clamp — that would be the bug back again.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m2(g, s);
        \\  inout g, s; electrical g, s, si;
        \\  parameter real vto = 0.7;
        \\  analog I(si, s) <+ ($limit(V(g, si), "fetlimds", vto) - V(s)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "no complete mode ladder") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "pub fn limit(") == null);
}

test "codegen: cross-fed held state emits stateCtl with accepted twins" {
    // The hysteresis-FSM hook (contract.zig StateCtlOp): a module whose held
    // state is written from cross edges gets stateCtl + accepted-copy twins,
    // so the transient can land its conductance flip sharp. A held variable
    // fed only by a timer does NOT — breakpoints already place those edges.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n, c);
        \\  inout p, n, c; electrical p, n, c;
        \\  integer latched;
        \\  analog begin
        \\    @(cross(V(c) - 0.5, +1)) latched = 1;
        \\    @(cross(V(c) - 0.5, -1)) latched = 0;
        \\    I(p, n) <+ ((latched > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s, "pub fn stateCtl(") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__held__latched__acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__prev__acc = inst.") != null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tmr(p, n);
        \\  inout p, n; electrical p, n;
        \\  integer armed;
        \\  analog begin
        \\    @(timer(1n)) armed = 1;
        \\    I(p, n) <+ ((armed > 0) ? 1.0 : 1.0e-9) * V(p, n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "stateCtl") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "__acc") == null);
}

test "codegen: a $prev-only model still gets latch staging and commit" {
    // `$prev` plants a path_prev site with NO path_acc sibling (the reactive
    // lowering always pairs them, a source site arrives alone), so every gate
    // on the latch machinery must key on pathLatches(), not acc_lo — this is
    // the model that fails silently (pb__ stuck at 0.0) if one reverts.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module avg(p, n);
        \\  inout p, n; electrical p, n;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 + 0.1 * V(p, n);
        \\    I(p, n) <+ 0.5 * (g + $prev(g)) * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const s = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s, "S.con(inst.pb__0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "inst.wb__0 = ") != null); // updateState stages
    try std.testing.expect(std.mem.indexOf(u8, s, "inst.pb__0 = inst.wb__0;") != null); // commit latches
    try std.testing.expect(std.mem.indexOf(u8, s, "pub fn stateCtl(") != null);

    // $prev of a value with no unknown dependence is the value itself — no
    // latch, no hook, byte-identical to writing the parameter.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module k(p, n);
        \\  inout p, n; electrical p, n;
        \\  parameter real c = 2.0;
        \\  analog I(p, n) <+ $prev(c) * V(p, n);
        \\endmodule
    , &h2);
    defer h2.deinit();
    const s2 = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, s2, "pb__") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2, "stateCtl") == null);
}

test "codegen: every .val()-collapsing helper is on the lane-pin ledger" {
    // The `lane_clean` promise is only as good as its pins, and the pins are
    // hand-placed at emission sites — fixture 158 (zPow) proved a forgotten
    // one ships a false promise. This binds the two mechanically: any helper
    // in the emitted math/ops templates whose BODY reads `.val(` must appear
    // here, and adding one without deciding its pin fails this test, not a
    // customer's batch run. A helper is on the ledger either because its
    // emission site calls `pinLanes` (see each site's comment) or because it
    // steers only on lane-UNIFORM state (dt, ic, inst history — never x).
    const pinned = [_][]const u8{
        "zPow",    "zHypot", "zFmod", "zFloor", "zCeil",
        "zAtan2",  "zLimexp", "zWrap",  "zLimitUf",
    };
    const uniform = [_][]const u8{
        "zDdt", "zIdt", "zIdtAcc", "zIdtmod", "zSlew", "zTransFrac",
        "zTransition", "zAbsdelay", "zLog10", "zTan", "zAsin", "zAcos",
        "zAsinh", "zAcosh", "zAtanh", "zPadInt",
    };
    const text = math_txt ++ ops_txt;
    var it = std.mem.splitSequence(u8, text, "\nfn ");
    _ = it.first(); // preamble before the first helper
    while (it.next()) |chunk| {
        const paren = std.mem.indexOfScalar(u8, chunk, '(') orelse continue;
        const fn_name = chunk[0..paren];
        // Body = up to the next helper (the split already bounded it).
        if (std.mem.indexOf(u8, chunk, ".val(") == null) continue;
        for (pinned) |p| {
            if (std.mem.eql(u8, fn_name, p)) break;
        } else for (uniform) |u| {
            if (std.mem.eql(u8, fn_name, u)) break;
        } else {
            std.debug.print("helper `{s}` reads .val() but is on neither ledger\n", .{fn_name});
            return error.TestUnexpectedResult;
        }
    }
}

test "codegen: §4.5.15 only pnjlim reports non-convergence" {
    // The kernels above are pure functions; this pins the one line of
    // `cg_limit.emitClamp` that turns `zPnjlim`'s transparency into the
    // contract's `converged` verdict. ngspice sets `icheck` from `DEVpnjlim`
    // alone, and exactly on the paths where it moved `vnew` — so "the value
    // changed" IS the flag. Nothing executes `D.limit` (see the test above), so
    // the emitted text is the only place this claim is visible.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  parameter real vt = 0.025852;
        \\  parameter real vc = 0.6;
        \\  analog I(mid, p) <+ ($limit(V(mid), "pnjlim", vt, vc) - V(p)) / 1.0;
        \\endmodule
    , &h);
    defer h.deinit();
    const pnj = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, pnj, "if (vl != vn) ok = false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, pnj, ".converged = ok }") != null);

    // fetlim clamps too, but its clamp is trajectory shaping and not a statement
    // about the residual — so the device reports converged and carries no `ok`
    // at all. An unconditional `var ok` would be an unused-variable compile
    // error in the emitted device, which no fixture would ever reach.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lim(p);
        \\  inout p; electrical p; electrical mid;
        \\  analog I(mid, p) <+ ($limit(V(mid), "fetlim", 0.7) - V(p)) / 1.0;
        \\endmodule
    , &h2);
    defer h2.deinit();
    const fet = try h2.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, fet, "zFetlim(") != null);
    try std.testing.expect(std.mem.indexOf(u8, fet, "var ok = true;") == null);
    try std.testing.expect(std.mem.indexOf(u8, fet, "vl != vn") == null);
    try std.testing.expect(std.mem.indexOf(u8, fet, ".converged = true }") != null);
}
