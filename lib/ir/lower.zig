//! Classes 3,4,5,7,9 — AST → MIR lowering + the type/discipline/param/branch
//! tables. This is the largest frontend file; it realizes most of the LRM.
//!
//! Transformation: ast.SourceFile → Mir + Lower side tables (params, branches,
//! contributions, node_order) consumed by proof.zig and codegen.zig.
//!
//! DOD: side tables are SoA (parallel slices), keyed by small integer ids.
//! node_order defines the U-enum index; keep it stable (codegen depends on it).
//!
//! FILE-AS-STRUCT: `@import("lower.zig")` is both the namespace
//! (`Lower.ParamInfo`) and the type (`lower: *const Lower`), exactly like
//! mir.zig. proof.zig / naming.zig / codegen.zig already spell it that way.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("mir.zig");
const Ssa = @import("ssa.zig");
const Elaborate = @import("elaborate.zig");
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const assert = std.debug.assert;

pub const Lower = @This(); // so `Lower.Lower` also resolves

/// Only OOM unwinds during lowering; everything else goes in the shared
/// `diag.Bag` and lowering continues with a poison value, so one run reports
/// many errors.
const Oom = std.mem.Allocator.Error;
pub const Error = Oom || error{ DiagnosticsReported, NoModule };

/// Class 3 — a resolved parameter. LRM §3.4.
pub const ParamInfo = struct {
    name: []const u8,
    /// Token of the declaration, so a class-6 diagnostic can point a label at
    /// "`k` declared here" and hang a `from (0:inf)` suggestion off it.
    tok: u32 = Mir.no_tok,
    ty: Ast.Type,
    /// An explicit `integer` declaration converts to signed 32 bits; an
    /// inferred integral parameter retains its initializer's bit pattern.
    integer32: bool = true,
    default: Mir.Value,
    /// LRM §3.4.2. CRITICAL: carry ranges here from Ast.ParamDecl.ranges.
    /// proof.zig (class 6) uses these as the bound evidence. Historically this
    /// field did not exist and ranges were dropped — that is the class-6 gap.
    ranges: []const Ast.ValueRange = &.{},
    /// §3.4.5 localparam: not part of the model card ABI.
    is_local: bool = false,
    /// §3.4 "the value under the DECLARED defaults" — `constEval` of the
    /// declaration, kept because it is the number the emitted `Model` field
    /// initializer has to carry and it cannot always be recovered from
    /// `default`. §4.2.12's `?:` lowers to a CFG diamond and a phi
    /// (`lowerTernary`), which no value-level fold over the MIR can see
    /// through; this fold ran over the AST, before the diamond existed.
    /// `null` when the default is not a constant expression at all.
    folded: ?Const = null,
};

/// Class 4 — a branch (pair of nodes carrying a flow/potential). LRM §3.12.
pub const BranchInfo = struct {
    hi: u16, // node_order index
    lo: u16, // node_order index (`ground` if implicit, §1.3.1.1)
    /// §5.4.1 "There can be any number of named branches between any two
    /// signals" — so the node pair does NOT identify the branch, and everything
    /// that retains a value per branch (§5.6.1.2/§5.6.1.3) has to key on this
    /// instead. One id per DECLARED name, elements of a §3.12 branch array
    /// included: they are separate branches over one terminal pair.
    id: u32,
};

/// §5.4.1 Example 2: "There can only be one unnamed branch between any two nets
/// or between a net and implicit ground (in addition to any number of named
/// branches)." So every `V(a,b)`/`I(a,b)` reference shares ONE identity, which
/// the node pair already determines — this is that identity, and it is
/// deliberately distinct from every named branch over the same pair.
pub const unnamed_branch: u32 = 0;

/// §1.3.1.1 the global reference node. Not a solver unknown, so it is a
/// sentinel rather than a node_order slot: probing it yields a literal 0.
pub const ground: u16 = std.math.maxInt(u16);

/// What quantity a `node_order` slot carries. The spelling does NOT answer this
/// and never could: §2.8.1 strips the backslash from an escaped identifier, so
/// the net `\flow(p,n)` *is* the identifier `flow(p,n)` and collides byte-for-byte
/// with what `flowUnknown` prints. Kind is recorded at the one place a slot is
/// created (`appendNode`) and read back by index, so no consumer re-derives
/// structure from the name.
///
/// The payload is the node whose discipline supplies the unknown's §3.6.1.2
/// tolerance — the branch's HIGH node, or the probed port. It is carried here
/// because `abstolOf` used to recover it by parsing `flow(a,b)` back apart.
///
/// §6.5.2 vector elements are deliberately NOT a fourth kind: §3.6.3 scalarises
/// `electrical [1:0] b` into two ORDINARY nets called `b[1]`/`b[0]`, and every
/// consumer downstream of that already treats them as nets. See TODO.md §3 for
/// the collision that leaves standing (`\b[0]` and `b[0]`).
pub const NodeKind = union(enum) {
    /// §3.6 a net: a declared one, a §3.6.5 implicit one, or a §3.6.3 element.
    net,
    /// §5.4.2 the current of a branch, carrying the branch's high node.
    branch_flow: u16,
    /// §5.4.3 the current through a port, carrying the port.
    port_flow: u16,
};

/// §5.4.2 the identity of a branch: its ordered node pair. `pub` because
/// codegen asks `flow_unknowns` whether a §5.6 potential contribution's branch
/// already has an unknown, and the pair is the only honest way to ask.
pub const FlowKey = struct { hi: u16, lo: u16 };

/// §4.4 access-function flavour. `V(a,b)` is a potential, `I(a,b)` a flow;
/// user natures rename them (§3.6.1.4) but the two roles are closed.
pub const Access = enum(u8) { potential, flow };

/// Class 4 — a contribution target + its accumulated value. LRM §5.6.
///
/// ONE entry per (access, BRANCH), never one per `<+` statement: §5.6.1.3
/// makes `<+` an accumulation, and conditional contributions (§5.8) only make
/// sense as "the accumulator's value at the end of the analog block". Both fall
/// out of accumulating into an SSA place, so `resist_val`/`react_val` are the
/// final reads of that place. This is also the naming.zig unit target
/// (`I_drain_source`), so it is stable under source inserts.
///
/// The branch and not the node pair, because §5.4.1 allows "any number of named
/// branches between any two signals" and §5.4.3's own diode model uses two of
/// them over one pair — `I(i_diode)` and `I(junc_cap)` between (a, c), with the
/// first READ inside the second's right-hand side. One accumulator per pair
/// answers that read with the sum and puts the junction capacitance into the
/// conduction source; two accumulators keep them the two sources the figure
/// draws. KCL is unaffected either way: codegen stamps every entry into the same
/// two node rows, so the node still sees the total.
///
/// Split into resistive (DC) and reactive (ddt/q) parts, §5.6.1.2.
pub const Contribution = struct {
    access: Access,
    /// §5.4.1 which branch retains this value: a `BranchInfo.id`, or
    /// `unnamed_branch` for the one implicit branch of the node pair.
    br: u32 = unnamed_branch,
    /// Token of the `<+` this unit came from. proof.zig's W0650 reports
    /// per-unit, so it needs the STATEMENT, not the instruction that happened
    /// to break the finiteness proof.
    tok: u32 = Mir.no_tok,
    hi: u16, // node_order index (or `ground`)
    lo: u16, // node_order index (or `ground`)
    resist_val: Mir.Value = .f_zero, // → eval()
    react_val: Mir.Value = .f_zero, // → q()   (§4.5.3 ddt)
    /// §5.6.1.3 "If a value is retained for the potential ... otherwise, if a
    /// value is retained for the flow ... otherwise the branch is an open
    /// circuit." Retention is a property of the CYCLE'S EXECUTION PATH, so this
    /// is the end-of-block read of the `Accum.wrote` flag: the constant 1.0 for
    /// an unconditional `<+` (codegen keeps today's static row), the constant
    /// 0.0 for one discarded on the straight line (no row, as today), and a phi
    /// when an `if` decides — which is what makes codegen select the branch
    /// row's CONTENT at run time instead of pinning a phantom 0 V short.
    /// `.direct` only; an indirect entry never reads it.
    wrote_val: Mir.Value = .f_zero,
    noise_srcs: []const NoiseSrc = &.{}, // §4.6.4
    /// §5.6.7 `V(out) : V(in) == e` is the SAME topology as a direct potential
    /// contribution — a source in the branch, its current an unknown — with a
    /// different constitutive row. `.direct` carries `V(hi,lo) − resist_val`;
    /// `.indirect` carries `resist_val` alone (= probe − equation), because the
    /// branch voltage is precisely what is being solved for (a nullor).
    ///
    /// A `.indirect` entry is NEVER deduped by `contribIndex`: §5.6.1.3
    /// accumulation is a property of `<+`, and each indirect statement is its
    /// own equation with its own source.
    kind: Kind = .direct,
    /// `Ast.AnalogBlock.unit` of the block that OPENED this accumulator — the
    /// module instance whose §5.4.1 branch it is. Read by `discardOpposite`
    /// alone, so an entry that later absorbed a same-kind `<+` from another
    /// instance (two resistors in parallel) keeps the first one's id: the two
    /// devices aggregate, which is right, and neither can be discarded by the
    /// third instance wired across them, which is the point.
    unit: u32 = 0,
};

pub const Kind = enum(u8) { direct, indirect };

/// §5.4.3 one probed module port: the port's node_order slot and the
/// node_order slot of the flow unknown that carries `I(<port>)`.
pub const PortProbe = struct { port: u16, u: u16 };

/// §5.4.2.1 one access function READ, kept for the end-of-module probe sweep.
pub const BranchRead = struct { access: Access, hi: u16, lo: u16, tok: u32 };

/// §3.6.3.2 one net_decl_assignment: the net's `node_order` slot and the folded
/// initializer — "a nodeset value for the potential of the net by the analog
/// solver". An initial guess, never a constraint, so it is metadata for a host
/// and reaches nothing in the residual.
pub const Nodeset = struct { node: u16, value: f64, tok: u32 };

/// §4.6.4.1/.2 the parametric forms, then §4.6.4.3/.4 the tabulated ones, then
/// §4.6.3's stimulus. APPENDED, so no existing ordinal moves.
///
/// `ac_stim` is NOT noise and never reaches `noise_gens` — codegen routes it to
/// `ac_gens` instead. It rides in this enum because it rides in the same
/// A.8.2 grammar node (`analog_small_signal_function_call`) and therefore
/// through the same collection walk: `noiseSrcsOf`, `addNoiseSrc`'s identity
/// dedup and `var_noise`'s "the source was assigned to a variable first" path
/// are all exactly what §4.6.3 needs too, and a second copy of them keyed on a
/// second struct would be the same code twice with one of the two forgetting
/// the variable case.
pub const NoiseKind = enum(u8) { thermal, flicker, table, table_log, ac_stim };

/// §4.6.4 one noise GENERATOR a contribution carries: its PSD kind and its
/// identity. `id` is the `Ast.ExprId` of the `white_noise`/`flicker_noise`
/// call that declared it, which is what §4.6.4.6 needs: "each noise function
/// generates noise which is uncorrelated with the noise generated by other
/// functions", so one CALL is one generator, and two contributions reaching
/// the same call (through a variable) share one generator — perfectly
/// correlated — while two textually separate calls never do. Codegen renames
/// the ids densely into `contract.NoiseGen.source`.
///
/// A contribution holds a SET of these, not one kind: "multiple noise
/// contributions to a single branch are combined", and the clause's own
/// examples declare a thermal source and a flicker source on the same branch
/// (`combined/13_noise_temperature_analysis.va` is that shape). A single
/// `?NoiseKind` once made the second statement overwrite the first, which
/// silently deleted a generator from the emitted `noise_gens` table — and with
/// it a PSD the host cannot know it should have asked for.
///
/// `pwr`/`exp` are §4.6.4.1/.2's OWN ARGUMENTS, as MIR values: the whole PSD
/// of a Verilog-A generator is the argument, not the tag. `white_noise(pwr)`
/// is `S(f) = pwr` and `flicker_noise(pwr, exp)` is `S(f) = pwr/f^exp`, both
/// in the contributed nature's units² per Hz — so `white_noise(2·q·|I|)` is
/// shot noise and `white_noise(4·k·T/R)` is thermal, and NOTHING in the call
/// distinguishes them. `kind` stays as topology metadata — it says which of
/// the two CALLS this row came from, which is all it ever knew — and codegen
/// exports `pwr`/`exp` through `noisePsd`, so the host never has to guess a
/// PSD off a Jacobian.
pub const NoiseSrc = struct {
    kind: NoiseKind,
    id: u32,
    /// §4.6.4.1/.2 arg 0. `.f_zero` only for a generator whose call never
    /// lowered, which cannot happen through `lowerNoise`.
    ///
    /// On an `.ac_stim` row this is §4.6.3's `mag`, the first NUMERIC argument
    /// (the analysis name is a string and does not take a slot), defaulting to
    /// the clause's 1.
    pwr: Mir.Value = .f_zero,
    /// §4.6.4.2 arg 1, the frequency exponent. Unread on a `.thermal` row, and
    /// 1 for a one-argument `flicker_noise` — the same default either way.
    ///
    /// On an `.ac_stim` row this is §4.6.3's `phase` in radians, defaulting to
    /// the clause's 0 — which is why `lowerNoise` seeds the pair differently
    /// for a stimulus than for a generator.
    exp: Mir.Value = .f_one,
    /// §4.6.4.3/.4 arg 0 of a `.table`/`.table_log` row: the vector, flattened
    /// to `f0, p0, f1, p1, …` and still unfolded. Empty on every other kind,
    /// and empty on a table call whose argument was not a vector — codegen
    /// folds, sorts and validates it, because the constants it needs are the
    /// ones `Analysis.foldConst` answers for.
    table: []const Mir.Value = &.{},
    /// The call's own token, for the diagnostics codegen raises over `table`.
    tok: u32 = Mir.no_tok,
    /// §4.6.4.6 the coefficient this CONTRIBUTION applies to the generator:
    /// the `c1` of `V(a,b) <+ c1*n`. The generator's own power is `pwr`, and
    /// the density the branch actually carries is `coeff²·pwr` — so a row
    /// exporting `pwr` alone understates a scaled source by `c²`, silently.
    ///
    /// Per (contribution, generator) and NOT per generator, which is the whole
    /// point: one shared `white_noise` reaching two branches through a
    /// variable is ONE source with TWO coefficients, and their product is the
    /// cross-spectrum the clause's Example 1 is about. It is signed, because
    /// opposite signs are anti-correlation and no squared density can say so.
    ///
    /// `.f_zero` is "no contribution has claimed this row yet"; the first use
    /// replaces it and later ones add. A row that reaches codegen still at
    /// zero never appeared in a contributed value, which `planNoise` reads as
    /// the 1 it always assumed.
    coeff: Mir.Value = .f_zero,
    /// The generator appears in a shape no single factor describes. `coeff` is
    /// then 1 — the pre-coefficient behaviour — and stays there.
    nonlinear: bool = false,
    /// §4.6.4.1/.2/.3 the optional trailing `name` argument, verbatim; empty
    /// when the call did not supply one. It is a LABEL and nothing else: the
    /// clause says "the contributions of noise sources with the same name from
    /// the same instance of a module are combined in the noise contribution
    /// summary", which is a property of the host's REPORT and not of the
    /// generators — §4.6.4.6 keeps two separate calls uncorrelated whatever
    /// they are called. So this never merges rows or touches `id`; it rides
    /// out to `contract.NoiseGen.name` for a host that prints the summary.
    name: []const u8 = "",
};

/// §3.6.1.2 tolerances of a discipline's two natures. Recorded for proof.zig
/// and for codegen's per-node abstol; nothing here consumes it.
pub const DisciplineInfo = struct {
    potential_abstol: f64 = 1e-6,
    flow_abstol: f64 = 1e-12,
    is_discrete: bool = false, // §3.6.2.2
    /// §3.6.2.1 a CONSERVATIVE discipline binds both a potential and a flow
    /// nature; §3.6.2.2 a SIGNAL-FLOW discipline binds only one. Codegen needs
    /// the distinction: a contribution to a signal-flow net has no KCL meaning.
    has_potential: bool = false,
    has_flow: bool = false,
    /// §3.6.1.4 the access identifier each bound nature declares, `""` when the
    /// discipline binds none. §4.4 requires the name in `V(n)` to be THIS one,
    /// so the check needs the discipline's spelling, not just the global set of
    /// access names.
    potential_access: []const u8 = "",
    flow_access: []const u8 = "",
};

/// Value type of a lowered expression. LRM §3.1 — the analog kernel only has
/// these three; `Ast.Type.unspecified` is resolved before it reaches here.
pub const Ty = enum(u8) { real, integer, string };

/// A lowered expression: its Value plus the LRM type that governs which opcode
/// family the *consumer* must use (§4.2.1.1–§4.2.1.3 implicit conversions).
pub const TypedValue = struct { v: Mir.Value, ty: Ty };

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

arena: std.mem.Allocator,
mir: *Mir,
/// §6.7 path → flat name, from elaboration. Read only by `flatName`.
hier_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// §9.15/§9.16, indexed by `Ast.AnalogBlock.unit`: the module a block was
/// WRITTEN in and the instance path it was inlined at. See `Design.units` —
/// flattening erases both, so elaboration publishes them.
unit_paths: []const Elaborate.UnitPath = &.{},
/// MUTABLE, and only for one reason: `Elaborate.elaborate` APPENDS to the
/// stores (§6.7 flat names, cloned expression rows, cloned statements) when it
/// flattens an instance tree. It runs as the first statement of `lowerFile`,
/// before anything here has cached an index or a slice into them, and lowering
/// itself only ever reads.
file: *Ast.SourceFile,
builder: Ssa.SsaBuilder,
/// The block statements are currently being appended to.
cur: Mir.Block = .entry,

// ---- class 3 side tables (the codegen/proof contract) ----
params: std.ArrayList(ParamInfo) = .empty, // §3.4
/// Deduped `param_ref` Value per params[i] — parallel to `params`.
param_values: std.ArrayList(Mir.Value) = .empty,
branches: std.StringHashMapUnmanaged(BranchInfo) = .empty, // §3.12 named branches
/// Last `BranchInfo.id` handed out. Starts at `unnamed_branch`, so the first
/// declared branch is 1 and no named branch can ever be mistaken for §5.4.1
/// Example 2's single implicit branch of a node pair.
last_branch_id: u32 = unnamed_branch,
/// §3.12.1 port branches: branch name → the port's `node_order` slot. A table
/// of its own and not a flag on `BranchInfo`, because a port branch is not a
/// node pair at all — it is the §5.4.3 port flow under a second name, and
/// everything that consumes `branches` (contribution keying, `flowUnknown`,
/// codegen's stamp reconstruction) is written on pairs.
port_branches: std.StringHashMapUnmanaged(u16) = .empty,
contributions: std.ArrayList(Contribution) = .empty, // §5.6
/// The U-enum index space: ports (§6.5) first, then internal nodes (§3.6.3),
/// then branch-flow unknowns (§5.4.2). Append-only ⇒ stable.
node_order: std.ArrayList([]const u8) = .empty,
/// What each node_order slot IS, as opposed to what it is SPELLED. One entry
/// per slot, appended by `appendNode` — see `NodeKind` for why the two had to
/// come apart.
node_kind: std.ArrayList(NodeKind) = .empty,
/// Discipline name per node_order slot (`""` when undeclared, §3.9).
node_disciplines: std.ArrayList([]const u8) = .empty,
/// §6.5.2.2 port direction per node_order slot (`.unspecified` for an internal
/// net or a port whose direction is never declared). A DIRECTIONAL port —
/// `input` or `output` — is the one place the LRM's signal-flow port model
/// (§1.3.4) is unambiguous, and codegen has to refuse those; which of the two
/// it is decides §1.3.4.1's contribution-target rule (see E0425).
node_dir: std.ArrayList(Ast.Direction) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the module's KCL sum
/// at `port`; codegen emits that row. Append-only ⇒ deterministic.
port_probes: std.ArrayList(PortProbe) = .empty,
/// §3.6.3.2 the net_decl_assignments of this module, in declaration order and
/// already folded. Sparse — most modules declare none — so codegen emits the
/// optional `u_nodeset` table only when this is non-empty.
nodesets: std.ArrayList(Nodeset) = .empty,
num_ports: usize = 0, // §6.5
/// §1.3.1 NET name → node_order index. Nets only: a §5.4.2/§5.4.3 flow unknown
/// is not a net and is not reachable by name (`flow_unknowns` and `port_probes`
/// are its identity), so the `contains`/`get`/`didYouMeanMap` callers below all
/// mean "is this identifier a net of this module?" and now get that answer.
node_voltages: std.StringHashMapUnmanaged(u16) = .empty,
/// §5.4.2 branch-flow identity: the node PAIR → its unknown's node_order slot.
/// The pair is the identity the LRM gives the branch, and keying on it is what
/// stopped `I(a)` and `I(a,gnd)` sharing an unknown when a plain net is spelled
/// `gnd` — see `flowUnknown`. Bounded by the branch count of one module.
flow_unknowns: std.AutoHashMapUnmanaged(FlowKey, u16) = .empty,
/// Every spelling handed to `node_order`, so `appendNode` can keep them unique.
/// This is NOT an identity table — two different unknowns may want one spelling
/// (`uniqueSpelling` names both ways that happens); it exists because the
/// emitted `U` enum has one member per slot and two members cannot share a name.
/// Heap, and one entry per `node_order` slot: the only bound on that count is
/// the source, since |U| ≤ 256 is enforced by `codegen.emitTopology` AFTER
/// lowering has built the table.
spellings: std.StringHashMapUnmanaged(void) = .empty,
disciplines: std.StringHashMapUnmanaged(DisciplineInfo) = .empty, // §3.6.2
/// §3.6.3 declared vector nets and §3.12 vector branches, by base name.
///
/// SCALARISED, so this map is the only place a range survives elaboration:
/// `electrical [3:0] p` interns four ordinary nodes called `p[3]`…`p[0]` and
/// the node table never learns that ranges exist. Everything downstream —
/// `internNode`, `probe`, the contribution index, codegen's `U` enum — sees
/// four unrelated nets and needs no change at all. What is left over is the
/// two questions a reference has to answer: is this name a vector, and is
/// this index one of its elements (E0351, E0352).
vectors: std.StringHashMapUnmanaged(VecRange) = .empty,

// ---- internal lowering state (not part of the codegen contract) ----
/// Deduped probe Value per node_order slot; `.undef` = not probed yet.
probe_cache: std.ArrayList(Mir.Value) = .empty,
/// Accumulator places, parallel to `contributions`.
accum: std.ArrayList(Accum) = .empty,
/// §1.3.1/§5.4.2.1 every access function READ, in source order. A branch is a
/// probe only once the whole module has been lowered — a contribution to it may
/// come after the read — so the rule is a sweep over this at the end, not a
/// test at the read. Reads only: the left of a `<+` is a contribution.
branch_reads: std.ArrayList(BranchRead) = .empty,
/// Preprocessed source and the lexer's `.start` column, kept ONLY so a token
/// index can become a `diag.Span`. proof.zig reaches them through
/// `tokenSpan` too — it holds a `*const Lower` already, so this is the whole
/// reason class-6 diagnostics have a source location.
src: []const u8 = "",
tok_starts: []const u32 = &.{},
/// §10.2 `default_discipline events, in text-stream order, as the preprocessor
/// saw them. Set by the caller after `init` (root.zig): a text stage cannot
/// apply the directive itself — §10.2 hands it to §7.4 discipline resolution,
/// which needs the module's declarations — so all it can do is say WHERE each
/// one took effect. Empty when the text never came through stage 1.
default_disciplines: []const Preprocessor.DefaultDiscipline = &.{},
/// §10.3 `default_transition events, in text-stream order, set by the same
/// caller for the same reason: only the text stage knows where each directive
/// sat, and only §4.5.8 codegen knows which `transition()` call it reaches.
/// `codegen.defaultTransition` does the positional lookup.
default_transitions: []const Preprocessor.DefaultTransition = &.{},
/// IEEE 1364 §19.9 `timescale, set by the same caller and for the same reason:
/// it is a text-stream fact with a §9.15 consumer. Null when the stream carried
/// no `timescale, which is not the same as a default one — Table 9-27 defines
/// "timeUnit" as "the time unit AS SPECIFIED IN `timescale", so with nothing
/// specified the parameter is not known and §9.15's fallback rule applies.
timescale: ?Preprocessor.Timescale = null,
/// IEEE 1364 §19.2 `default_nettype regions, in text-stream order, set by the
/// same caller for the same reason. Read wherever a §3.6.5 implicit net would be
/// made: `nodeOf` for a behavioral reference, and `rejectImplicitNet` over
/// `Design.implicit_nets` for the structural one elaboration spotted.
nettypes: []const Preprocessor.NetTypeRegion = &.{},
/// IEEE 1364 §19.1 `celldefine regions, in text-stream order. Read once, by
/// `lowerModule`, to tag `Mir.is_cell`.
cells: []const Preprocessor.CellRegion = &.{},
/// IEEE 1364 §19.10 `unconnected_drive regions, in text-stream order. Read by
/// `applyUnconnectedDrive`, over the ports `Design.unconnected_inputs` names.
drives: []const Preprocessor.DriveRegion = &.{},
/// `Elaborate.Design.unconnected_inputs`, held between `lowerFile` (which has
/// the design) and `lowerModule` (which has the nodes `drives` applies to).
///
/// This is the whole of the split: elaboration knows WHICH ports were left
/// blank and nothing about the directives, this file knows the directives and
/// their byte offsets and nothing about port binding. Neither half is a
/// judgement, so neither pass had to learn the other's subject.
unconnected_inputs: []const Elaborate.NameSite = &.{},
/// Where every diagnostic of this compilation goes. Shared with the other
/// stages, so the cap, the dedupe and the source order are global.
bag: *diag.Bag = undefined,
/// Set by `err`; `lowerFile` reads it. NOT `bag.entries.len`, which the cap
/// and the dedupe both make an unreliable answer to "did lowering fail".
had_error: bool = false,
/// §3.6.1.4 access identifier → which half of the discipline it reads.
access_kind: std.StringHashMapUnmanaged(Access) = .empty,
/// Visible variables (§3.2) — locals, function args, scalarized array elements.
vars: std.StringHashMapUnmanaged(VarSlot) = .empty,
/// Undo log so named blocks (§5.3.2) and inlined functions (§4.7) can shadow.
scope_log: std.ArrayList(ScopeEntry) = .empty,
/// §3.4 parameters and §3.5 genvars visible to constant evaluation.
consts: std.StringHashMapUnmanaged(Const) = .empty,
/// name → index into `params` (aliasparam §3.4.7 maps two names to one index).
param_index: std.StringHashMapUnmanaged(u32) = .empty,
/// §3.4.7 the alias side of that map, in declaration order, for the ONE
/// consumer that cannot read it out of `param_index`: the model card. An alias
/// exists to carry an override — "nmos2 #(.trise(5))" and "nmos2 #(.dtemp(5))"
/// have to mean the same thing — so the alias needs a field of its own on the
/// card, which `params` (one entry per real parameter) has no slot for.
/// `param_index` cannot answer this because it holds both names with nothing
/// saying which is the alias.
aliases: std.ArrayList(struct { name: []const u8, param: u32 }) = .empty,
/// §3.4.7's one printed example whose right-hand side is NOT a parameter:
/// `aliasparam m = $mfactor;`. The index of the parameter the alias declared, or
/// null when this module never aliased it — see `aliasSystemParam`.
mfactor_param: ?u32 = null,
/// Scalarized array bounds (§3.2.2 variables, §3.4.4 parameters).
arrays: std.StringHashMapUnmanaged(ArrayInfo) = .empty,
/// §4.6.4 the noise sources a VARIABLE holds, by name.
///
/// `noiseSrcsOf` walks a contributed expression, so it sees the generator only
/// when the call is written inside the `<+`. §4.6.4.6 writes it the other way
/// round — "Perfectly correlated noise is generated by using the output of one
/// noise function for more than one noise source", whose printed example is
/// `n = white_noise(pwr); V(a,b) <+ c1*n;` — and for that shape the walk
/// reaches an identifier and returned nothing, so the device exported no
/// `noise_gens` row at all and a host was told the model had no generators.
///
/// Each entry is the SET of generators the name carries, with the identity
/// (`NoiseSrc.id`) that makes two uses of one name share one generator — the
/// correlation §4.6.4.6 exists to express, exported as `NoiseGen.source`.
///
/// ponytail: keyed by NAME and unioned, never cleared, so this is reaching
/// rather than dataflow. A variable assigned a source and later reassigned
/// something else still counts as carrying it. The over-report is one extra row
/// in a table describing topology; the under-report it replaces was a missing
/// generator, which is a PSD a host cannot know it should have asked for.
var_noise: std.StringHashMapUnmanaged([]const NoiseSrc) = .empty,
/// §4.6.4 the `(pwr, exp)` MIR values of every lowered noise call, by
/// `Ast.ExprId`. `lowerNoise` fills it, `noiseSrcsOf` reads it back onto the
/// `NoiseSrc` it appends — the walk runs on the AST, so this map is the only
/// thing that still knows what the arguments lowered to.
noise_psd: std.AutoHashMapUnmanaged(u32, [2]Mir.Value) = .empty,
/// §4.6.4.3/.4 the same thing for the TABLE forms: the flattened
/// `f0, p0, f1, p1, …` of `noise_table`'s vector argument, by `Ast.ExprId`.
/// Absent (or empty) for a call whose argument was not a vector at all — the
/// clause's file-name form — which is the shape codegen reports, since a table
/// with no pairs in it is the one thing that cannot become a PSD.
noise_tab: std.AutoHashMapUnmanaged(u32, []const Mir.Value) = .empty,
/// §4.6.4 the RESULT value of every lowered noise call, by `Ast.ExprId`. It is
/// the variable `noiseCoeff` differentiates a contribution with respect to —
/// the AST says which generator, this says which SSA value carries it.
noise_val: std.AutoHashMapUnmanaged(u32, Mir.Value) = .empty,
/// §5.9 break/continue targets.
loops: std.ArrayList(LoopCtx) = .empty,
/// A.6.5 `disable` targets — the enclosing named blocks, innermost last.
named_blocks: std.ArrayList(NamedBlockCtx) = .empty,
/// §5.3.2 "All identifiers declared within a named sequential block can be
/// accessed outside the scope in which they are declared." The qualified
/// `<label>.<local>` spellings `publishBlockLocals` bound, which is what tells
/// them apart from §6.7.1's forbidden cross-instance variable read (E0910).
block_locals: std.StringHashMapUnmanaged(void) = .empty,
/// §4.7.1 the function currently being inlined (return slot + exit block).
ret: ?RetCtx = null,
/// §4.7.2/§6.8 the local `parameter` declarations of the function currently
/// being inlined, empty outside one. Their VALUES fold into `consts`
/// (`inlineUserFuncPre`); this slice is the MASK `lookupName`/`foldExpr` consult
/// before `param_index`, because §6.8 makes the function one of the six scopes
/// and a local declaration shadows the module's — while lookup asks
/// `param_index` first, so without the mask a module parameter of the same
/// name won over the local. A slice, not a set: a function declares a handful
/// of parameters at most, and the save/restore is two pointer copies.
func_params: []const Ast.ParamDecl = &.{},
/// §4.7.1 recursion guard — names on the inline stack.
inlining: std.ArrayList([]const u8) = .empty,
/// Non-null inside an `analog initial` block (§5.2.1) or an analog function
/// (§4.7.2); names the context in the "not allowed here" diagnostic.
restrict: ?[]const u8 = null,
/// §9.20 the analog_net_reference of every alias call so far → the unknown that
/// net was DECLARED with, before any alias moved it.
///
/// Two rules need this and neither can be answered from `node_voltages` once an
/// alias has been applied. The relation between two calls — "It shall be an
/// error for the hierarchical_reference_string to reference a node that is used
/// as an analog_net_reference in ANOTHER ... call" — is the key set. And the
/// clause's ban on a PORT as the analog_net_reference is about the net's own
/// declaration: once `n1` has been aliased onto a port, `node_voltages` says it
/// IS one, and the SECOND call of the last-writer rule would be refused for
/// something the source never wrote.
alias_home: std.StringHashMapUnmanaged(u16) = .empty,
/// §9.5.3/§9.5.4.2 — does the module call `$sformat`/`$swrite`/`$sscanf`? Set at
/// the call, read by codegen to decide whether `str_kernels.zig` is emitted. A
/// flag rather than a site list because the SITE that needs a name (the format
/// scratch) is identified by its MIR instruction, which codegen already has.
uses_str_tasks: bool = false,
/// §9.5.1–§9.5.8 — does the module call the file-descriptor family? Gates
/// `file_kernels.zig` exactly as `uses_str_tasks` gates the string kernels, and
/// only in the `display == .emit` artifact: a descriptor table is a HOST facility
/// (§9.5.1's own "if a file cannot be opened … a zero is returned" is the answer
/// a device with no such host must give), so a device compiled for a solver does
/// not carry one.
uses_file_tasks: bool = false,
/// §9.21 — does the module call `$table_model`? Set at the call, read by codegen
/// to decide whether `table_kernels.zig` is emitted, exactly as
/// `uses_str_tasks` gates the string kernels.
uses_table_model: bool = false,
/// First-call sample counts, one entry per array-source call site.
table_samples: std.ArrayList(u32) = .empty,
/// Source identity survives repeated analog-function inlining.
table_sources: std.ArrayList(Ast.ExprId) = .empty,
/// Guard-aware source-order chain for table captures and distribution checks;
/// its final value is a core live-out.
table_effect_place: ?Ssa.Place = null,
table_effect: Mir.Value = .f_zero,
/// §9.13 — does the module call one of Table 9-10's 17 probabilistic
/// distributions? Gates `rng_kernels.zig` exactly as `uses_str_tasks` gates the
/// string kernels.
uses_rng: bool = false,
/// §9.13.1 — how many call sites took the SEEDLESS form (`$random` with no
/// argument, or a constant/parameter seed, whose "internal seed ... is not
/// visible from the source"). One `Instance` latch slot each: codegen emits the
/// array, `updateState` advances it on the accepted step, and the residual only
/// reads it. Per SITE and not one shared counter because §9.13.1 says the
/// internal seed "gets updated every time the call to $arandom is made", so two
/// call sites are two streams, not two reads of one.
rng_auto_sites: u32 = 0,
/// Where a §9.21.1 `$table_model` data FILE is looked for, in order. The same
/// list `include` searches, set by the caller (root.zig) for the same reason the
/// directives above are: only the driver knows the search path. Empty means "the
/// working directory only", which is what a bare `vera foo.va` gives.
include_dirs: []const []const u8 = &.{},
/// True inside an `analog initial` block (§5.2.1), and ONLY that — `restrict`
/// conflates it with an analog function, and §9.7.2's `$stop` rule keys on the
/// narrower one. Deliberately not cleared when an analog function is inlined:
/// the call site is still "within an analog initial block", which is what the
/// sentence constrains.
in_analog_initial: bool = false,
/// `Ast.AnalogBlock.unit` of the block being lowered — the module instance that
/// wrote it. Read by `discardOpposite` only; see `newContrib`.
cur_unit: u32 = 0,
/// True while lowering the body of an `@(...)` — i.e. while the statement
/// position is A.6.4 `analog_event_statement` rather than `analog_statement`.
/// The two productions differ in BOTH directions, so this flag gates two
/// distinct rules: `disable_statement`/`event_trigger` are legal only when it
/// is set, and `contribution_statement`/`indirect_contribution_statement` and a
/// nested `analog_event_control_statement` are legal only when it is clear
/// (§5.10 states the last three as prose restrictions as well).
in_event_stmt: bool = false,
/// §5.6.7 "Indirect branch contributions shall not be used in conditional or
/// looping statements, unless the conditional expression is a constant
/// expression". Incremented only on the paths that actually emit a branch —
/// the constant-folded `if` and the unrolled genvar `for` lower their body
/// straight into `self.cur` and never come through `lowerCondBody`.
cond_depth: u32 = 0,
/// §5.8.1's carve-out, counted in parallel with `cond_depth`: how many of the
/// enclosing runtime conditionals had an A.8.3 `analysis_or_constant_expression`
/// for their condition. `cond_depth == static_cond_depth` therefore means
/// "every enclosing conditional is decided before the solve starts", which is
/// exactly when an analog operator's history stays whole (E0514).
///
/// A LOOP body never raises it: §5.9 bans analog filter functions in `repeat`,
/// `while` and non-genvar `for` with no carve-out at all, so a loop must always
/// leave `cond_depth > static_cond_depth`.
///
/// Kept SEPARATE from `cond_depth` rather than replacing it, because the two
/// answer different questions: §5.6.7 (indirect contributions) and §5.8/§5.10.3.1
/// (event control) ask for a CONSTANT condition, which `analysis("dc")` is not.
static_cond_depth: u32 = 0,
/// The module being lowered (§6.2). Set by `lowerModule`.
module: ?*const Ast.ModuleDecl = null,
/// §9.17.2 `$bound_step` / §9.17.1 `$discontinuity`. Each is an SSA place
/// seeded to +inf ("nothing asked for") in the ENTRY block and `fmin`-ed at
/// every call site, exactly like a contribution accumulator: a call under an
/// `if` therefore reaches the exit through a phi and does NOT bound the step on
/// the arm that never executed. `lowerModule` reads the final value and emits
/// ONE synthetic `call`, which is what naming.zig turns into a unit and
/// codegen's `updateState` writes into `Instance`. Null = the model never
/// called the task, so no unit and no state write.
bound_step_place: ?Ssa.Place = null,
disc_place: ?Ssa.Place = null,
/// §9.17.1 rejection belongs to the Newton iteration, not timestep history.
reject_iteration_place: ?Ssa.Place = null,
reject_iteration: Mir.Value = .zero,
/// §9.4 display tasks, in source order. A display call's RESULT is never read,
/// so it is dead code the moment codegen slices a unit out of the MIR — and the
/// print vanishes with it. `display_root` is the one live root that keeps them
/// all: see `finishDisplays`.
displays: std.ArrayList(Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// §9.4.1 display statements whose CALL is created at the end of the analog
/// block (`finishDisplays`), in source order — see `queueDisplay` for the
/// clause reading. Parallel-ish to `displays`: each entry names the
/// placeholder `displays` row whose `.val` it fills.
deferred_displays: std.ArrayList(DeferredDisplay) = .empty,
/// §6.6.1/§5.9.3 genvars currently bound in `consts` — a stack, pushed and
/// popped by `tryUnrollFor`. Exists so `queueDisplay` can SNAPSHOT the
/// bindings a deferred operand in an unrolled body was written under;
/// `tryUnrollFor` removes them from `consts` when the loop ends, which is
/// before `finishDisplays` re-lowers the operand.
active_genvars: std.ArrayList([]const u8) = .empty,
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable RETAINS its value between analog evaluations — that
/// is the entire point of `@(cross(...)) x = V(p);`, and an ordinary SSA place
/// cannot express it, because every module variable is re-initialised from its
/// declaration at the top of every evaluation. Each entry gets a persistent
/// `Instance` slot instead; codegen reads it directly.
held_vars: std.ArrayList(HeldVar) = .empty,
/// Variables `markHeldVars` found assigned under an `@(...)`, collected BEFORE
/// the module's variables are declared. Empty for a module with no event
/// control.
///
/// Keyed on §5.3.2's "unique location", i.e. the pair (scope, name) spelled as
/// a dotted path: a module variable is its bare name, a named block's local is
/// `<label>.<name>` (`<outer>.<inner>.<name>` when nested). A bare name would
/// make `lo.n`, `hi.n` and the module's own `n` one slot.
held_names: std.StringHashMapUnmanaged(void) = .empty,
/// The enclosing NAMED blocks during `scanHeld`, so a target resolves to the
/// nearest declaration of it — a module variable assigned from inside a block
/// still keys bare, because the block does not declare it.
held_frames: std.ArrayList(HeldFrame) = .empty,
/// §5.3.2 the dotted prefix of the named block being lowered ("" at module
/// scope, "lo." inside `begin : lo`). The lowering-side half of `held_names`'
/// key; see `declareVarDecl`.
block_path: []const u8 = "",
/// §9.17.3 the user-function `$limit` state, one entry per ACCESS FUNCTION.
/// Collected by `scanCallSites` before the analog block is lowered.
limit_slots: std.ArrayList(LimitSlot) = .empty,
/// §9.15 the model queries the runtime Newton iteration number.
uses_newton_iter: bool = false,
/// §9.15 the model reads a `$simparam` whose value is the HOST's
/// (`simparamHostField`), so codegen owes its Model the reserved field. Set at
/// the call because a §3.4 parameter default is lowered outside the block
/// stream, and `parameter real tnom = $simparam("tnom")` is the whole use.
uses_host_simparam: bool = false,
/// A.6.2 the digital `initial` block's assignments, name -> the constant
/// expression it leaves in that variable. Collected BEFORE the module's
/// variables are declared, for the same reason `held_names` is: the value a
/// variable starts every evaluation with is decided at its declaration.
/// Empty for a module with no `initial` block. See `collectInitialState`.
initial_state: std.StringArrayHashMapUnmanaged(struct { value: Ast.ExprId, tok: u32 }) = .empty,
/// §5.10.4 named events, name -> the flag slot `-> ev` writes and `@(ev)` reads.
/// Its own map and NOT `vars`, because §2.8 gives an event a name but no value:
/// `x = tick;` has no derivation, and putting the flag in `vars` would give it
/// one.
events: std.StringHashMapUnmanaged(Ssa.Place) = .empty,
/// §5.6.6 the branch a `<+` right-hand side is CURRENTLY being lowered for,
/// null outside one. Exists for the clause's implicit form — `I(b) <+ f(I(b))`
/// — where the rhs occurrence of the target "may be expressed in terms of
/// itself" and the simulator "will find the value ... that equals the sum of
/// the contributions made to it": that read is the branch-flow UNKNOWN of the
/// implicit equation, not the §5.6.1.2 retained accumulator (which, mid-
/// statement, still holds the sum WITHOUT this statement — a self-reference
/// answered with a stale prefix of itself). See `lowerBranchAccess`.
contrib_target: ?Target = null,

/// One §5.10 event-assigned module variable and its persistent slot.
pub const HeldVar = struct {
    /// Source spelling, INCLUDING the `[i]` of a scalarized array element
    /// (§3.2.2). Unique within the module scope, so codegen's `Instance` field
    /// name is injective after `naming.sanitize`.
    name: []const u8,
    ty: Ty,
    /// The declared initializer. Only reachable on the FIRST evaluation, so
    /// codegen renders it as the `Instance` field's default and nowhere else.
    init: Mir.Value,
    /// The `$held_*` call seeded into the ENTRY block. Reading the variable
    /// anywhere — including lexically before the `@(...)` — reads this, i.e.
    /// the value the last accepted evaluation left behind.
    seed: Mir.Value,
    /// The variable's value at the END of the analog block; `updateState`
    /// stores it back on the accepted solution. Filled by `finishHeldVars`.
    final: Mir.Value = .undef,
    place: Ssa.Place,
};

/// §9.17.3 one `$limit(access, user_function, …)` STATE SLOT.
///
/// KEYED BY THE ACCESS FUNCTION, not by the call site, and that is the whole
/// design decision here. §9.17.3 says the second argument the simulator passes
/// is "the appropriate internal state; GENERALLY, this is the value that was
/// returned by the $limit() function on the previous iteration", and §9.17.3's
/// opening sentence puts the state on the ARGUMENT ("internal state containing
/// information about the argument on previous iterations"). Per-CALL-SITE state
/// cannot express the accessor idiom every machine-converted SPICE model uses:
///
///     MOS1vgs  = type * $limit(V(g,s), DEVlimitOldGet);            // reads
///     …model's own fetlim/limvds/pnjlim ladder in plain Verilog-A…
///     load_vgs = type * $limit(V(g,s), DEVlimitNewSet, …, limited); // writes
///
/// `DEVlimitOldGet(vnew,vold) = vold`, so a per-site slot would store back the
/// value it just read and freeze at its default forever — every DEV*lim in the
/// model becomes a no-op and the Newton damping is lost. One slot per access
/// function makes the reader see what the writer left, which is what the idiom
/// means and what ngspice's `MOS1vgs` state field IS. When each site names a
/// distinct access function the two readings coincide, so this is a strict
/// generalisation of per-site state, never a weakening.
pub const LimitSlot = struct {
    /// `V(g,s)` as it reads in the source, for the `Instance` field comment.
    label: []const u8,
    access: Access,
    hi: u16,
    lo: u16,
    neg: bool,
    br: u32,
    /// This evaluation's returned value. Seeded in the entry block with the
    /// `$limit$old` read, overwritten by each site, and read back at the end of
    /// the block — so a site under an `if` that does not run leaves the slot
    /// holding what it held, and never an undefined SSA value.
    place: Ssa.Place,
    /// The `$limit$old` call seeded into the ENTRY block: the value this slot
    /// returned on the previous Newton iterate.
    seed: Mir.Value,
    /// The slot's value at the END of the analog block. `updateState` stages
    /// it; the next iterate's `updateState` promotes it into the read field.
    final: Mir.Value = .undef,
};

/// One §9.4/§9.7.3 print site.
pub const Display = struct {
    /// The synthetic `call`. Its first argument is the §2.7 format string.
    val: Mir.Value,
    /// The task's exact spelling — `$strobe`, `$write`, `$error`, … Codegen
    /// needs it for the newline rule (§9.4.1: `$write` does not append one) and
    /// for the §9.7.3 severity prefix.
    name: []const u8,
    /// The call token, for W0850/W0851.
    tok: u32,
    /// The call sits under an `if` or a loop. §9.4.6 makes emission a runtime
    /// property of the solve, which a hoisted unit root cannot express, and the
    /// value would not dominate the chain root either — so it is NOT emitted.
    conditional: bool,
};

/// One §9.4/§9.7 task whose `call` is minted at the END of the analog block —
/// every unconditional display-family statement takes this route (see
/// `queueDisplay`). Holds what the statement position knew and the end of the
/// block will not: the at-statement operand values and the genvar bindings.
const DeferredDisplay = struct {
    name: []const u8,
    tok: u32,
    /// The original argument list, `.none` slots included (A.6.9).
    args: []const Ast.ExprId,
    /// Parallel to `args`. Non-null = the operand's value, captured AT THE
    /// STATEMENT (§5.6.1.2 sequential semantics for everything that is not
    /// converged simulation data — a variable printed then reassigned shows
    /// its at-statement value). Null = the operand reads a branch flow and is
    /// lowered at the end of the block instead, against the converged
    /// retention state (§9.4.1/§5.4.2.2).
    pre: []const ?TypedValue,
    /// §5.9.3 genvar bindings live at the statement, re-established around the
    /// end-of-block lowering so `I(pair[k])` in an unrolled body still folds.
    genvars: []const GenvarBind,
    /// Index of the placeholder row in `displays` whose `.val` this fills.
    display: u32,
};

const GenvarBind = struct { name: []const u8, c: Const };

const VarSlot = struct { place: Ssa.Place, ty: Ty };
const ScopeEntry = struct { name: []const u8, prev: ?VarSlot, prev_array: ?ArrayInfo };
/// A declared array's shape (§3.2), one `Bounds` per dimension, outermost
/// first. `dims.len` is the number of subscripts a reference must supply.
const ArrayInfo = struct {
    dims: []const Bounds,
    ty: Ty,
};
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
/// A.6.5 `disable hierarchical_block_identifier` target: §5.3's "the control
/// shall pass out of the block", i.e. that block's own exit. One entry per
/// ENCLOSING named block, so an inner and an outer block of the same nesting
/// are two different targets chosen by the name and by nothing else.
const NamedBlockCtx = struct { name: []const u8, exit: Mir.Block };
/// One enclosing §5.3.2 named block, as `scanHeld` sees it: the dotted prefix
/// its locals are keyed under, and the declarations that say which names those
/// are.
const HeldFrame = struct { prefix: []const u8, vars: []const Ast.VarDecl };
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };
/// `wrote` is §5.6.1.3's retention FLAG beside the value: 0.0 in the entry
/// block, 1.0 after every `<+` on this (access, branch), back to 0.0 when the
/// opposite access discards it. It has exactly the accumulator's phi structure,
/// so "was a value retained THIS cycle?" survives a conditional as an ordinary
/// SSA boolean — which is what codegen's runtime-selected branch row reads.
/// On a straight line it folds to the constant 1.0/0.0 and costs nothing.
const Accum = struct { resist: Ssa.Place, react: Ssa.Place, wrote: Ssa.Place };

/// A folded `[msb:lsb]` (§3.6.3 Syntax 3-6 `range`). Both bounds are signed and
/// either order is legal — §3.6.3's own examples run `[5:0]` and the LRM's
/// vector-branch example runs `[3:5]` — so nothing here assumes msb ≥ lsb.
const VecRange = struct {
    msb: i64,
    lsb: i64,

    fn size(v: VecRange) u32 {
        return @intCast(@abs(v.msb - v.lsb) + 1);
    }
    fn has(v: VecRange, i: i64) bool {
        return i >= @min(v.msb, v.lsb) and i <= @max(v.msb, v.lsb);
    }
    /// The k-th element in DECLARATION order, msb first. That order is the
    /// host's terminal order for a vector port, and it is what §3.12 pairs
    /// "in a parallel one-to-one fashion" for a vector branch.
    fn at(v: VecRange, k: u32) i64 {
        const d: i64 = @intCast(k);
        return if (v.msb <= v.lsb) v.msb + d else v.msb - d;
    }
};

/// A folded constant (§4.2 constant_expression). Genvars (§3.5) and parameter
/// defaults live here so `for (i=0;i<N;i=i+1)` can unroll (§6.6.1).
pub const Const = union(enum) {
    int: i64,
    real: f64,
    str: []const u8,

    pub fn asReal(c: Const) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            .str => 0,
        };
    }
    /// §4.2.1.1 real→integer rounds, ties away from zero — and says nothing
    /// about a real that has no nearest integer, because it never contemplates
    /// one. A NaN, an infinity, and anything past i64 are all in that hole.
    ///
    /// Returns null there rather than inventing a value. Any caller holding a
    /// real the USER wrote must go through this and diagnose; `asInt` below is
    /// only for operands already known to be in range.
    pub fn asIntExact(c: Const) ?i64 {
        return switch (c) {
            .int => |i| i,
            .real => |r| blk: {
                const v = @round(r);
                if (!std.math.isFinite(v)) break :blk null;
                // Compared against 2^63 and not maxInt(i64): 2^63 is exactly
                // representable as an f64 and maxInt(i64) is not, so rounding
                // the bound itself would let 2^63 through as "in range".
                if (v >= 9223372036854775808.0 or v < -9223372036854775808.0) break :blk null;
                break :blk @intFromFloat(v);
            },
            .str => 0,
        };
    }
    pub fn asInt(c: Const) i64 {
        // Saturating, NaN to zero. This MUST NOT be able to panic: a bare
        // `@intFromFloat` on an out-of-range double is illegal behavior, and it
        // used to abort the whole compilation — no diagnostic, and every other
        // error in the file lost with it — whenever a folded subscript or a
        // `$discontinuity` degree reached it as an infinity. The two paths that
        // can see such a value now call `asIntExact` and report; this fallback
        // is what remains for operands a range check has already passed.
        return c.asIntExact() orelse blk: {
            const r = c.asReal();
            if (std.math.isNan(r)) break :blk 0;
            break :blk if (r > 0) std.math.maxInt(i64) else std.math.minInt(i64);
        };
    }
    pub fn isTrue(c: Const) bool {
        return switch (c) {
            .int => |i| i != 0,
            .real => |r| r != 0,
            .str => |s| s.len != 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// `mir` must be empty (this pass owns block 0). `file` and every string in it
/// are BORROWED and must outlive the Lower (both live in the arena).
pub fn init(
    arena: std.mem.Allocator,
    mir: *Mir,
    file: *Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
) Lower {
    assert(mir.blockCount() == 0);
    return .{
        .arena = arena,
        .mir = mir,
        .file = file,
        .src = src,
        .tok_starts = tok_starts,
        .bag = bag,
        .builder = Ssa.SsaBuilder.init(arena, mir),
    };
}

/// Frees the side tables and the SSA scratch. A no-op under an arena; present
/// so the whole pass runs leak-free on `std.testing.allocator`.
pub fn deinit(self: *Lower) void {
    const gpa = self.arena;
    self.builder.deinit();
    self.params.deinit(gpa);
    self.param_values.deinit(gpa);
    self.branches.deinit(gpa);
    self.port_branches.deinit(gpa);
    self.contributions.deinit(gpa);
    self.node_order.deinit(gpa);
    self.node_kind.deinit(gpa);
    self.node_disciplines.deinit(gpa);
    self.node_dir.deinit(gpa);
    self.port_probes.deinit(gpa);
    self.nodesets.deinit(gpa);
    self.alias_home.deinit(gpa);
    self.node_voltages.deinit(gpa);
    self.flow_unknowns.deinit(gpa);
    self.spellings.deinit(gpa);
    self.vectors.deinit(gpa);
    self.disciplines.deinit(gpa);
    self.probe_cache.deinit(gpa);
    self.accum.deinit(gpa);
    self.branch_reads.deinit(gpa);
    self.access_kind.deinit(gpa);
    self.vars.deinit(gpa);
    self.scope_log.deinit(gpa);
    self.consts.deinit(gpa);
    self.param_index.deinit(gpa);
    self.arrays.deinit(gpa);
    self.loops.deinit(gpa);
    self.named_blocks.deinit(gpa);
    self.block_locals.deinit(gpa);
    self.inlining.deinit(gpa);
    self.displays.deinit(gpa);
    self.deferred_displays.deinit(gpa);
    self.active_genvars.deinit(gpa);
    self.held_vars.deinit(gpa);
    self.limit_slots.deinit(gpa);
    self.held_names.deinit(gpa);
    self.held_frames.deinit(gpa);
    self.events.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Byte range of a token — the currency every diagnostic reports in.
/// `pub` because proof.zig maps a `Mir.Inst` back to source through it.
pub fn tokenSpan(self: *const Lower, tok: u32) diag.Span {
    return Lexer.tokenSpan(self.src, self.tok_starts, tok);
}

/// Where `tok` starts in the PREPROCESSED text — the currency §10.1's
/// positional directives are published in, so this is what a `Region` lookup
/// takes. Zero for a token index the caller never lexed, which puts the query
/// before every directive and so answers with the directive's default.
fn tokStart(self: *const Lower, tok: u32) u32 {
    return if (tok < self.tok_starts.len) self.tok_starts[tok] else 0;
}

/// Record an error and keep going. Callers substitute a poison value; nothing
/// downstream runs because `lowerFile` fails at the end.
fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    self.had_error = true;
    return self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
}

/// Same, for a diagnostic that wants a label, a note or a suggestion. The
/// caller must `emit()`.
fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    self.had_error = true;
    return self.bag.build(.lower, code, self.tokenSpan(tok));
}

/// A poison real. Lowering continues so the run reports every error at once.
const poison: TypedValue = .{ .v = .undef, .ty = .real };

// ---------------------------------------------------------------------------
// Small MIR helpers
// ---------------------------------------------------------------------------

fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    return self.mir.emit(self.arena, self.cur, op, ops);
}

fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    const callee = try self.mir.internString(self.arena, name);
    return self.mir.emitCall(self.arena, self.cur, callee, args);
}

/// Close `self.cur` with a jump and register the CFG edge (ssa.zig requires the
/// edge before the target is sealed).
fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Register both CFG edges before sealing their targets. A loop leaves its
/// exit unsealed until its body has registered any `break` predecessors.
inline fn branchTo(self: *Lower, cond: Mir.Value, then_b: Mir.Block, else_b: Mir.Block, comptime seal_else: bool) Oom!void {
    _ = try self.mir.emitBranch(self.arena, self.cur, cond, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    if (seal_else) try self.builder.sealBlock(else_b);
}

/// Start a fresh predecessor-less block. Everything appended to it is dead
/// (post-`break`/`return` code, §5.9/§4.7.1); sealing it immediately keeps the
/// SSA builder from ever waiting on an edge that will not arrive.
fn startUnreachable(self: *Lower) Oom!void {
    const b = try self.mir.addBlock(self.arena);
    try self.builder.sealBlock(b);
    self.cur = b;
}

// ---------------------------------------------------------------------------
// Type coercion — LRM §4.2.1.1 (real→integer), §4.2.1.2 (integer→real)
// ---------------------------------------------------------------------------

/// §2.7 — "A string literal used as an operand in expressions and assignments
/// shall be treated as unsigned integer constants represented by a sequence of
/// 8-bit ASCII values, with one 8-bit ASCII value representing one character."
/// A base-256 numeral, most significant character FIRST: "AB" is
/// 'A'*256 + 'B' == 16706, and the one-character "\n" is 10.
///
/// `bits` is §3.3's width rule for the assignment case — "if their size
/// differs, the literal is right justified and either truncated on the left or
/// zero filled on the left, as necessary" — and both halves of it are already
/// in this loop: the zero fill is the accumulator starting at 0, and the
/// truncation is walking only the last `bits/8` bytes.
///
/// ponytail: the result is the UNSIGNED value, so a 32-bit "\377\377\377\377"
/// is 4294967295 and not the -1 that §3.2's signed `integer` would hold. That
/// is not the width gap `wrap32` closed — width is imposed on the OPERATION
/// there, so this string reads 4294967295 and the first arithmetic done to it
/// wraps into range. §2.7 calls the operand "unsigned integer constants" in so
/// many words, so the reading here is the clause's own; sign-extending it needs
/// a fixture that asks.
pub fn strToInt(s: []const u8, bits: u8) i64 {
    var acc: u64 = 0;
    for (s[s.len - @min(s.len, bits / 8) ..]) |c| acc = acc << 8 | c;
    return @bitCast(acc);
}

/// §3.2, two sentences and one width: an `integer` "can hold values ranging from
/// -2^31 to 2^31-1", and "arithmetic operations performed on integer variables
/// produce 2's complement results". So the answer to `2147483647 + 1` is
/// -2147483648, and a 64-bit type is wrong at both ends of the range.
///
/// The width is imposed on the OPERATION, not on the storage: an `integer` stays
/// in an i64 slot (one machine word, and every ch9 status return and array
/// index already fits) and every integer arithmetic result is truncated to 32
/// bits and widened back. That is exact rather than approximate, because both
/// operands of an integer operation are themselves in range — either literals
/// §2.5.1 keeps in range or the output of another wrapped operation — so
/// truncating the 64-bit result is bit-for-bit the 32-bit result.
///
/// THREE SITES MUST AGREE and this is the only definition of the rule: this fold
/// (`foldBinary`, §4.2 constant expressions), `analysis.foldConst` (parameter
/// defaults and §4.5 operator control arguments) and `codegen.intBin` (the
/// device). A fold that disagreed with the runtime would make one expression
/// answer differently depending on whether it landed in a parameter default.
///
/// NOT applied to a literal: §2.5.1's `-2147483648` is `ineg` of the in-range-
/// as-unsigned 2147483648, and wrapping the operand first would make the
/// negation of it positive.
pub fn wrap32(x: i64) i64 {
    return @as(i32, @truncate(x));
}

/// §2.7 at an OPERAND: a string about to be used as a number becomes one.
/// Everything else is returned untouched, including a string with no compile-
/// time bytes — there is no runtime string in the emitted device, so that is
/// already broken and the caller's own diagnostic is the better one.
///
/// ponytail: 64 bits, the width of the slot the value lands in. §3.3's
/// assignment case knows the DECLARED width and passes its own; an operand has
/// only its storage, so a literal longer than eight characters keeps its low
/// eight.
fn strNum(self: *Lower, tv: TypedValue) Oom!TypedValue {
    if (tv.ty != .string) return tv;
    return switch (self.mir.valueDef(tv.v)) {
        .str_const => |s| .{ .v = try self.mir.addIntConst(self.arena, strToInt(s, 64)), .ty = .integer },
        else => tv,
    };
}

fn toReal(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    const tv = try self.strNum(tv0); // §2.7
    return switch (tv.ty) {
        .real => tv.v,
        .integer => self.emit(.if_cast, &.{tv.v}),
        .string => tv.v, // already diagnosed at the use site
    };
}

fn toInt(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    const tv = try self.strNum(tv0); // §2.7
    return switch (tv.ty) {
        .integer => tv.v,
        .real => self.emit(.fi_cast, &.{tv.v}),
        .string => tv.v,
    };
}

/// §5.7 store `tv` into a slot of type `ty`. §4.2.1.1/§4.2.1.2 convert between
/// integer and real; §3.3 draws the one line no conversion crosses, and it is
/// drawn between a string LITERAL and a string VALUE, not between the types:
///
///   "A string literal can be assigned to a string or an integral type. ...
///    A string cannot be assigned to an integral type."
///
/// So `integer code = "A";` is legal and `code = label;` (label a `string`) is
/// not, and the test is the shape of the expression, not the type it lowered
/// to. §3.3's own worked example is the same distinction one level up:
/// `r = {i{"Hi"}}` is "invalid" because Table 3-3 makes a nonconstant
/// replication a STRING, where `integer code = "A"` still has a literal in
/// hand.
///
/// Every write to a declared variable goes through this: the assignment, the
/// element-wise array assignment, and the declaration initializer.
///
/// ponytail: one ceiling left where §3.3 put it — the mirror direction, a
/// numeric into a `string` slot, which §3.4.1 forbids too, is unchecked; the
/// arm to add it to is `.string` below.
fn coerceTo(self: *Lower, e: Ast.ExprId, ty: Ty, tv: TypedValue) Oom!Mir.Value {
    if (tv.ty == .string and ty != .string) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.arena);
        if (!try self.strLitBytes(e, &bytes)) {
            try self.err(self.file.exprs.mainTok(e), .E0354, "assigning a string to {s}", .{@tagName(ty)});
            return zeroOf(ty);
        }
        // §3.3's "right justified and either truncated on the left or zero
        // filled on the left" is measured against the DECLARED type, and §3.2
        // fixes `integer` at 32 bits: "hello" is 40 bits and loses its 'h'.
        // That width is the LRM's and not VerA's storage — see `strToInt`.
        if (ty == .integer) return self.mir.addIntConst(self.arena, strToInt(bytes.items, 32));
    }
    return switch (ty) {
        .real => self.toReal(tv),
        .integer => self.toInt(tv),
        .string => tv.v,
    };
}

/// Is `e` a §3.3 string LITERAL, and what are its bytes? The literal itself, or
/// a concatenation of literals — §4.2.13's replication with a literal count is
/// unrolled by the parser, so `{5{"Hi"}}` arrives as five operands.
///
/// A `.multi_concat` is deliberately not one, and that exclusion is the whole
/// rule: Table 3-3's multiplier "can be nonconstant", and a nonconstant one
/// leaves a string with no width at elaboration, which is why §3.3's own
/// example makes `r = {i{"Hi"}}` invalid where `b = {i{"Hi"}}` is fine.
///
/// The test cannot be made on the VALUE, and that is why it is made on the
/// AST: the SSA builder answers a read of a once-written `string label = "hi"`
/// with the very `str_const` the literal produced, so by the time lowering has
/// a Value in hand `code = label` and `code = "hi"` are the same thing — and
/// §3.3 says one is an error and the other is not.
///
/// Table 3-3's empty-string row is the one place these bytes differ from the
/// string the same expression evaluates to: `""` "is converted to 8'b0", so
/// `{"H", ""}` is "H" as a string and 'H' followed by one zero byte as an
/// integral.
fn strLitBytes(self: *Lower, e: Ast.ExprId, out: *std.ArrayList(u8)) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .str_literal => {
            const s = self.file.str(ex.strOf(e));
            try out.appendSlice(self.arena, if (s.len == 0) &[_]u8{0} else s);
            return true;
        },
        .concat => {
            for (ex.args(e)) |el| if (!try self.strLitBytes(el, out)) return false;
            return true;
        },
        else => return false,
    }
}

/// §4.2.8 — a condition is "true" when non-zero. Normalized to integer 0/1 so
/// `logand`/`logor`/`branch` all see the same shape.
fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .integer => self.emit(.ine, &.{ tv.v, .zero }),
        .real => self.emit(.fne, &.{ tv.v, .f_zero }),
        .string => .zero,
    };
}

/// §4.2.1 — an operation with one real operand is performed in real.
fn unify(a: Ty, b: Ty) Ty {
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

fn astTy(t: Ast.Type) Ty {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .integer,
        .string => .string,
    };
}

// ---------------------------------------------------------------------------
// Class 9 — elaboration (LRM ch6)
// ---------------------------------------------------------------------------

/// Entry point: elaborate the file (LRM §6.2.2), then lower what came out.
///
/// `elaborate.zig` owns "which module is the device, and what did the hierarchy
/// above it do to the names in it"; this owns "turn one unit's declarations and
/// analog blocks into MIR". The design is FLAT by construction — see that file's
/// header for why the MIR gains no hierarchy concept.
///
/// Elaboration is called from lowering rather than from the driver because its
/// input is the AST and its only consumer is the next line: a `Lower` field set
/// by root.zig would buy a second entry path and nothing else.
pub fn lowerFile(self: *Lower) Error!void {
    // The current backend only executes two-state analog equations. Preserve
    // full source literals in the AST, but never silently coerce them here.
    for (self.file.exprs.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .logic_literal) continue;
        const e: Ast.ExprId = @enumFromInt(i);
        const literal = self.file.exprs.logicValue(e);
        const span = self.tokenSpan(self.file.exprs.mainTok(e));
        try self.err(self.file.exprs.mainTok(e), .E0130, "`{s}`: the analog backend cannot execute this {d}-bit {s} literal", .{ self.src[span.start..span.end], literal.width, if (literal.hasUnknown()) "four-state" else "wide" });
    }
    if (self.had_error) return error.DiagnosticsReported;
    const design = try Elaborate.elaborate(.{
        .arena = self.arena,
        .file = self.file,
        .src = self.src,
        .tok_starts = self.tok_starts,
        .bag = self.bag,
    });
    self.hier_names = design.names;
    self.unit_paths = design.units; // §9.15 Table 9-28 / §9.16 sibling scope
    // IEEE 1364 §19.2 on §3.6.5's STRUCTURAL implicit nets, which is the half
    // elaboration made but could not judge. Before `lowerModule`, so a design
    // built on a mistyped instance terminal fails at the mistype instead of at
    // the E0337 the invented floating node would cause three phases later.
    for (design.implicit_nets) |n| try self.rejectImplicitNet(n.name, n.main_tok);
    self.unconnected_inputs = design.unconnected_inputs;
    try self.lowerModule(design.top);
    if (self.had_error) return error.DiagnosticsReported;
}

/// LRM §6.2/§6.9. Register ports (§6.5) into node_order, elaborate the
/// declarations, then lower each analog block (§5.2) in source order —
/// multiple analog blocks are executed as if concatenated (§6.9.1).
pub fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    self.module = module;
    self.mir.name = self.file.str(module.name);
    // IEEE 1364 §19.1 (§10.1 carries it over): the tag of the module keyword's
    // own position, which is what "modules between `celldefine and
    // `endcelldefine" means once the directives are positional regions.
    self.mir.is_cell = Preprocessor.CellRegion.inForce(self.cells, self.tokStart(module.main_tok), false);

    const entry = try self.mir.addBlock(self.arena);
    assert(entry == .entry);
    try self.builder.sealBlock(entry);
    self.cur = entry;

    try self.collectDisciplines(); // §3.6.1/§3.6.2 (annex D.1 is inlined here)
    try self.checkNatureTable(); // §3.6.1/§3.13 — the declaration table itself

    // §3.4 parameters BEFORE the ports, because a range is a constant
    // expression over them: §6.5.2.2's own example is `input [1:width] dt`
    // with `width` a module parameter, and `foldDim` cannot answer that from
    // an empty `consts`. Nothing in a parameter declaration can name a net —
    // §3.4 defaults are constant expressions — so the two orders differ only
    // in what is already known, never in what is reachable.
    for (module.params) |*p| try self.lowerParamDecl(p);

    // §6.5 ports first: this order IS the host device's terminal order.
    for (module.ports) |p| {
        // §3.6.3/§6.5.2 a vector port is N terminals, in declaration order.
        if (try self.portRange(&p)) |r| {
            const name = self.file.str(p.name);
            const disc = self.strOrEmpty(p.discipline);
            for (0..r.size()) |k| {
                const idx = try self.internNode(try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, r.at(@intCast(k)) }), disc);
                self.node_dir.items[idx] = p.direction;
            }
            try self.vectors.put(self.arena, name, r);
            continue;
        }
        const idx = try self.internNode(self.file.str(p.name), self.strOrEmpty(p.discipline));
        // §6.5.2.2. Recorded here and nowhere else: only a port can be
        // directional, and this loop is the only place the direction is known.
        self.node_dir.items[idx] = p.direction;
        // §1.3.4.1/§1.3.4.2's "not to `inout` ports" is NOT checked here, even
        // though the direction is: this line does not yet know the discipline.
        // See E0360, below the net loop, for where the rule lands and why it
        // cannot land any earlier.
    }
    self.num_ports = self.node_order.items.len;

    // §3.6.3 internal nets, then §3.6.4 ground.
    for (module.nets) |n| {
        const name = self.file.str(n.name);
        // §3.6.3 a vector net is N independent nets, scalarised here.
        //
        // ponytail: `n.init` is dropped on this path. §3.6.3.2's bus form is a
        // constant ARRAY expression with holes — `electrical [0:4] bus =
        // '{2.3,4.5,,6.0};`, where "a null value in the constant array
        // indicates that no nodeset value is being specified for this element"
        // — and A.8.1's assignment_pattern as this parser reads it has no null
        // element, so there is nothing to pair with `r.at(k)` yet. The upgrade
        // path is an empty slot in `parsePrimary`'s `'{ ... }` arm plus the
        // same `recordNodeset` call per element, keyed by position.
        if (n.range) |d| {
            if (try self.foldDim(d, n.main_tok)) |r| {
                for (0..r.size()) |k|
                    _ = try self.internNode(try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, r.at(@intCast(k)) }), self.strOrEmpty(n.discipline));
                try self.vectors.put(self.arena, name, r);
            }
            continue;
        }
        if (n.is_ground) {
            // §3.6.4 "Each ground declaration is associated with an already
            // declared net of continuous discipline. ... The net must be
            // assigned a continuous discipline to be declared ground." The
            // global reference node is the zero of a POTENTIAL, and §3.6.2.2
            // leaves a discrete discipline with no nature to have one.
            //
            // The discipline can come from either spelling — `ground <disc> g;`
            // carries it here, `<disc> g; ground g;` left it on the node the
            // earlier declaration interned.
            const dname = if (n.discipline != .none)
                self.file.str(n.discipline)
            else if (self.node_voltages.get(name)) |idx|
                (if (idx == ground) "" else self.node_disciplines.items[idx])
            else
                "";
            if (self.disciplines.get(dname)) |info| {
                if (info.is_discrete)
                    try self.err(n.main_tok, .E0344, "`{s}` is of discipline `{s}`, whose domain is discrete", .{ name, dname });
            }
            try self.node_voltages.put(self.arena, name, ground);
            continue;
        }
        // §7.4.4, printed again as step 3 of F.2.1/F.2.2: "More than one
        // conflicting discipline declaration from the same context ... is an
        // error. In this case, conflicting simply means an attempt to declare
        // more than one discipline regardless of whether the disciplines are
        // compatible or not." So the test is a SECOND declaration, not a
        // mismatch: two spellings of the same natures are equally illegal.
        //
        // This is the only site that can see a second one. A port is interned
        // once by the loop above, and parser.zig parseNetNames now leaves a net
        // entry behind when a body declaration re-disciplines a header port
        // instead of silently overwriting it, so both shapes arrive here.
        //
        // Both sides must be non-empty: §3.6.5 implicit nets and §3.9 undeclared
        // ports carry `""`, and a later declaration of one of those is the
        // FIRST declaration, not a conflict.
        if (n.discipline != .none) if (self.node_voltages.get(name)) |idx| {
            const had = if (idx == ground) "" else self.node_disciplines.items[idx];
            if (had.len != 0) {
                var b = self.errWith(n.main_tok, .E0902);
                b.msg("`{s}` is already of discipline `{s}`", .{ name, had });
                b.note("`{s}` would be its second, and §7.4.4 forbids a second declaration whether or not the two are compatible", .{self.file.str(n.discipline)});
                try b.emit();
                continue; // keep the FIRST declaration; do not silently overwrite it
            }
        };
        const idx = try self.internNode(name, self.strOrEmpty(n.discipline));
        // §3.6.3.2 the net_decl_assignment, folded. `consts` is already loaded
        // — the parameter loop runs above the port loop — so a nodeset written
        // over a parameter folds here and not later.
        if (n.init != .none) try self.recordNodeset(idx, n.init, n.main_tok, name);
    }

    // §7.4 discipline resolution, the one rule of it VerA implements: §10.2's
    // default. It runs HERE, after every declaration in the module has been
    // interned, and not at the intern itself — a port and a body declaration
    // of the same net are two entries (`module (p); inout p; electrical p;`),
    // and a default written in at the first would make the second a §7.4.4
    // "second discipline declaration" (E0902) on three fixtures that are
    // legal and green.
    //
    // A vector is scalarised by now, so the default has to be applied to the
    // ELEMENTS: `p` is not a node and `applyDefaultDiscipline` would find
    // nothing under it, leaving four natureless nets and four E0337s where
    // §10.2 supplied a discipline.
    for (module.ports) |p| try self.applyDefaultToAll(self.file.str(p.name), p.main_tok);
    for (module.nets) |n| try self.applyDefaultToAll(self.file.str(n.name), n.main_tok);

    // §1.3.4.1 "Nets of potential signal flow disciplines in modules may only
    // be bound to `input` or `output` ports of the module, not to `inout`
    // ports"; §1.3.4.2 says the same of flow signal-flow disciplines. The
    // sibling of E0425, which rules on the contribution TARGET rather than the
    // declaration.
    //
    // HERE and not in the port loop above, for two reasons that are the same
    // reason: the discipline is not known there. `inout p; voltage p;` splits
    // the direction and the discipline across two declarations — the port loop
    // interns `p` with `""` and the net loop supplies `voltage` — and §10.2's
    // default arrives later still, in the two `applyDefaultToAll` loops on the
    // lines above. This is the first point at which both halves of the rule's
    // one question are answered.
    //
    // `.unspecified` is deliberately not caught: §6.5.2 leaves a port with no
    // direction declaration to §3.9, and the clause names `inout` only.
    for (module.ports) |p| {
        if (p.direction != .inout) continue;
        const base = self.file.str(p.name);
        // A vector port is N nets sharing one declaration and therefore one
        // discipline (§6.5.2), so the first element answers for all of them and
        // the violation is reported once, at the declaration that commits it.
        var key_buf: [elem_key_len]u8 = undefined;
        const probe_name = if (self.vectors.get(base)) |r| try self.elemKey(&key_buf, base, &.{r.at(0)}) else base;
        const idx = self.node_voltages.get(probe_name) orelse continue;
        if (idx == ground) continue;
        const dname = self.node_disciplines.items[idx];
        if (!self.isSignalFlow(dname)) continue;
        var b = self.errWith(p.main_tok, .E0360);
        b.msg("`{s}` is an `inout` port of discipline `{s}`, which binds a {s} nature only", .{
            base, dname, if (self.disciplines.get(dname).?.has_potential) "potential" else "flow",
        });
        b.help("declare `{s}` as `input` or `output`", .{base});
        try b.emit();
    }

    // §3.6.3.2: "Nets with continuous disciplines are allowed to have
    // initializers on their net discipline declarations; however, nets of
    // non-continuous disciplines are not."
    //
    // HERE for the same reason E0360 is here and not at the declaration: a net
    // and its discipline can arrive in two declarations, and §10.2's default
    // arrives in the `applyDefaultToAll` loops above. A net that still has no
    // discipline at this point is left alone — it is §3.6.5's implicit net,
    // whose domain is decided by resolution (§7.4) and not by this module, and
    // E0337 already rules on it if anything analog touches it.
    for (self.nodesets.items) |ns| {
        const dname = self.node_disciplines.items[ns.node];
        const info = self.disciplines.get(dname) orelse continue;
        if (!info.is_discrete) continue;
        var b = self.errWith(ns.tok, .E0366);
        b.msg("`{s}` is of discipline `{s}`, whose domain is discrete", .{ self.node_order.items[ns.node], dname });
        b.note("a nodeset is an initial guess for a POTENTIAL, and §3.6.2.2 leaves a discrete discipline with no nature to have one", .{});
        try b.emit();
    }

    // §3.4 parameters were lowered above the port loop — in source order, so a
    // later default may still reference an earlier parameter (§6.3.4).
    // §3.4.7 aliasparam: a second name for an existing parameter.
    for (module.aliasparams) |a| {
        const target = self.file.str(a.target);
        const alias = self.file.str(a.alias);
        // §3.4.7 "The alias_identifier shall not occur anywhere else in the
        // module; in particular, it shall not conflict with a different
        // parameter_identifier". Unchecked, the `put` below REBINDS the
        // colliding name for the rest of the module: every equation that says
        // `alias` quietly reads `target` instead, and the model card's `alias`
        // field goes dead. Nothing else in the file looks wrong.
        if (!self.param_index.contains(alias) and try self.aliasSystemParam(alias, target)) continue;
        if (self.param_index.contains(alias)) {
            var b = self.errWith(module.main_tok, .E0331);
            b.msg("`{s}`", .{alias});
            b.help("an `aliasparam` gives `{s}` a second NAME, it does not declare a second parameter", .{target});
            try b.emit();
            continue;
        }
        if (self.param_index.get(target)) |idx| {
            try self.param_index.put(self.arena, alias, idx);
            try self.aliases.append(self.arena, .{ .name = alias, .param = idx });
        } else {
            var b = self.errWith(module.main_tok, .E0303);
            b.msg("`{s}`", .{target});
            if (diag.didYouMeanMap(target, self.param_index)) |s|
                b.help("did you mean `{s}`?", .{s});
            try b.emit();
        }
    }

    // §3.12 named branches.
    for (module.branches) |b| {
        const base = self.file.str(b.name);
        // A.2.3 `list_of_branch_identifiers ::= branch_identifier [ range ]
        // { , branch_identifier [ range ] }` — a branch ARRAY, several branches
        // over one declared terminal pair. Folded here and not in the parser
        // because the bounds are constant EXPRESSIONS (same reason as §6.5.2.2's
        // port ranges), and the elements are registered under their scalarised
        // names so `V(pair[1])` resolves through the ordinary branch lookup.
        const arr: ?VecRange = if (b.range) |d|
            (try self.foldDim(d, b.main_tok) orelse continue)
        else
            null;
        if (b.is_port_branch) {
            // §3.12.1 "A port branch is a special type of branch used to access
            // the flow into a port of a module (see 5.4.3). It is a branch
            // between the upper and lower connections of the port." Recorded as
            // the PORT and not as a node pair, because those two connections are
            // one node here: a pair would give the branch a potential that is
            // identically zero and a flow that is a second, unconstrained
            // unknown, neither of which is the quantity §5.4.3 names. The one
            // read that means anything is the flow, and it is the flow `I(<p>)`
            // already has — see `lowerBranchAccess`.
            const p = try self.nodeOf(b.hi);
            for (0..(if (arr) |r| r.size() else 1)) |k| {
                const key = if (arr) |r| try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, r.at(@intCast(k)) }) else base;
                try self.port_branches.put(self.arena, key, p);
            }
        } else if (arr) |r| {
            // A.2.3's branch ARRAY: the elements share one (hi, lo) and are
            // separate branches over it (§5.4.1 "any number of named branches
            // between any two signals"), so each takes its own identity and its
            // own accumulator — `br1[0]` and `br1[1]` are two sources.
            const hi = try self.nodeOf(b.hi);
            const lo = if (b.lo == .none) ground else try self.nodeOf(b.lo);
            try self.checkNetCompat(b.main_tok, hi, lo); // §3.12 → §3.11
            for (0..r.size()) |k|
                try self.branches.put(self.arena, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, r.at(@intCast(k)) }), .{
                    .hi = hi,
                    .lo = lo,
                    .id = self.newBranchId(),
                });
        } else if (self.vecTerminal(b.hi) != null or self.vecTerminal(b.lo) != null) {
            // §3.12 a branch with a vector terminal is a vector branch.
            try self.declareVectorBranch(&b);
            continue;
        } else {
            const hi = try self.nodeOf(b.hi);
            const lo = if (b.lo == .none) ground else try self.nodeOf(b.lo);
            // §3.12: "The disciplines for the specified nets shall be
            // compatible (see 3.11)." Only the two-terminal form has two
            // disciplines to compare — the one-terminal form's second net is
            // ground, and §3.12 says the branch then "derives" its discipline
            // from the one net that is named.
            try self.checkNetCompat(b.main_tok, hi, lo);
            try self.branches.put(self.arena, base, .{ .hi = hi, .lo = lo, .id = self.newBranchId() });
        }
        // The BASE name is a vector, so `V(pair)` and `V(pair[9])` get the
        // vector diagnostics (E0351/E0352) rather than interning an implicit
        // net — exactly as `declareVectorBranch` arranges for a vector terminal.
        if (arr) |r| try self.vectors.put(self.arena, base, r);
    }

    // §3.5 genvars exist only for unrolling; they carry no runtime storage.
    // §3.2/§3.3 module-level variables. The §5.10 scan runs FIRST: whether a
    // variable needs a persistent slot is decided at its declaration, not at
    // the assignment that reveals it — see `holdSlot`.
    try self.markHeldVars(module);
    try self.checkOneItemPerScope(module.vars);
    // A.6.2 the digital `initial` block, for the same reason and at the same
    // point as the §5.10 scan above: what a variable holds at the top of every
    // evaluation is decided at its declaration. `initial x = 3;` and
    // `integer x = 3;` therefore lower to one write, and the AST edit below is
    // the whole of the difference.
    try self.collectInitialState(module);
    for (module.vars) |*v| {
        var d = v.*;
        if (self.initial_state.get(self.file.str(d.name))) |a| {
            // §3.2.2 an array takes an assignment PATTERN, not a scalar, and
            // which element is which is the question a discrete kernel would be
            // answering. E0433 rather than §5.7's E0429 because the refusal is
            // about the block, not about the shapes.
            if (d.dims.len != 0)
                try self.err(a.tok, .E0433, "`{s}` is an array", .{self.file.str(d.name)})
            else
                d.init = a.value;
        }
        try self.declareVarDecl(&d, .module);
    }
    // §6.8: an `initial` block that assigns a name this module never declared.
    // Reported here because it is only knowable once every declaration is in —
    // and it has to be reported by somebody, since nothing else lowers the block.
    for (self.initial_state.keys(), self.initial_state.values()) |name, a| {
        if (!self.vars.contains(name) and !self.arrays.contains(name))
            try self.err(a.tok, .E0313, "`{s}`", .{name});
    }

    // §5.10.4 named events. An event carries no value — only "triggered at this
    // timepoint or not" — so one integer flag per event, zero on entry to every
    // evaluation, set by `-> ev` and tested by `@(ev)`.
    //
    // Deliberately NOT a `holdSlot` like an event-ASSIGNED variable: a trigger
    // is instantaneous. A flag that survived the timepoint would leave `@(ev)`
    // active at every later step, which is the opposite of §5.10's event model —
    // and the retained flag would never be cleared, since §5.10.4 gives no
    // "untrigger". The known ceiling of the fresh flag is the other order: a
    // detection that lexically PRECEDES its trigger reads 0 and does not run at
    // the following step either. Closing that needs a scheduler with a queue,
    // which the flat analog kernel has no place to put; §5.10.4's own example
    // (and every fixture) triggers first.
    for (module.events) |ev| {
        const place = self.builder.newPlace();
        try self.builder.writeVariable(place, self.cur, .zero);
        try self.events.put(self.arena, self.file.str(ev), place);
    }

    // §4.7.3 — checked on the DECLARATIONS, before any call site sees them.
    try self.checkFuncRecursion(module.functions);

    // §2.9/§2.9.2 — AFTER the declarations, because "constant expression" is a
    // question about the scopes, and BEFORE the analog block, so an attribute is
    // reported at its own token rather than after a body that may not compile.
    try self.checkAttributes(module.attrs);

    // §7.2.2 the DISCRETE context. Before the analog blocks because the rules
    // below relate the two, and it is the discrete side that names the variables
    // the continuous side is then judged against.
    try self.checkDiscreteContext(module);

    // §9.17.3 the user-function `$limit` state slots. BEFORE the body, because
    // each slot's previous-iterate read has to be seeded in the ENTRY block —
    // a site under an `if` must still leave a value the end-of-block read can
    // find, and a slot minted inside the arm would not dominate it.
    for (module.analog) |blk| try self.scanCallSites(blk.body, true, {}, {});

    // IEEE 1364 §19.10, also before the body and for a related reason: the pull
    // on an unconnected `input` is the OUTSIDE driving the port, so it is there
    // when the child's equations read it, not added after them.
    try self.applyUnconnectedDrive();

    // §5.2 analog blocks, concatenated (§6.9.1).
    for (module.analog) |blk| {
        self.cur_unit = blk.unit;
        if (blk.is_initial) {
            // §5.2.1 executed once per analysis, before a matrix solution
            // exists. Guarded rather than split into a second CFG so codegen
            // keeps ONE walk; the guard is a call codegen answers from a flag on
            // the Instance.
            //
            // NOT `initial_step`, and that is the whole of §5.2.1's second
            // sentence: "The analog initial block is executed once for each
            // analysis, and CAN BE EXECUTED FOR EACH SUB-TASK of parameter sweep
            // analysis (such as dc sweep). ... If a parameter or variable that is
            // referenced from an analog initial block is changed during a
            // sub-task of a parameter sweep analysis, then the analog initial
            // block SHALL BE RE-EXECUTED so that the new value is taken into
            // account." Table 5-1 makes `initial_step` the FIRST POINT of an
            // analysis, and a dc sweep is ONE analysis whose points are its
            // sub-tasks — so a body guarded on it runs at the first sweep point
            // and never again, which is the opposite of the "shall".
            const flag = try self.call("analog_initial", &.{});
            const prev = self.restrict;
            self.restrict = "an analog initial block";
            self.in_analog_initial = true;
            try self.lowerBranchStmt(flag, blk.body, .none, false);
            self.in_analog_initial = false;
            self.restrict = prev;
        } else {
            try self.lowerStmt(blk.body);
        }
    }

    // §5.6.1.3 the contribution accumulators' final values, and beside each the
    // final value of its retention flag — the "is a value retained [this
    // cycle]?" question the clause's three-way rule turns on.
    for (self.contributions.items, self.accum.items) |*c, acc| {
        c.resist_val = try self.builder.readVariable(acc.resist, self.cur);
        c.react_val = try self.builder.readVariable(acc.react, self.cur);
        c.wrote_val = try self.builder.readVariable(acc.wrote, self.cur);
    }
    // §5.10 the same, for every held variable. Reads only — no `call` — so the
    // unit enumeration below is untouched.
    for (self.held_vars.items) |*h| h.final = try self.builder.readVariable(h.place, self.cur);
    // §9.17.3 and the same again for every `$limit` state slot: the value the
    // last site on that access function returned this evaluation, or — if none
    // of them ran — the `$limit$old` seed, unchanged.
    for (self.limit_slots.items) |*s| s.final = try self.builder.readVariable(s.place, self.cur);

    // §9.17 analog kernel control. Emitted LAST and in this fixed order so the
    // unit enumeration stays a pure function of the source.
    try self.finishKernelCtl();
    // §9.4 display tasks. AFTER the kernel-control calls on purpose: those two
    // become naming units, and inserting anything ahead of them would renumber
    // every Instance state field. The display chain adds no unit of its own.
    // (Deferred §9.4.1 operands are lowered inside, after the accumulator
    // finals above — that read order is what "converged" means here.)
    try self.finishDisplays();
    if (self.table_effect_place) |p| self.table_effect = try self.builder.readVariable(p, self.cur);

    // AFTER `finishDisplays`: a deferred display operand appends its
    // `branch_reads` there, and §1.3.1's probe test has to see every read.
    try self.checkProbeBranches();
}

/// §9.17.1/§9.17.2. Turn each accumulated kernel-control place into exactly one
/// synthetic `call`, whose single argument is the value the host must read.
/// `naming.enumerateUnits` gives that call a unit; `codegen.emitStateMachine`
/// evaluates the unit once per accepted step and stores it into `Instance`.
fn finishKernelCtl(self: *Lower) Oom!void {
    if (self.reject_iteration_place) |p| self.reject_iteration = try self.builder.readVariable(p, self.cur);
    if (self.bound_step_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$bound_step", &.{v});
    }
    if (self.disc_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$discontinuity", &.{v});
    }
}

/// §9.4 Chain every unconditional display call into ONE value, so codegen has a
/// single live root to slice a unit from. `fadd` is the cheapest carrier: the
/// operands are what matters, the sum is discarded, and rendering the sum walks
/// the operands in MIR order — which is source order.
///
/// Only `cond_depth == 0` calls join. They lie on the straight-line spine of the
/// analog block, so each one dominates `self.cur` here; a call inside an `if`
/// arm does not, and chaining it would be invalid SSA as well as the wrong
/// semantics (§9.4.6). Those are reported by the driver as W0851.
fn finishDisplays(self: *Lower) Oom!void {
    try self.lowerDeferredDisplays();
    var root: Mir.Value = .f_zero;
    var first = true;
    for (self.displays.items) |d| {
        if (d.conditional) continue;
        // Every unconditional entry either carried its call from the
        // statement or was a `queueDisplay` placeholder just filled above.
        assert(d.val != .undef);
        root = if (first) d.val else try self.emit(.fadd, &.{ root, d.val });
        first = false;
    }
    self.display_root = root;
}

/// Fetch (creating on first use) a kernel-control place, seeded to +inf in the
/// entry block. `+inf` is the identity of `fmin` AND the correct "the model
/// asked for nothing" default for both tasks, so no separate "was it called"
/// flag has to survive the CFG.
fn kernelCtlPlace(self: *Lower, slot: *?Ssa.Place) Oom!Ssa.Place {
    if (slot.*) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_inf);
    slot.* = p;
    return p;
}

fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8 {
    return if (id == .none) "" else self.file.str(id);
}

// ---- §7.2.2 the discrete context -------------------------------------------

/// §7.2.2's two contexts, and the four rules the LRM states across them.
///
/// A `Ast.DiscreteBlock` is not lowered as CODE — an `always` block is refused
/// outright (E0205) and an `initial` block contributes only its constant results
/// (`collectInitialState`), because EXECUTING one needs an event queue and delta
/// cycles, which is a simulator and not a compiler pass. What is done here is the
/// other half: the LRM states rules ABOUT a discrete context, and while the
/// keyword was a hard syntax error not one of them could fire. All four are
/// decidable from the AST alone, which is why this is a scan and not a lowering:
///
///   §4.5.15  an analog operator "can not be used inside an initial or always
///            block"                                                  → E0422
///   §4.7.3   an analog function "shall only be called within the analog
///            context" (§7.3.7 states the mixed-signal half)           → E0430
///   §5.2.1   "digital values cannot be accessed from the analog initial
///            block"                                                   → E0431
///   §7.2.2   "It shall be an error to assign to a given variable in both
///            contexts"                                                → E0432
///
/// §7.2.2's first sentence is what makes the last two computable without a
/// digital engine: "The domain of a variable is that of the context from which
/// its value is assigned." So the set of ASSIGNMENT TARGETS in the discrete
/// blocks IS the set of digital-owned variables, and no `reg`-ness, no driver
/// state and no scheduler is needed to know it.
const DiscreteCtx = struct {
    /// Module-level variables assigned by a statement in an `initial` or
    /// `always` block → the token of the block that assigns it. Insertion
    /// ordered: two errors in one module must be reported in source order.
    assigned: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// This module's §4.7.1 analog function names.
    funcs: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Which block the scan is inside, for the E0422 wording (§4.5.15 names
    /// both spellings).
    where: []const u8 = "",
};

fn checkDiscreteContext(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    if (module.discrete.len == 0) return;

    var ctx: DiscreteCtx = .{};
    for (module.functions) |f| try ctx.funcs.put(self.arena, self.file.str(f.name), {});

    for (module.discrete) |blk| {
        ctx.where = if (blk.is_always) "an always block" else "an initial block";
        try self.scanContext(blk.body, true, blk.main_tok, &ctx);
    }
    // The continuous side second: §7.2.2's conflict and §5.2.1's read are both
    // "this analog statement, against what the discrete blocks own", so the
    // discrete set has to be complete first. §7.2.2 is symmetric, and reporting
    // it at the ANALOG statement is the choice the clause's own wording makes —
    // "the domain of a variable is that of the context from which its value is
    // assigned" gives the variable to whichever context is not the intruder, and
    // a module with a discrete block in it has already been told about that.
    for (module.analog) |blk| try self.scanContext(blk.body, false, blk.is_initial, &ctx);
}

/// A.6.2 `initial_construct ::= initial statement`, lowered — as far as it can
/// honestly be lowered by a compiler with no discrete kernel.
///
/// THE ONE SHAPE. A body of assignments of CONSTANT expressions to module
/// variables. §7.2.2's first sentence is what makes that shape complete rather
/// than a guess: "The domain of a variable is that of the context from which its
/// value is assigned", so the target belongs to the discrete context, and §7.2.2
/// then forbids the continuous context to assign it as well (E0432). The block
/// runs once before the analysis, nothing else ever writes the variable, and the
/// constant is therefore the value it holds for the whole analysis. §7.3.1
/// Table 7-1 is the rest of the story — how the continuous context READS it —
/// and for a `reg` the parser has already applied that table's `bit` row by
/// declaring the grouping as one integer.
///
/// So this records the expression and `lowerModule` installs it as the
/// variable's initial value, exactly where an A.2.2.1 declaration assignment
/// lands. No block is emitted, because there is no second point in time at which
/// it could run.
///
/// EVERYTHING ELSE IS E0433, and deliberately so rather than "unimplemented":
/// a delay or an event control has nothing to suspend on, a loop or a
/// conditional is only worth writing over values that change during the run, and
/// a non-constant right-hand side reads something no discrete kernel computed.
/// Each of those has several possible readings and the LRM picks between them
/// with §8.5's simulation cycle, which VerA does not have. Refusing is the
/// answer that cannot be silently wrong.
///
// ponytail: no event queue, no delta cycles, no drivers. The upgrade path is a
// discrete half in the engine, not a bigger version of this function — and if
// one ever lands, this stays as its constant-folding fast path.
fn collectInitialState(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.discrete) |blk| {
        // `always` is refused at the keyword (E0205, parser): it re-runs on an
        // event, so it has no constant reading to collect. Reporting its body
        // here as well would be a second diagnostic for one decision.
        if (blk.is_always) continue;
        try self.collectInitialStmt(blk.body);
    }
}

fn collectInitialStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .empty => {},
        // A.6.3 `seq_block` — transparent. Its own local declarations are not:
        // a name declared inside the block is not the module variable the
        // continuous context reads, so there is nothing to install.
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0)
                try self.err(self.file.stmtTok(id), .E0433, "a local declaration inside an initial block", .{});
            for (b.body) |s| try self.collectInitialStmt(s);
        },
        .assign => |a| {
            const tok = self.file.stmtTok(id);
            if (a.target == .none or ex.tag(a.target) != .ident) {
                // §3.2.2 `bus[i] = …`: the element is representable, but which
                // element is a question about a value, and the arrays this ever
                // applies to are the ones a digital kernel would drive.
                try self.err(tok, .E0433, "the assignment target is not a plain variable name", .{});
                return;
            }
            const name = self.file.str(ex.strOf(a.target));
            if (self.constEval(a.value) == null) {
                var b = self.errWith(tok, .E0433);
                b.msg("`{s}` is assigned a value that is not constant", .{name});
                b.note(
                    "an initial block runs once, before the analysis, so a value it computes " ++
                        "from anything the analysis produces does not exist yet",
                    .{},
                );
                try b.emit();
                return;
            }
            // Last assignment wins — the body is sequential, so a later one
            // overwrites an earlier one, and both overwrite an A.2.2.1
            // declaration assignment (which happens at elaboration, before this
            // block runs).
            try self.initial_state.put(self.arena, name, .{ .value = a.value, .tok = tok });
        },
        else => try self.err(
            self.file.stmtTok(id),
            .E0433,
            "only assignments of constant expressions are supported here",
            .{},
        ),
    }
}

/// Collect discrete §7.2.2 assignment targets, then check the continuous side
/// for both-context assignments and §5.2.1 digital reads in `analog initial`.
/// The context is compile-time: each walk keeps its own early exits and visits.
/// Runs only in a module that HAS a discrete block; ordinary analog pays nothing.
///
/// ponytail: a name declared in a NAMED BLOCK inside the discrete body shadows
/// the module-level one, and this scan does not model that — the
/// `self.vars.contains` filter is what keeps the false positive out, by only
/// ever recording a name the module itself declared. A block-local `integer x`
/// shadowing a module-level `real x` would still be recorded; give
/// `Ast.SeqBlock` a scope walk here if a model ever does that.
fn scanContext(self: *Lower, id: Ast.StmtId, comptime discrete: bool, context: if (discrete) u32 else bool, ctx: *DiscreteCtx) Oom!void {
    if (id == .none or (!discrete and ctx.assigned.count() == 0)) return;
    const is_initial = if (discrete) {} else context;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .assign => |a| {
            // The target of `bus[3] = ...` is the array, so walk down to the
            // base name — §7.2.2's domain is a property of the DECLARATION.
            var t = a.target;
            while (t != .none and (ex.tag(t) == .index or ex.tag(t) == .range)) t = ex.lhs(t);
            if (t != .none and ex.tag(t) == .ident) {
                const name = self.file.str(ex.strOf(t));
                if (discrete) {
                    if (self.vars.contains(name)) try ctx.assigned.put(self.arena, name, context);
                } else if (ctx.assigned.get(name)) |dtok| {
                    var b = self.errWith(self.file.exprs.mainTok(t), .E0432);
                    b.msg("`{s}`", .{name});
                    b.label(
                        self.tokenSpan(dtok),
                        "`{s}` is also assigned here, in the discrete context",
                        .{name},
                    );
                    try b.emit();
                }
            }
            try self.scanContextExpr(a.value, discrete, is_initial, ctx);
        },
        .block => |b| for (b.body) |s| try self.scanContext(s, discrete, context, ctx),
        .if_stmt => |s| {
            try self.scanContextExpr(s.cond, discrete, is_initial, ctx);
            try self.scanContext(s.then_s, discrete, context, ctx);
            try self.scanContext(s.else_s, discrete, context, ctx);
        },
        .case_stmt => |s| {
            try self.scanContextExpr(s.scrutinee, discrete, is_initial, ctx);
            for (s.arms) |arm| {
                for (arm.labels) |l| try self.scanContextExpr(l, discrete, is_initial, ctx);
                try self.scanContext(arm.body, discrete, context, ctx);
            }
        },
        .for_stmt => |s| {
            try self.scanContext(s.init, discrete, context, ctx);
            try self.scanContextExpr(s.cond, discrete, is_initial, ctx);
            try self.scanContext(s.step, discrete, context, ctx);
            try self.scanContext(s.body, discrete, context, ctx);
        },
        .while_stmt => |s| {
            try self.scanContextExpr(s.cond, discrete, is_initial, ctx);
            try self.scanContext(s.body, discrete, context, ctx);
        },
        .repeat_stmt => |s| {
            try self.scanContextExpr(s.count, discrete, is_initial, ctx);
            try self.scanContext(s.body, discrete, context, ctx);
        },
        .event_control => |s| {
            try self.scanContextExpr(s.event, discrete, is_initial, ctx);
            try self.scanContext(s.body, discrete, context, ctx);
        },
        .sys_task => |s| for (s.args) |a| try self.scanContextExpr(a, discrete, is_initial, ctx),
        // A contribution or an indirect contribution in a discrete block is
        // §5.6's own "the analog context" rule, not one of the four above, and
        // the block has already been refused. Nothing to add.
        .contribute => |s| if (!discrete) try self.scanContextExpr(s.rhs, discrete, is_initial, ctx),
        .indirect => |s| if (!discrete) try self.scanContextExpr(s.eqn, discrete, is_initial, ctx),
        .empty, .event_trigger, .disable, .jump => {},
    }
}

/// Every expression reachable from a context statement. The child edges are the
/// per-tag column usage documented on `Ast.ExprTag`; the `args` whitelist is the
/// set of tags whose `extra` is an ExprId list offset — the others park a literal
/// value or a StrId list there, and reading them as expressions would walk
/// garbage.
/// §5.2.1: "digital values cannot be accessed from the analog initial block as
/// they have not yet been assigned when the analog initial block is executed."
/// Only the READ is diagnosed, and only inside an `analog initial` — the same
/// read from the ordinary analog block is what §7.3.1 Table 7-1 is the
/// conversion table for.
fn scanContextExpr(self: *Lower, e: Ast.ExprId, comptime discrete: bool, is_initial: if (discrete) void else bool, ctx: *DiscreteCtx) Oom!void {
    if (e == .none or (!discrete and !is_initial)) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (discrete) {
        switch (tag) {
            // §4.5.15, verbatim: analog operators "can not be used inside an initial
            // or always block". Same code as the analog-function-body and
            // analog-initial cases, because it is the same sentence's family of
            // contexts: an operator carries state from one accepted timepoint to the
            // next, and none of these has a timepoint to advance.
            .filter_call => try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx.where}),
            .call => {
                const name = self.file.str(ex.strOf(e));
                if (ctx.funcs.contains(name)) {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0430);
                    b.msg("`{s}`", .{name});
                    b.note(
                        "an analog function shall only be called from an analog block " ++
                            "or from another analog function",
                        .{},
                    );
                    try b.emit();
                }
            },
            else => {},
        }
    } else if (tag == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0431);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(dtok), "`{s}` is assigned here, in the discrete context", .{name});
            try b.emit();
        }
    }
    try self.scanContextExpr(ex.lhs(e), discrete, is_initial, ctx);
    try self.scanContextExpr(ex.rhs(e), discrete, is_initial, ctx);
    if (tag == .ternary) try self.scanContextExpr(ex.ternaryElse(e), discrete, is_initial, ctx);
    switch (tag) {
        .call,
        .builtin_call,
        .sys_call,
        .filter_call,
        .noise_call,
        .event_function,
        .concat,
        .assign_pattern,
        => for (ex.args(e)) |a| try self.scanContextExpr(a, discrete, is_initial, ctx),
        else => {},
    }
}

// ---- §3.6 disciplines & natures --------------------------------------------

/// Build the discipline table and the §3.6.1.4 access-name map. The
/// preprocessor inlines annex D.1, so `electrical`/`thermal`/… arrive as
/// ordinary declarations in `file.disciplines`.
fn collectDisciplines(self: *Lower) Oom!void {
    // §4.4 the two standard access identifiers always resolve.
    try self.access_kind.put(self.arena, "V", .potential);
    try self.access_kind.put(self.arena, "I", .flow);
    // §5.5.1 Syntax 5-3 / §4.4 the GENERIC access functions, which resolve on
    // every discipline that binds the half they name. Registering them here
    // rather than in a parallel table is what makes them "an alternative
    // spelling": everything downstream — `branchOf`, `contribIndex`,
    // `resolveLvalue`, the E0501/E0337 checks — sees an `Access` and cannot
    // tell which word produced it. The single exemption is the §3.6.1.4 name
    // match in `checkAccessMatch`.
    try self.access_kind.put(self.arena, generic_potential, .potential);
    try self.access_kind.put(self.arena, generic_flow, .flow);

    for (self.file.disciplines) |*d| {
        var info: DisciplineInfo = .{
            .is_discrete = d.domain == .discrete,
            .has_potential = d.potential != .none,
            .has_flow = d.flow != .none,
        };
        // §3.6.2.1 "Conservative disciplines shall not have the same nature
        // specified for both the potential and the flow." The same clause makes
        // each nature's `access` the access function of its half, so one nature
        // on both bindings gives one NAME two meanings — and `access_kind`
        // below would keep whichever of the two it saw last.
        if (info.has_potential and d.potential == d.flow)
            try self.err(d.main_tok, .E0338, "`{s}` binds `{s}` to both its potential and its flow", .{
                self.file.str(d.name), self.file.str(d.potential),
            });
        // §3.6.2.2 "It is an error for a discipline to have a domain binding of
        // discrete if it has nature bindings." Either half is enough; a
        // discrete net is solved by the digital kernel, which has no continuous
        // quantity for the nature to describe.
        if (info.is_discrete and (info.has_potential or info.has_flow))
            try self.err(d.main_tok, .E0339, "`{s}` declares `domain discrete` and binds a nature", .{
                self.file.str(d.name),
            });
        if (d.potential != .none) {
            const n = self.natureOf(d.potential);
            if (n.abstol) |a| info.potential_abstol = a;
            if (n.access) |acc| {
                info.potential_access = acc;
                try self.access_kind.put(self.arena, acc, .potential);
            }
        }
        if (d.flow != .none) {
            const n = self.natureOf(d.flow);
            if (n.abstol) |a| info.flow_abstol = a;
            if (n.access) |acc| {
                info.flow_access = acc;
                try self.access_kind.put(self.arena, acc, .flow);
            }
        }
        // §3.6.2.3 discipline-level attribute overrides win over the nature's.
        for (d.overrides) |o| {
            if (!std.mem.eql(u8, self.file.str(o.attr.name), "abstol")) continue;
            const v = self.constEval(o.attr.value) orelse continue;
            switch (o.which) {
                .potential => info.potential_abstol = v.asReal(),
                .flow => info.flow_abstol = v.asReal(),
            }
        }
        try self.disciplines.put(self.arena, self.file.str(d.name), info);
    }
}

/// §3.6.1/§3.6.1.2/§3.13 — the rules the nature+discipline TABLE has to satisfy
/// on its own, before a module refers to any of it. One pass, because all of
/// them read the same two declaration lists.
///
/// WHY THE UNIQUENESS RULES ARE PER-FILE. §3.13.1 gives natures and disciplines
/// one global scope, but VerA prepends annex D's `disciplines.vams` to EVERY
/// compilation whether or not the source included it. A model that declares its
/// own `nature My_Voltage; access = V;` never asked for annex D's `Voltage`, so
/// comparing across the prelude would reject it for a declaration its author did
/// not write. Within one file the comparison is exactly §3.13.1's.
fn checkNatureTable(self: *Lower) Oom!void {
    const natures = self.file.natures;
    // §3.6.1.4 access identifier per nature, `.none` when it declares no
    // `access` of its own (a derived nature inherits it — §3.6.1.2).
    const access = try self.arena.alloc(Ast.StrId, natures.len);

    for (natures, access) |*n, *acc| {
        var abstol: bool = false;
        var units: u32 = Mir.no_tok;
        acc.* = .none;
        var acc_tok: u32 = Mir.no_tok;
        for (n.attrs, 0..) |a, ai| {
            const an = self.file.str(a.name);
            // §3.6.1.3 "The name of the attribute shall be unique in the nature
            // being defined". Two values for one name leave `<nature>.<attr>`
            // with no single reading — and the LAST one silently winning is
            // exactly the failure mode that has no symptom.
            // ponytail: O(n²) over the handful of attributes one nature has.
            for (n.attrs[0..ai]) |prev| {
                if (prev.name != a.name) continue;
                try self.err(a.main_tok, .E0343, "`{s}` is already an attribute of `{s}`", .{
                    an, self.file.str(n.name),
                });
                break;
            }
            try self.checkNatureAttrValue(n, a, an);
            if (std.mem.eql(u8, an, "abstol")) {
                abstol = true;
            } else if (std.mem.eql(u8, an, "units")) {
                units = a.main_tok;
            } else if (std.mem.eql(u8, an, "access")) {
                acc_tok = a.main_tok;
                if (self.file.exprs.tag(a.value) == .ident) acc.* = self.file.exprs.strOf(a.value);
            }
        }
        const name = self.file.str(n.name);
        if (n.parent == .none) {
            // §3.6.1: a nature definition "shall include all the required
            // attributes specified in 3.6.1.2"; that clause says of abstol,
            // access and units alike that each "is required for all base
            // natures". A nature meaning to inherit them says so with a parent.
            const missing: []const u8 = if (!abstol)
                "abstol"
            else if (acc_tok == Mir.no_tok)
                "access"
            else if (units == Mir.no_tok)
                "units"
            else
                "";
            if (missing.len != 0) {
                var b = self.errWith(n.main_tok, .E0332);
                b.msg("`{s}` has no `{s}`", .{ name, missing });
                b.help("or derive it from a base nature: `nature {s} : <parent>;`", .{name});
                try b.emit();
            }
        } else {
            if (units != Mir.no_tok) try self.err(units, .E0333, "`{s}`", .{name});
            if (acc_tok != Mir.no_tok) try self.err(acc_tok, .E0334, "`{s}`", .{name});
        }
    }

    // §3.6.1.2 idt_nature "shall be the name (not a string) of a nature which
    // is defined elsewhere", and a derived nature that overrides it "shall be
    // related (share the same base nature) to the nature the parent uses".
    // Both halves are one code: the integral's tolerance comes from that
    // nature, and a name that resolves to nothing and a name that resolves to
    // an unrelated quantity leave it equally undefined.
    for (natures) |*n| {
        const own = for (n.attrs) |a| {
            if (std.mem.eql(u8, self.file.str(a.name), "idt_nature")) break a;
        } else continue;
        // A non-identifier value is E0340's report, not a second one here.
        if (self.file.exprs.tag(own.value) != .ident) continue;
        const target = self.file.exprs.strOf(own.value);
        const target_base = self.baseNatureOf(target);
        if (target_base == .none) {
            try self.err(own.main_tok, .E0341, "`{s}` is not a declared nature", .{self.file.str(target)});
            continue;
        }
        if (n.parent == .none) continue;
        const inherited = self.idtNatureOf(n.parent);
        if (inherited == .none or self.baseNatureOf(inherited) == target_base) continue;
        var b = self.errWith(own.main_tok, .E0341);
        b.msg("`{s}` is not related to `{s}`", .{ self.file.str(target), self.file.str(inherited) });
        b.note("`{s}` derives from `{s}`, whose `idt_nature` is `{s}`; an override shares its base nature", .{
            self.file.str(n.name), self.file.str(n.parent), self.file.str(inherited),
        });
        try b.emit();
    }

    // §3.13.2 "the access function of each base nature shall be unique". Keyed
    // on the nature NAME, so one nature declared twice (annex D's own headers
    // arrive that way when a fixture restates them) is one claim, not two.
    for (natures, access, 0..) |*a, a_acc, i| {
        if (a.parent != .none or a_acc == .none) continue;
        for (natures[i + 1 ..], access[i + 1 ..]) |*b, b_acc| {
            if (b.parent != .none or b_acc != a_acc or b.name == a.name) continue;
            if (self.fileOf(a.main_tok) != self.fileOf(b.main_tok)) continue;
            try self.err(b.main_tok, .E0335, "`{s}` and `{s}` both access `{s}`", .{
                self.file.str(a.name), self.file.str(b.name), self.file.str(b_acc),
            });
        }
    }

    // §3.13.1 natures and disciplines share ONE global scope.
    for (natures) |*n| {
        for (self.file.disciplines) |*d| {
            if (d.name != n.name or self.fileOf(d.main_tok) != self.fileOf(n.main_tok)) continue;
            try self.err(d.main_tok, .E0336, "`{s}` is already a nature", .{self.file.str(d.name)});
        }
    }

    // §3.6.1/§3.6.2 same-KIND duplicates. E0336 above is the cross-kind case
    // only, and a name declared twice as the same kind is the one that has no
    // symptom: `disciplines`/the nature walk keep the last, so every net of the
    // name silently gets the second declaration's access functions.
    // Same per-file scoping as E0335, and for the same reason (see the header).
    for (natures, 0..) |*a, i| {
        for (natures[i + 1 ..]) |*b| {
            if (b.name != a.name or self.fileOf(a.main_tok) != self.fileOf(b.main_tok)) continue;
            try self.err(b.main_tok, .E0342, "nature `{s}` is already declared", .{self.file.str(b.name)});
        }
    }
    for (self.file.disciplines, 0..) |*a, i| {
        for (self.file.disciplines[i + 1 ..]) |*b| {
            if (b.name != a.name or self.fileOf(a.main_tok) != self.fileOf(b.main_tok)) continue;
            try self.err(b.main_tok, .E0342, "discipline `{s}` is already declared", .{self.file.str(b.name)});
        }
    }
}

/// §3.6.1.2/§3.6.1.3 — the FORM each attribute's value has to take. The LRM
/// spells three of them out and then makes one blanket statement about the
/// rest, so this is four arms and not a table.
///
/// The identifier/string distinction is one character wide and means two
/// different things: `access = V` introduces a callable name into every module
/// that uses the discipline, `access = "V"` is a value nothing can call.
fn checkNatureAttrValue(self: *Lower, n: *const Ast.NatureDecl, a: Ast.NatureAttr, an: []const u8) Oom!void {
    const tag = self.file.exprs.tag(a.value);
    // §3.6.1.2: `access` "shall be an identifier (by name, not as a string)";
    // idt_nature/ddt_nature take "the name (not a string) of a nature".
    const wants_ident = std.mem.eql(u8, an, "access") or
        std.mem.eql(u8, an, "idt_nature") or
        std.mem.eql(u8, an, "ddt_nature");
    if (wants_ident) {
        if (tag != .ident) try self.err(a.main_tok, .E0340, "`{s}` of `{s}` must be an identifier, not a value", .{
            an, self.file.str(n.name),
        });
        return;
    }
    // §3.6.1.2: `units` "shall be a string" — §3.11.1's Units Value Rule
    // compares two natures on it, which needs one comparable spelling.
    if (std.mem.eql(u8, an, "units")) {
        if (tag != .str_literal) try self.err(a.main_tok, .E0340, "`units` of `{s}` must be a string", .{
            self.file.str(n.name),
        });
        return;
    }
    // §3.6.1.3 everything else — abstol included — "shall be constant". A
    // nature is declared at source-text level (§3.13.1), outside every module,
    // so there is no scope here in which a runtime name could resolve.
    if (self.constEval(a.value) == null)
        try self.err(a.main_tok, .E0340, "`{s}` of `{s}` is not a constant expression", .{
            an, self.file.str(n.name),
        });
}

/// §3.11.1 Derived Nature Rule — the base a (possibly derived) nature bottoms
/// out at. Two natures are RELATED when this answers the same name for both.
/// `.none` when the name resolves to no nature at all.
fn baseNatureOf(self: *const Lower, name: Ast.StrId) Ast.StrId {
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (self.file.natures) |*n| {
            if (n.name == want) break n;
        } else return if (hops == 0) .none else want;
        if (nat.parent == .none) return want;
        if (nat.parent_access) |half| {
            const d = for (self.file.disciplines) |*x| {
                if (x.name == nat.parent) break x;
            } else return want;
            const bound = switch (half) {
                .potential => d.potential,
                .flow => d.flow,
            };
            if (bound == .none) return want;
            want = bound;
        } else want = nat.parent;
    }
    return want;
}

/// The `idt_nature` a nature ends up with, its own or an inherited one.
fn idtNatureOf(self: *const Lower, name: Ast.StrId) Ast.StrId {
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (self.file.natures) |*n| {
            if (n.name == want) break n;
        } else return .none;
        for (nat.attrs) |a| {
            if (std.mem.eql(u8, self.file.str(a.name), "idt_nature") and
                self.file.exprs.tag(a.value) == .ident)
                return self.file.exprs.strOf(a.value);
        }
        if (nat.parent == .none) return .none;
        if (nat.parent_access != null) return .none;
        want = nat.parent;
    }
    return .none;
}

/// Which source file a token came from (§3.13.1 scope comparisons). The
/// preprocessor's segment map is the only thing that still knows: by lowering,
/// the prelude and the user's text are one byte stream.
fn fileOf(self: *const Lower, tok: u32) diag.FileId {
    return self.bag.locate(self.tokenSpan(tok), null).file;
}

const NatureAttrs = struct {
    abstol: ?f64 = null,
    access: ?[]const u8 = null,
    /// §3.6.1.2 `units`, read for §3.11.1's Units Value Rule — the one rule
    /// that relates two natures with no derivation between them.
    units: ?[]const u8 = null,
};

/// §3.6.1.1 walk a (possibly derived) nature for `abstol` (§3.6.1.2),
/// `access` (§3.6.1.4) and `units` (§3.6.1.2). Derived natures inherit what
/// they do not override.
fn natureOf(self: *Lower, name: Ast.StrId) NatureAttrs {
    var out: NatureAttrs = .{};
    // ponytail: share the AST's 16-hop walk; extend it there if deeper inheritance is needed.
    if (self.file.natureAttrExpr(name, "abstol")) |v| {
        if (self.constEval(v)) |c| out.abstol = c.asReal();
    }
    if (self.file.natureAttrExpr(name, "access")) |v| {
        if (self.file.exprs.tag(v) == .ident) out.access = self.file.str(self.file.exprs.strOf(v));
    }
    if (self.file.natureAttrExpr(name, "units")) |v| {
        if (self.file.exprs.tag(v) == .str_literal) out.units = self.file.str(self.file.exprs.strOf(v));
    }
    return out;
}

// ---- §3.11 net compatibility -----------------------------------------------

/// §3.11.1's five NATURE rules, in the order that makes each one's job visible.
///
///   Non-Existent Binding Rule  "A nature is compatible with a non-existent
///                              discipline binding."
///   Self Rule (Nature)         "A nature is compatible with itself."
///   Base Nature Rule           "A derived nature is compatible with its base."
///   Derived Nature Rule        "Two natures are compatible if they are derived
///                              from the same base nature."
///   Units Value Rule           "Two natures are compatible if they have the
///                              same value for the units attribute."
///
/// The Non-Existent Binding Rule is also what makes §3.11.1's Natureless
/// Discipline Rule fall out with no arm of its own: a discipline that binds no
/// nature is `.none` on both halves, so it conflicts with nobody.
fn naturesCompatible(self: *Lower, a: Ast.StrId, b: Ast.StrId) bool {
    if (a == .none or b == .none) return true;
    if (a == b) return true;
    // The Base and Derived Nature Rules are ONE comparison: `baseNatureOf`
    // answers a base nature with itself, so "derived from its base" and
    // "derived from a common base" are the same equality.
    const base = self.baseNatureOf(a);
    if (base != .none and base == self.baseNatureOf(b)) return true;
    const ua = self.natureOf(a).units orelse return false;
    const ub = self.natureOf(b).units orelse return false;
    return std.mem.eql(u8, ua, ub);
}

/// §3.6.2.2 the domain a discipline is IN, or null when it is domainless.
///
/// `unspecified` is not the same answer as domainless. §3.11.1's own worked
/// example says so: "electrical and continuous_elec are compatible disciplines
/// because the DEFAULT domain for discipline electrical is continuous" —
/// electrical declares no `domain` attribute and is still continuous, because
/// it binds natures. Only a discipline that declares no domain AND binds
/// nothing is the deprecated `domainless` of that same example.
fn domainOf(d: *const Ast.DisciplineDecl) ?Ast.DisciplineDecl.Domain {
    return switch (d.domain) {
        .continuous, .discrete => d.domain,
        .unspecified => if (d.potential != .none or d.flow != .none) .continuous else null,
    };
}

fn disciplineDecl(self: *const Lower, name: []const u8) ?*const Ast.DisciplineDecl {
    for (self.file.disciplines) |*d| {
        if (std.mem.eql(u8, self.file.str(d.name), name)) return d;
    }
    return null;
}

/// §3.11.1's DISCIPLINE rules. Null when the two are compatible; otherwise the
/// rule that refuses them, worded for the diagnostic's note.
///
///   Self Rule (Discipline)       "A discipline is compatible with itself."
///   Domainless Discipline Rule   "compatible with all disciplines as there is
///                                no nature or domain conflict."
///   Domain Incompatibility Rule  "Disciplines with different domain attributes
///                                are incompatible."
///   Potential / Flow Incompatibility Rules — deferred to `naturesCompatible`.
fn disciplineConflict(self: *Lower, an: []const u8, bn: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, an, bn)) return null;
    const a = self.disciplineDecl(an) orelse return null;
    const b = self.disciplineDecl(bn) orelse return null;
    const da = domainOf(a) orelse return null;
    const db = domainOf(b) orelse return null;
    const unrelated = "neither the same nature, nor derived from a common base nature, nor agreed on `units`";
    if (da != db)
        return "3.11.1 Domain Incompatibility Rule: disciplines with different domain attributes are incompatible; 3.11 says such nets need a `connect` statement (7.4)";
    if (!self.naturesCompatible(a.potential, b.potential))
        return "3.11.1 Potential Incompatibility Rule: the two potential natures are " ++ unrelated;
    if (!self.naturesCompatible(a.flow, b.flow))
        return "3.11.1 Flow Incompatibility Rule: the two flow natures are " ++ unrelated;
    return null;
}

/// §3.11: "Certain operations can be done on nets only if the two (or more)
/// nets are compatible. For example, if an access function has two nets as
/// arguments, they must be compatible." §3.12 states the same requirement for
/// the two terminals of a branch declaration, and §7.4.3 for a continuous-time
/// port connection — one rule (§3.11.1), so one helper and one code.
fn checkNetCompat(self: *Lower, tok: u32, hi: u16, lo: u16) Oom!void {
    // §1.3.1.1 collapses every ground onto one global reference node, which is
    // not a second NET the rule can be about: `V(p)` is `V(p, gnd)` and spans
    // one discipline.
    if (hi == ground or lo == ground) return;
    const an = self.node_disciplines.items[hi];
    const bn = self.node_disciplines.items[lo];
    // A net with no discipline at all is E0337's, not this rule's: §3.11
    // compares two disciplines and here there is only one.
    if (an.len == 0 or bn.len == 0) return;
    const why = self.disciplineConflict(an, bn) orelse return;
    var d = self.errWith(tok, .E0355);
    d.msg("`{s}` is of discipline `{s}` and `{s}` is of discipline `{s}`", .{
        self.nodeName(hi), an, self.nodeName(lo), bn,
    });
    d.note("{s}", .{why});
    try d.emit();
}

// ---- §1.3.1 nodes ----------------------------------------------------------

/// §1.3.4 — is `dname` a SIGNAL-FLOW discipline? Exactly one of the two natures
/// is bound, so the net carries one quantity and no conservation law relates it
/// to anything (§3.6.2.1 makes the both-natures case conservative instead).
///
/// The exclusive-or matters. codegen.zig flowOnlySignalFlowNet asks the
/// narrower `flow and no potential`, which is right for the question IT asks —
/// "is this node's one unknown a flow?" — but a natureless `domain continuous`
/// discipline (§3.11.1) and a
/// `domain discrete` one bind NEITHER nature, and neither is a signal-flow
/// discipline. §1.3.4.1/§1.3.4.2 say "potential signal flow" and "flow
/// signal-flow" disciplines, which is one nature, present.
fn isSignalFlow(self: *const Lower, dname: []const u8) bool {
    if (dname.len == 0) return false;
    const d = self.disciplines.get(dname) orelse return false;
    return d.has_potential != d.has_flow;
}

/// §10.2 + §7.4. "The default discipline is applied by discipline resolution
/// (see 7.4 and Annex F) to all discrete signals without a discipline
/// declaration that appear in the text stream following the use of the
/// `default_discipline directive." So: only a net that still has none, and
/// only a directive that precedes the net's own declaration.
///
/// The QUALIFIER selects which nets a default claims, which is why more than
/// one can be in force "provided each differs in qualifier", and why §10.2's
/// precedence sentence ("the more specific directives have higher precedence")
/// makes a qualified default beat an unqualified one. Every net that reaches
/// this point is a plain net, hence `wire` by IEEE Std 1364 §3.5's default
/// nettype — VerA has no `real`/`wreal` net declarations at all (E0205) and a
/// `reg` is one §3.2 integer VARIABLE rather than a net (§7.3.1 Table 7-1's own
/// mapping), so `wire` and the unqualified form are the only two keys that can
/// match.
/// ponytail: widen the key to the net's declared data type when those land.
/// The same, for a declaration that may be a §3.6.3 vector: the default is
/// written onto each scalarised element, since the base name is not a node.
fn applyDefaultToAll(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    const r = self.vectors.get(name) orelse
        return self.applyDefaultDiscipline(name, main_tok);
    var key_buf: [elem_key_len]u8 = undefined;
    for (0..r.size()) |k|
        try self.applyDefaultDiscipline(try self.elemKey(&key_buf, name, &.{r.at(@intCast(k))}), main_tok);
}

fn applyDefaultDiscipline(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (self.default_disciplines.len == 0) return;
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    if (self.node_disciplines.items[idx].len != 0) return;
    if (main_tok >= self.tok_starts.len) return;
    const at = self.tok_starts[main_tok];

    // Backwards from the declaration: the most recent directive wins, and a
    // wire-qualified one wins over an unqualified one however old it is.
    var fallback: ?[]const u8 = null;
    var i = self.default_disciplines.len;
    const chosen = while (i > 0) {
        i -= 1;
        const e = self.default_disciplines[i];
        if (e.at > at) continue;
        // §10.2: the bare form and `resetall withdraw the default outright,
        // so nothing older than one of those is still in force.
        if (e.discipline.len == 0) break fallback;
        if (std.mem.eql(u8, e.qualifier, "wire")) break e.discipline;
        if (e.qualifier.len == 0 and fallback == null) fallback = e.discipline;
    } else fallback;

    const dname = chosen orelse return;
    // A default naming a discipline that was never declared supplies no
    // nature, so leaving the net bare is the honest outcome: E0337 then says
    // the net has no discipline, which is exactly what happened.
    if (!self.disciplines.contains(dname)) return;
    self.node_disciplines.items[idx] = dname;
}

/// IEEE 1364 §19.2 `` `default_nettype none ``, on a name that is about to
/// become a §3.6.5 implicit net. A no-op under every other net type: the
/// directive picks the TYPE an implicit net has, and VerA's analog nets have no
/// type to pick — §3.6 gives a net a DISCIPLINE, which is §10.2's directive and
/// a different question. `none` is the member that says something this engine
/// can act on, because it says the implicit net may not exist at all.
///
/// ponytail: the other ten values are accepted and dropped. The ceiling is real
/// and it is the digital kernel's — `wand`/`wor`/`trireg`/`tri0` differ only in
/// how MULTIPLE DRIVERS resolve, and VerA has no driver-resolution model to
/// differ in. Upgrade path is the discrete net type on `Ast.NetDecl`, at which
/// point this function stops discarding the value and starts stamping it.
fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    if (Preprocessor.NetTypeRegion.inForce(self.nettypes, self.tokStart(main_tok), .default) != .none) return;
    var b = self.errWith(main_tok, .E0367);
    b.msg("`{s}` was never declared, and `default_nettype none is in force", .{name});
    b.note("§3.6.5 would make it an implicit net; IEEE 1364 §19.2's `none` is what withdraws that", .{});
    b.help("declare it — `electrical {s};` — or go back to `default_nettype wire", .{name});
    try b.emit();
}

/// IEEE 1364 §19.10 on the internal nets §6.2.2 gave the unconnected `input`
/// ports. Run after the declarations are interned and before the analog blocks
/// lower, which is the order the rule reads in: the port arrives already driven,
/// and the child's equations then see whatever the drive put there.
///
/// WHAT A PULL IS HERE. §19.10 pulls a digital net to a logic level through a
/// `pull`-strength driver. The analog kernel has neither logic levels nor
/// strengths, and it has exactly one way of saying "driven to a level": a
/// potential source between the node and the reference. So `pull0` holds the
/// port at 0 and `pull1` at 1, in the units of its discipline's potential
/// nature — and the half that DISCRIMINATES is not the number, it is the
/// source: an unconnected input under `nounconnected_drive is a floating
/// unknown that KCL gives zero current, and under either pull it is a driven
/// node that current flows into.
///
/// ponytail: 1.0 is the ceiling. §19.10's `pull1` is strength Pu1 on a
/// four-state net, not one volt, and a discipline whose potential is a
/// temperature or a pressure has no reason for its logic 1 to be 1. The upgrade
/// path is the discrete kernel's net resolution, where a pull is a driver among
/// drivers and this stops being a potential at all; until there is one, a
/// number that is right for `logic` and honest about being a number beats
/// recording the directive and doing nothing with it.
///
/// Skipped on a net whose discipline binds no potential (§3.6.2.2 discrete, or
/// none at all): there is nothing to hold it at, and inventing a source would
/// turn a directive into an E0501 about an access function the model never
/// wrote.
fn applyUnconnectedDrive(self: *Lower) Oom!void {
    if (self.drives.len == 0) return;
    for (self.unconnected_inputs) |site| {
        const drive = Preprocessor.DriveRegion.inForce(self.drives, self.tokStart(site.main_tok), .default);
        if (drive == .float) continue;
        const idx = self.node_voltages.get(site.name) orelse continue;
        if (idx == ground) continue;
        const info = self.disciplines.get(self.node_disciplines.items[idx]) orelse continue;
        if (!info.has_potential) continue;
        const target: Target = .{ .access = .potential, .hi = idx, .lo = ground };
        const acc = self.accum.items[try self.contribIndex(target, site.main_tok)];
        const old = try self.builder.readVariable(acc.resist, self.cur);
        const level: Mir.Value = if (drive == .pull1) .f_one else .f_zero;
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, level }));
        // §5.6.1.3: the source is retained on every path, the same as an
        // unconditional `<+` — there is no path on which an unconnected port
        // stops being unconnected.
        try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    }
}

/// Register (or find) a node. Undeclared names are implicit nets (§3.6.5), so
/// this never fails; registration order is source order ⇒ deterministic.
fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u16 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.node_disciplines.items[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx = try self.appendNode(name, discipline, .net);
    gop.value_ptr.* = idx;
    return idx;
}

/// §3.6.3.2 fold one net_decl_assignment into a nodeset value for `node`.
///
/// "The initializer shall be a constant_expression" — so a fold that fails IS
/// the rule, and E0365 is it. `constEval` looks through parameters, which is
/// what the clause wants: §3.4 makes a parameter reference a constant
/// expression, and `electrical n = vstart;` is the form a model card tunes.
///
/// A string folds to 0.0 through `asReal()` and is not separately diagnosed: a
/// nodeset is a potential, `parameter string` cannot be one, and the value it
/// lands on is the same 0.0 the unknown starts at without any nodeset at all.
///
/// ponytail: the value is frozen at the fold, so a nodeset written over a
/// parameter keeps the parameter's DECLARED default even after a model card
/// overrides it — a stale initial guess, never a wrong answer, since §3.6.3.2
/// only feeds the solver's starting point. The upgrade path is the §6.3.4
/// `derive()` shape: keep the `Ast.ExprId`, render it with codegen's
/// `f64Const`, and export `nodeset(model)` instead of a comptime table.
fn recordNodeset(self: *Lower, node: u16, e: Ast.ExprId, tok: u32, name: []const u8) Oom!void {
    const c = self.constEval(e) orelse {
        var b = self.errWith(tok, .E0365);
        b.msg("the initializer of `{s}` is not a constant expression", .{name});
        b.note("§3.6.3.2 gives it to the analog solver as a nodeset value for the potential of `{s}`, which is fixed before the solve starts", .{name});
        try b.emit();
        return;
    };
    try self.nodesets.append(self.arena, .{ .node = node, .value = c.asReal(), .tok = tok });
}

/// The one place a `node_order` slot is created: it fixes the slot's KIND and
/// its SPELLING together, which is the split this table exists to keep. Every
/// caller owns the IDENTITY question itself (`node_voltages` for a net,
/// `flow_unknowns` for a branch, `port_probes` for a port) — this function does
/// not dedupe and must not, since two distinct unknowns may ask for one name.
fn appendNode(self: *Lower, name: []const u8, discipline: []const u8, kind: NodeKind) Oom!u16 {
    const idx: u16 = @intCast(self.node_order.items.len);
    assert(idx != ground);
    const spelling = try self.uniqueSpelling(name);
    try self.spellings.put(self.arena, spelling, {});
    try self.node_order.append(self.arena, spelling);
    try self.node_kind.append(self.arena, kind);
    try self.node_disciplines.append(self.arena, discipline);
    try self.node_dir.append(self.arena, .unspecified);
    try self.probe_cache.append(self.arena, .undef);
    return idx;
}

/// `name`, or the first `name#k` nobody has taken. codegen prints one `U`
/// member per slot, so two slots cannot share a spelling — and once identity
/// stopped BEING the spelling, two slots genuinely can want one:
///
///   - §1.3.1.1's reference node prints `gnd` (`nodeName`) and §2.7 lets a plain
///     net be called `gnd` too, so `I(a)` and `I(a,gnd)` both print `flow(a,gnd)`
///     while naming two different branches;
///   - §2.8.1 strips the backslash, so a net `\flow(p,n)` is the identifier
///     `flow(p,n)`, which is what `flowUnknown` prints for the branch (p,n).
///
/// `#` is not a §2.7 identifier character and `naming.sanitize` escapes it, so a
/// suffixed member cannot collide with an unsuffixed one either — the same
/// convention, and the same reasoning, as `codegen.freshUName`, which uniquifies
/// the branch-current unknowns codegen appends after `node_order`. The loop
/// terminates in at most `node_order.len` steps (each `k` it rejects is held by
/// a distinct earlier slot), and that is bounded by |U| ≤ 256.
///
/// The suffix falls on the LATER slot, so it is a function of source order and
/// nothing else. A fixture that has to spell one of these writes the member as
/// `emitTopology` prints it — the same rule as every other unknown.
fn uniqueSpelling(self: *Lower, name: []const u8) Oom![]const u8 {
    if (!self.spellings.contains(name)) return name;
    // The candidates that LOSE are hashed and thrown away, so they are built on
    // the stack and only the winner reaches the arena — `elemKey`'s trick, with
    // the same spill for a name too wide for the buffer.
    var buf: [spelling_buf_len]u8 = undefined;
    var k: u32 = 1;
    while (true) : (k += 1) {
        const cand = std.fmt.bufPrint(&buf, "{s}#{d}", .{ name, k }) catch
            try std.fmt.allocPrint(self.arena, "{s}#{d}", .{ name, k });
        if (!self.spellings.contains(cand)) return self.arena.dupe(u8, cand);
    }
}

/// Widest spelling `uniqueSpelling` builds without spilling: `flow(<` plus two
/// §2.7 identifiers — capped at 1024 characters, the same source bound
/// `elem_key_len` and `naming.max_name_len` are sized from — plus the
/// punctuation and a `#` with a `u32` after it.
const spelling_buf_len = 2 * 1024 + 32;

/// Resolve a net reference — `n` or `n[i]` — to a node_order index.
///
/// The element case is a plain `internNode` of the scalarised name, so a
/// vector element is a node like any other from here on. What this function
/// owes on top is the two checks that only exist while the range is still
/// known: §5.5.2 says an access function takes "scalars or individual elements
/// of a vector", so a bare vector name is not a signal (E0351), and an index
/// has to name an element that was declared (E0351/E0352). Without them
/// `V(bus[9])` would quietly intern a §3.6.5 implicit net called `bus[9]` and
/// read 0.
fn nodeOf(self: *Lower, e: Ast.ExprId) Oom!u16 {
    if (e == .none) return ground;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vectors.get(name)) |r| {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` is a vector [{d}:{d}]; name one element of it", .{ name, r.msb, r.lsb });
                return ground;
            }
            // IEEE 1364 §19.2's `none`, on the other half of §3.6.5: `internNode`
            // below is the one call in this file that MAKES a net out of a name
            // nobody declared, so this is the one place the directive can act.
            // Checked before the intern and not inside it — `lowerModule` interns
            // every declared port and net through the same function, and those
            // are declarations, not implicit nets.
            if (!self.node_voltages.contains(name))
                try self.rejectImplicitNet(name, self.file.exprs.mainTok(e));
            return self.internNode(name, "");
        },
        // §6.7.1 a hierarchical terminal, `V(u.a)`. `flatName` is the whole
        // resolution: elaboration named the child's net `u.a`, so the path IS the
        // flat name and the lookup is the ordinary one.
        //
        // What it may NOT do is intern a new node the way the `.ident` arm does.
        // §3.6.5's implicit net is a rule about an UNDECLARED SIMPLE name in this
        // module; a path that resolves to nothing names no net anywhere in the
        // design, and silently creating one turns a wrong path into a floating
        // node and an E0337 about a name the author never declared.
        .hier_ident => {
            const name = try self.flatName(e);
            if (!self.node_voltages.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0901);
                b.msg("`{s}` names no net in the elaborated design", .{name});
                try b.emit();
                return ground;
            }
            return self.internNode(name, "");
        },
        .index => {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) {
                try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
                return ground;
            }
            const name = self.file.str(ex.strOf(base));
            const r = self.vectors.get(name) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0351, "`{s}` was not declared with a range", .{name});
                return ground;
            };
            // §5.5.2 "The index must be a constant expression, though it may
            // include genvar variables" — which `constEval` reads out of
            // `consts`, where `tryUnrollFor` binds the genvar of the enclosing
            // §5.9.3 `for` for the duration of each unrolled copy.
            const i = self.constEval(ex.rhs(e)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0352, "index into `{s}` is not a constant expression", .{name});
                return ground;
            };
            if (!r.has(i.asInt())) {
                try self.err(self.file.exprs.mainTok(e), .E0352, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ name, r.msb, r.lsb, i.asInt() });
                return ground;
            }
            return self.internNodeElem(name, i.asInt());
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0306, "", .{});
            return ground;
        },
    }
}

/// The scalarised name of one vector element. `p[0]` and not `p__0`: it is the
/// spelling the source uses, so a diagnostic, a `//!` operating-point binding
/// and the emitted `U` enum all name the same thing, and naming.zig's escape
/// makes it a legal Zig identifier without anybody choosing an encoding.
///
/// `internNode` for a vector element, `bus[3]`.
///
/// The spelling goes into a stack buffer for the LOOKUP and only reaches the
/// arena when the element is genuinely new. `elemKey`'s reasoning exactly, and
/// for the same reason: §5.5.2 lets `V(bus[3])` sit in an unrolled §5.9.3 loop
/// body, and formatting the name afresh on every reference would just
/// rediscover the slot the first one interned. `getKey` hands back the arena copy
/// already in the map, so `internNode` does its whole job unchanged.
fn internNodeElem(self: *Lower, base: []const u8, i: i64) Oom!u16 {
    var buf: [elem_key_len]u8 = undefined;
    const key = try self.elemKey(&buf, base, &.{i});
    const name = self.node_voltages.getKey(key) orelse try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
    return self.internNode(name, "");
}

/// Fold a declared `[msb:lsb]` (§3.6.3 Syntax 3-6). The bounds are constant
/// expressions — §6.5.2.2 prints `electrical [0:4-1] in;` as valid — so this
/// is lowering's job and not the parser's. `null` means it did not fold and
/// the diagnostic has been emitted.
fn foldDim(self: *Lower, d: Ast.Dim, tok: u32) Oom!?VecRange {
    const msb = self.constEval(d.msb) orelse {
        try self.err(tok, .E0352, "the msb of the range is not a constant expression", .{});
        return null;
    };
    const lsb = self.constEval(d.lsb) orelse {
        try self.err(tok, .E0352, "the lsb of the range is not a constant expression", .{});
        return null;
    };
    return .{ .msb = msb.asInt(), .lsb = lsb.asInt() };
}

/// §6.5.2.2 the range of a port, from whichever of its two declarations
/// carries one — and, when both do, only after the clause's own check: "If a
/// port is declared as a vector, the range specification between the two
/// declarations of a port shall be identical."
///
/// Identical means EVALUATE-identical, which is why the comparison is here and
/// on FOLDED bounds: the clause prints `input [0:3] in; electrical [0:4-1] in;`
/// as valid and `input [3:0] in; electrical [0:3] in;` as an error, and those
/// two differ only after folding. A range on ONE declaration is not this rule's
/// business — its sentence is guarded by "if a port is declared as a vector",
/// and `inout p; electrical [3:0] p;` declares it exactly once.
fn portRange(self: *Lower, p: *const Ast.Port) Oom!?VecRange {
    const dir_r = if (p.range) |d| try self.foldDim(d, p.main_tok) else null;
    const ty_r = if (p.type_range) |d| try self.foldDim(d, p.main_tok) else null;
    if (dir_r) |a| if (ty_r) |b| {
        if (a.msb != b.msb or a.lsb != b.lsb)
            try self.err(p.main_tok, .E0350, "`{s}` is [{d}:{d}] where it is given a direction and [{d}:{d}] where it is given a discipline", .{
                self.file.str(p.name), a.msb, a.lsb, b.msb, b.lsb,
            });
    };
    return dir_r orelse ty_r;
}

/// The vector a branch terminal names, or null when it is a scalar (or not a
/// bare identifier at all — `branch (a[1], b)` is two scalars).
fn vecTerminal(self: *const Lower, e: Ast.ExprId) ?VecRange {
    if (e == .none) return null;
    if (self.file.exprs.tag(e) != .ident) return null;
    return self.vectors.get(self.file.str(self.file.exprs.strOf(e)));
}

/// §3.12 a vector branch. The LRM's own example:
///
///     electrical [3:5]a;
///     electrical [1:3]b;
///     branch (a,b) br1;  // Branch br1 is of size 3 and can be indexed 0 to 2
///
/// Three rules, all of them here. The terminals pair "in a parallel one-to-one
/// fashion", which is `VecRange.at(k)` against `at(k)` — declaration order on
/// both sides, so neither terminal's own numbering leaks into the pairing. A
/// scalar terminal fans in (Figure 3-2), so it repeats. And "if the range of
/// the vector branch is not specified then the indexing of the vector branch
/// shall start at 0" — hence `[0:size-1]` regardless of what either terminal
/// is indexed from.
///
/// The elements are registered in `branches` under their scalarised names, so
/// `V(br1[1])` resolves through the ordinary branch lookup; the base name goes
/// into `vectors` so that `V(br1)` and `V(br1[9])` get the vector diagnostics
/// rather than being read as a net.
fn declareVectorBranch(self: *Lower, b: *const Ast.BranchDecl) Oom!void {
    const name = self.file.str(b.name);
    const hv = self.vecTerminal(b.hi);
    const lv = self.vecTerminal(b.lo);
    if (hv) |h| if (lv) |l| {
        if (h.size() != l.size()) {
            try self.err(b.main_tok, .E0353, "`{s}` joins a size-{d} vector to a size-{d} one", .{ name, h.size(), l.size() });
            return;
        }
    };
    const size = if (hv) |h| h.size() else lv.?.size();
    // A scalar terminal is resolved once, outside the loop: it is the SAME
    // node on every element (Figure 3-2), not a fresh implicit net per index.
    const h_scalar = if (hv == null) try self.nodeOf(b.hi) else ground;
    const l_scalar = if (lv == null) try self.nodeOf(b.lo) else ground;
    const h_name = if (hv != null) self.file.str(self.file.exprs.strOf(b.hi)) else "";
    const l_name = if (lv != null) self.file.str(self.file.exprs.strOf(b.lo)) else "";
    for (0..size) |k| {
        const hi = if (hv) |h| try self.internNode(try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ h_name, h.at(@intCast(k)) }), "") else h_scalar;
        const lo = if (lv) |l| try self.internNode(try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ l_name, l.at(@intCast(k)) }), "") else l_scalar;
        // §3.12 → §3.11 once, not `size` times: every element of a vector
        // branch pairs the same two DISCIPLINES, so the verdict is the same on
        // all of them and only the first has anything new to say.
        if (k == 0) try self.checkNetCompat(b.main_tok, hi, lo);
        try self.branches.put(self.arena, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, @as(i64, @intCast(k)) }), .{
            .hi = hi,
            .lo = lo,
            .id = self.newBranchId(),
        });
    }
    try self.vectors.put(self.arena, name, .{ .msb = 0, .lsb = @as(i64, size) - 1 });
}

/// The name codegen prints for a node_order index (naming.zig unit targets).
pub fn nodeName(self: *const Lower, idx: u16) []const u8 {
    return if (idx == ground) "gnd" else self.node_order.items[idx];
}

/// §5.4.1 a fresh branch identity, one per DECLARED branch name (array elements
/// included). Ids are per-module and never reused; nothing outside lowering sees
/// them, so they need no stable spelling.
fn newBranchId(self: *Lower) u32 {
    self.last_branch_id += 1;
    return self.last_branch_id;
}

/// §4.4 potential probe of one node. Deduped so a node is one `block_param`
/// (codegen's `x[idx]`); ground is the literal 0 (§1.3.1.1).
fn probe(self: *Lower, idx: u16) Oom!Mir.Value {
    if (idx == ground) return .f_zero;
    if (self.probe_cache.items[idx] != .undef) return self.probe_cache.items[idx];
    const v = try self.mir.addBlockParam(self.arena, idx);
    self.probe_cache.items[idx] = v;
    return v;
}

/// §5.4.2 reading a flow (`I(a,b)`) makes the branch current a solver unknown
/// of its own. It gets a node_order slot so codegen indexes it like any other
/// `x[i]`.
///
/// Deduped on the PAIR, which is the identity §5.4.1 gives a branch, and not on
/// the printed name. Two branches can print alike — §1.3.1.1's reference node
/// and a net that §2.7 lets the author call `gnd` both spell `gnd` — and keying
/// on the name aliased `I(a)` onto `I(a,gnd)`, one unknown for two currents and
/// a Jacobian that is quietly wrong (`ch05_analog_behavior/
/// net_named_gnd_is_not_ground.va` is that circuit).
///
/// It also means the name is formatted on the MISS path only, where the old
/// spelling-keyed version paid an `allocPrint` per reference to discover the
/// entry already existed.
fn flowUnknown(self: *Lower, hi: u16, lo: u16) Oom!u16 {
    const gop = try self.flow_unknowns.getOrPut(self.arena, .{ .hi = hi, .lo = lo });
    if (gop.found_existing) return gop.value_ptr.*;
    const name = try std.fmt.allocPrint(self.arena, "flow({s},{s})", .{ self.nodeName(hi), self.nodeName(lo) });
    // The tolerance node is the HIGH one: a branch unknown carries no discipline
    // of its own (§3.6.1.2's abstol has to come from somewhere).
    const u = try self.appendNode(name, "", .{ .branch_flow = hi });
    gop.value_ptr.* = u;
    return u;
}

/// §5.4.3 the unknown carrying `I(<p>)`. Spelled `flow(<p>)` on purpose: it
/// reads as the port access function it came from, and it can never be mistaken
/// for a `flow(a,b)` branch unknown (that form always has a comma).
///
/// `port_probes` is the identity — one entry per port, and the scan is bounded
/// by the module's port count, which is why it needs no map. Reading it FIRST
/// is the fix: the old order interned the name and let the string dedupe,
/// so a net spelled `flow(<p>)` took over the port's current.
fn portFlowUnknown(self: *Lower, p: u16) Oom!u16 {
    for (self.port_probes.items) |pp| {
        if (pp.port == p) return pp.u;
    }
    const name = try std.fmt.allocPrint(self.arena, "flow(<{s}>)", .{self.nodeName(p)});
    const u = try self.appendNode(name, "", .{ .port_flow = p });
    try self.port_probes.append(self.arena, .{ .port = p, .u = u });
    return u;
}

// ---------------------------------------------------------------------------
// Class 3 — parameters (LRM §3.4) and variables (§3.2)
// ---------------------------------------------------------------------------

/// LRM §3.4. Register a parameter: infer its type (§3.4.1), fold its default,
/// and COPY decl.ranges into ParamInfo.ranges (§3.4.2 — the class-6 evidence).
pub fn lowerParamDecl(self: *Lower, decl: *const Ast.ParamDecl) Oom!void {
    const name = self.file.str(decl.name);

    // §3.4.2: "The first expression in the range shall be numerically smaller
    // than the second expression in the range." Decidable from the declaration
    // alone — separate from checking an OVERRIDE against a well-formed range,
    // which needs an instance value. Folded bounds only; §3.4.2 admits a
    // constant_expression over earlier parameters. Here, above the array
    // dispatch, so an array's ranges are judged once and not once per element.
    for (decl.ranges) |r| {
        if (r.strings != null or r.hi == .none) continue; // string set / single value
        const lo = self.constEval(r.lo) orelse continue;
        const hi = self.constEval(r.hi) orelse continue;
        if (lo == .str or hi == .str) continue;
        if (lo.asReal() < hi.asReal()) continue;
        try self.err(decl.main_tok, .E0347, "`{s}` {s} bounds {d} and {d} are not in increasing order", .{
            name, @tagName(r.kind), lo.asReal(), hi.asReal(),
        });
    }

    // §3.4/A.2.4: a parameter assignment carries a constant_mintypmax_
    // expression. "Did not fold" cannot be the test — the derive() fall-through
    // below deliberately keeps a default that reads OTHER parameters (§6.3.4:
    // the dependent must follow an override of its base) — so what is policed
    // is the part no parameter dependence can excuse: a read of the operating
    // point or the simulation state, which has no value a model card could
    // carry. Without this, `parameter real bad = $abstime;` compiled and the
    // card silently read 0.0. Reported and then lowered anyway, like E0347.
    if (self.simStateInDefault(decl.default)) |what| {
        var b = self.errWith(decl.main_tok, .E0363);
        b.msg("`{s}` reads `{s}`", .{ name, what });
        try b.emit();
    }

    // §3.4.4 array parameters are scalarized into `name[i]` entries.
    if (decl.dims.len != 0) return self.lowerParamArray(decl, name);

    const folded = if (self.constEval(decl.default)) |c| parameterConst(decl.ty, c) else null;
    try self.checkParamType(decl, name, folded);
    // §3.4.2's OTHER half: "the parameter value shall be within the range". It
    // needs a value somebody supplied, and `is_override` is the only marker that
    // one was — elaborate.zig sets it when a §6.3 instance parameter value
    // assignment becomes this declaration's default. A module compiled on its own
    // has no instance, so its declared default is judged for its BOUNDS (E0347,
    // above) and not for itself.
    if (decl.is_override) try self.checkParamRange(decl, name, folded);
    const ty: Ast.Type = if (decl.ty != .unspecified) decl.ty else switch (folded orelse Const{ .real = 0 }) {
        .int => .integer,
        .real => .real,
        .str => .string,
    };
    // §6.3.4 later defaults may reference this one. §6.6.1 also makes a
    // parameter a legal constant expression for an array or generate bound, so
    // `consts` keeps carrying the value it folds to under the declared default
    // — that is the only value those two positions can ever see.
    if (folded) |c| try self.consts.put(self.arena, name, c);

    // §6.3.4: "an update of gate_width, whether by a defparam statement or in
    // an instantiation statement for the module which defined these parameters,
    // automatically updates gate_cap". So a default that MENTIONS another
    // parameter may NOT be frozen at the number it folds to under that
    // parameter's declared default — the host overrides the base after
    // elaboration and the dependent has to follow it. `foldExpr(..., false)` is precisely
    // the fold that refuses to look through a parameter, so it is the "may this
    // be baked into the model card?" test; `folded` above cannot be, for the
    // §6.6.1 reason. Codegen turns the surviving expression into `derive()`.
    const default = try self.parameterDefault(decl.default, decl.ty);

    try self.addParam(name, ty, default, folded, decl.ranges, decl.is_local, decl.main_tok);
    self.params.items[self.params.items.len - 1].integer32 = decl.ty == .integer;
}

/// §3.4/A.2.4: the spelling of the first simulation-state reference in a
/// parameter default, or null when none exists. Access functions, analog
/// operators, small-signal sources and event functions are state reads by
/// TAG; a `sys_call` is one by NAME (`simStateName`), because most `$` names
/// that could appear here — `$param_given`, `$mfactor`, `$simprobe` — resolve
/// before the solve and are left to the ordinary paths. Same walk shape as
/// `scanCallSitesExpr`: list-carrying tags recurse `args`, the ternary's third
/// operand lives in `extra`, and `lhs`/`rhs` are `.none` wherever unused.
fn simStateInDefault(self: *const Lower, e: Ast.ExprId) ?[]const u8 {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    switch (tag) {
        // §4.4 access functions, §4.5 analog operators, §4.6 small-signal
        // sources, §5.10 event functions: operating-point reads by construction.
        .branch_access, .port_access, .filter_call, .noise_call, .event_function => return self.file.str(ex.strOf(e)),
        .sys_call => {
            const n = self.file.str(ex.strOf(e));
            if (simStateName(n)) return n;
        },
        else => {},
    }
    switch (tag) {
        .call, .builtin_call, .sys_call, .concat, .assign_pattern => {
            for (ex.args(e)) |a| if (self.simStateInDefault(a)) |w| return w;
        },
        .ternary => if (self.simStateInDefault(ex.ternaryElse(e))) |w| return w,
        else => {},
    }
    if (self.simStateInDefault(ex.lhs(e))) |w| return w;
    return self.simStateInDefault(ex.rhs(e));
}

/// The `$` (and `analysis`) names whose value belongs to a solve: time, the
/// ambient temperature pair, the RNG family, and the analysis type. §9.13's
/// distributions are matched by their two prefixes.
///
/// `$simparam` is deliberately NOT here: §9.15's table is the HOST's, constant
/// for a whole run, and a default reading it is the documented W1050 contract
/// — the field ships as 0 and the host writes it (codegen's "§3.4 a default
/// with no compile-time value is W1050" test pins exactly that shape).
fn simStateName(n: []const u8) bool {
    const names = [_][]const u8{
        "$abstime", "$realtime", "$temperature", "$vt",
        "$random",  "$arandom",  "analysis",
    };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return std.mem.startsWith(u8, n, "$dist_") or std.mem.startsWith(u8, n, "$rdist_");
}

/// §3.4.2: "The parameter value shall be within the range from the smallest
/// value specified to the largest value specified", minus everything an
/// `exclude` removes. Several `from` clauses are a UNION — the clause's own
/// example writes two — so the test is "inside at least one", not "inside all".
///
/// Only reached for a §6.3 override (see the call site). Nothing is reported
/// when a bound or the value will not fold: §3.4.2 admits a constant expression
/// over earlier parameters, and a bound that reads an overridable parameter has
/// no single value at compile time.
fn checkParamRange(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
    const c = folded orelse return;
    if (c == .str) {
        var has_from = false;
        var in_from = false;
        for (decl.ranges) |r| {
            const off = r.strings orelse continue;
            const contains = for (self.file.exprs.list(off)) |id| {
                if (std.mem.eql(u8, c.str, self.file.str(@enumFromInt(id)))) break true;
            } else false;
            switch (r.kind) {
                .from => {
                    has_from = true;
                    in_from = in_from or contains;
                },
                .exclude => if (contains) {
                    try self.err(decl.main_tok, .E0361, "`{s}` is \"{s}\", which the declared range excludes", .{ name, c.str });
                    return;
                },
            }
        }
        if (has_from and !in_from)
            try self.err(decl.main_tok, .E0361, "`{s}` is \"{s}\", outside the declared range", .{ name, c.str });
        return;
    }
    const v = c.asReal();

    var has_from = false;
    var in_from = false;
    for (decl.ranges) |r| {
        if (r.strings != null) continue;
        const lo = self.rangeBound(r.lo) orelse continue;
        // A.2.5 `exclude constant_expression` — a single value, so hi is absent.
        const hi = if (r.hi == .none) lo else self.rangeBound(r.hi) orelse continue;
        const above_lo = if (r.lo_inclusive) v >= lo else v > lo;
        const below_hi = if (r.hi_inclusive) v <= hi else v < hi;
        switch (r.kind) {
            .from => {
                has_from = true;
                if (above_lo and below_hi) in_from = true;
            },
            .exclude => if (above_lo and below_hi) {
                var b = self.errWith(decl.main_tok, .E0361);
                b.msg("`{s}` is {d}, which the declared range excludes", .{ name, v });
                try b.emit();
                return;
            },
        }
    }
    if (has_from and !in_from) {
        var b = self.errWith(decl.main_tok, .E0361);
        b.msg("`{s}` is {d}, outside the declared range", .{ name, v });
        try b.emit();
    }
}

/// One end of a §3.4.2 value_range. A.2.5 lets it be `inf` / `-inf`, which is
/// not a constant_expression and so cannot go through `constEval`.
fn rangeBound(self: *Lower, e: Ast.ExprId) ?f64 {
    if (e == .none) return null;
    return switch (self.file.exprs.tag(e)) {
        .pos_inf => std.math.inf(f64),
        .neg_inf => -std.math.inf(f64),
        else => blk: {
            const c = self.constEval(e) orelse break :blk null;
            break :blk if (c == .str) null else c.asReal();
        },
    };
}

/// §3.4.1 the two type rules the general "convert the value to the parameter's
/// type" sentence does NOT cover. Diagnose and carry on: inference still runs
/// and the parameter still enters the table, so one bad declaration does not
/// turn every use of it into a second diagnostic.
///
/// Scalars only — the array path has its own arm, since §3.4.4's requirement is
/// about the DECLARATION and holds whatever the pattern contains.
fn checkParamType(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8, folded: ?Const) Oom!void {
    const c = folded orelse return; // not constant here: nothing to compare
    const is_str = c == .str;
    // §3.4.1: "the type of a string parameter (see 3.4.6) ... is mandatory."
    // Inference is defined over the value "after any value overrides have been
    // applied", so an untyped parameter has no type until elaboration — and
    // the no-string-conversion rule below has to be decidable before then.
    if (decl.ty == .unspecified) {
        if (is_str) try self.err(decl.main_tok, .E0346, "`{s}` is initialized with a string; write `parameter string`", .{name});
        return;
    }
    // §3.4.1: "No conversion shall be applied for strings; it shall be an error
    // to assign a numeric value to a parameter declared as string or to assign
    // a string value to a real parameter." Both directions, one code — it is
    // one sentence and one fix.
    if ((decl.ty == .string) == is_str) return;
    try self.err(decl.main_tok, .E0345, "`{s}` is declared {s} and initialized with a {s} value", .{
        name,
        @tagName(decl.ty),
        if (is_str) "string" else "numeric",
    });
}

/// §3.4.7's other form: `aliasparam m = $mfactor;`, which the clause prints
/// beside `aliasparam trise = dtemp;` and which Syntax 3-2 does not cover —
/// `aliasparam_declaration ::= aliasparam parameter_identifier =
/// parameter_identifier ;` has an identifier on the right, so the form only
/// exists in the clause's prose. It exists because "m" is what a SPICE netlist
/// calls the shunt multiplicity and `$mfactor` is what §9.18 calls it, and a
/// model has to answer to both spellings.
///
/// THE ALIAS GETS THE STORAGE, which is the one design call here. §3.4.7 makes
/// an alias a second name for one location, and §9.18's `$mfactor` has no
/// location on VerA's model card at all — it is an `Instance` field the host
/// writes, because §6.3.6 has the host scale the whole stamp by it. So the way
/// to give the two names one location is the other direction: the alias becomes
/// an ordinary real parameter (Table 9-29's top-level 1.0 as its default, which
/// is exactly the value `$mfactor` had before anyone aliased it) and `$mfactor`
/// reads it (`lowerSysCall`).
///
/// ponytail: the ceiling is that a host which writes `Instance.mfactor` AND
/// overrides the alias has set the same physical quantity twice, and the
/// equations then read the alias while the stamp is scaled by the field. The
/// upgrade is for codegen to fold the model-card knob into `Instance.mfactor`
/// at `derive` time, which needs the two structs to know about each other.
fn aliasSystemParam(self: *Lower, alias: []const u8, target: []const u8) Oom!bool {
    if (!std.mem.eql(u8, target, "$mfactor")) return false;
    self.mfactor_param = @intCast(self.params.items.len);
    try self.addParam(alias, .real, try self.mir.addFloatConst(self.arena, 1.0), .{ .real = 1.0 }, &.{}, false, Mir.no_tok);
    return true;
}

fn addParam(
    self: *Lower,
    name: []const u8,
    ty: Ast.Type,
    default: Mir.Value,
    folded: ?Const,
    ranges: []const Ast.ValueRange,
    is_local: bool,
    tok: u32,
) Oom!void {
    const idx: u32 = @intCast(self.params.items.len);
    try self.params.append(self.arena, .{
        .name = name,
        .tok = tok, // §3.4.2 diagnostics point back at the declaration
        .ty = ty,
        .default = default,
        .folded = folded, // §3.4 the value under the declared defaults
        .ranges = ranges, // §3.4.2 — MUST reach proof.zig
        .is_local = is_local,
    });
    try self.param_values.append(self.arena, try self.mir.addParamRef(self.arena, idx));
    try self.param_index.put(self.arena, name, idx);
}

/// Apply an explicit parameter type before a later default infers its own type.
/// Out-of-i64 real conversion retains the existing saturation policy; deciding
/// that implementation-defined domain is separate from preserving integral bits.
fn parameterConst(ty: Ast.Type, value: Const) Const {
    return switch (ty) {
        .real => if (value == .str) value else .{ .real = value.asReal() },
        .integer => switch (value) {
            .int => |n| .{ .int = wrap32(n) },
            .real => |n| blk: {
                const rounded = @round(n);
                if (rounded >= -9223372036854775808.0 and rounded < 9223372036854775808.0)
                    break :blk .{ .int = wrap32(@intFromFloat(rounded)) };
                break :blk value;
            },
            .str => value,
        },
        .string, .unspecified => value,
    };
}

/// The MIR must contain the same declared-type conversion as `folded` metadata.
/// Later defaults and operator controls follow this MIR, not the Model field.
fn parameterDefault(self: *Lower, e: Ast.ExprId, ty: Ast.Type) Oom!Mir.Value {
    if (e == .none) return zeroOf(astTy(ty));
    if (self.foldExpr(e, false)) |raw| {
        return switch (parameterConst(ty, raw)) {
            .int => |n| self.mir.addIntConst(self.arena, n),
            .real => |n| self.mir.addFloatConst(self.arena, n),
            .str => |s| self.mir.addStrConst(self.arena, s),
        };
    }
    const value = try self.lowerExpr(e);
    return switch (ty) {
        .real => self.toReal(value),
        // MIR integer arithmetic truncates to signed 32 bits. Adding zero
        // expresses that conversion without changing the mathematical value.
        .integer => self.emit(.iadd, &.{ try self.toInt(value), .zero }),
        .string, .unspecified => value.v,
    };
}

/// §3.4.4 `parameter real c[0:2] = '{1,2,3};` → three scalar parameters named
/// `c[0]`, `c[1]`, `c[2]`. Codegen emits one Model field each.
fn lowerParamArray(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8) Oom!void {
    const dims = try self.dimsBounds(decl.dims, decl.main_tok, name) orelse return;
    // §3.4.4, in the restriction list closed by "Failure to follow these
    // restrictions shall result in an error": "A type of a parameter array
    // shall be given in the declaration." §3.4.1 says it again from the other
    // side. The reason is that §3.4.1's fallback derives the type from the
    // assigned VALUE, and an array's initializer is an assignment pattern —
    // there is no scalar there to derive from. `.real` below is a recovery
    // guess, not an inference.
    if (decl.ty == .unspecified)
        try self.err(decl.main_tok, .E0346, "array parameter `{s}` has no declared type", .{name});
    const ty: Ast.Type = if (decl.ty == .unspecified) .real else decl.ty;
    // §3.4: "For parameters defined as arrays, the initializer shall be a
    // constant_assignment_pattern expression ... using an assignment pattern
    // (see 4.2.14), i.e. within '{ and } delimiters." Annex G Table G.4 item 2
    // records why the apostrophe was added at all — without it `{2.1, 4.5}` is
    // the §4.2.13 concatenation operator and a front end cannot tell a list of
    // values from a concatenation. Diagnosed and carried on with no elements,
    // so every element keeps its §3.4 zero default and one bad declaration does
    // not turn every USE of the parameter into a second diagnostic.
    if (decl.default != .none and self.file.exprs.tag(decl.default) != .assign_pattern) {
        var b = self.errWith(self.file.exprs.mainTok(decl.default), .E0349);
        b.msg("initialising array parameter `{s}`", .{name});
        b.help("write the list as an assignment pattern: `'{{ ... }}`", .{});
        try b.emit();
    }
    const elems = try self.flattenPattern(decl.default, dims);

    try self.declareArray(name, .{ .dims = dims, .ty = astTy(ty) });
    var sub: [max_stack_dims]i64 = undefined;
    const idx = try self.subscriptBuf(&sub, dims.len);
    for (elems, 0..) |elem, k| {
        shapeSubscripts(dims, k, idx);
        const default = try self.parameterDefault(elem, ty);
        // §3.4.4 an omitted element is the type's zero; anything else folds
        // through the declared defaults exactly as a scalar's does.
        const folded: ?Const = if (elem == .none)
            (if (astTy(ty) == .real) Const{ .real = 0 } else Const{ .int = 0 })
        else
            self.constEval(elem);
        try self.addParam(try self.elemName(name, idx), ty, default, if (folded) |c| parameterConst(ty, c) else null, decl.ranges, decl.is_local, decl.main_tok);
    }
}

/// §2.9's two rules about an attribute VALUE, and §2.9.2's four value domains.
///
/// In lowering because "constant expression" is a question about the scopes: `z`
/// is refused and `gain` is not, and only the declaration tables know which is
/// which. The parser collects the specs (`Parser.parseAttributes`) and checks the
/// one rule it alone can see, the nesting ban.
///
/// The attribute's TARGET is not recorded and is not needed: neither rule is
/// about the decorated item, and §2.9 leaves what an attribute MEANS entirely to
/// the tool that reads it — "properties about objects, statements and groups of
/// statements in the HDL source that can be used by various tools".
fn checkAttributes(self: *Lower, attrs: []const Ast.NatureAttr) Oom!void {
    for (attrs) |a| {
        // §2.9: "If the value is not specified, then ... the default value is 1"
        // — a name on its own is complete, so there is nothing to judge.
        if (a.value == .none) continue;
        const name = self.file.str(a.name);
        const c = self.constEval(a.value) orelse {
            var b = self.errWith(a.main_tok, .E0357);
            b.msg("`{s}`", .{name});
            b.note("§2.9 Syntax 2-4: `attr_spec ::= attr_name [ = constant_expression ]`", .{});
            try b.emit();
            continue;
        };
        // §2.9.2 fixes the value of exactly four names, with a "must" each.
        // Every OTHER name is a tool convention with no stated domain, so it is
        // not checked — inventing one would refuse conforming source.
        const want: ?[]const []const u8 = if (std.mem.eql(u8, name, "desc") or
            std.mem.eql(u8, name, "units"))
            // "The attribute must be assigned a string" — any string.
            &.{}
        else if (std.mem.eql(u8, name, "op"))
            &.{ "yes", "no" }
        else if (std.mem.eql(u8, name, "multiplicity"))
            &.{ "multiply", "divide", "none" }
        else
            null;
        const allowed = want orelse continue;
        const got = switch (c) {
            .str => |sv| sv,
            // `desc = 7` fails on this arm: not a string at all.
            else => {
                var b = self.errWith(a.main_tok, .E0358);
                b.msg("`{s}` must be assigned a string", .{name});
                try b.emit();
                continue;
            },
        };
        if (allowed.len == 0) continue; // desc/units: a string is the whole rule
        var in_domain = false;
        for (allowed) |ok| {
            if (std.mem.eql(u8, got, ok)) in_domain = true;
        }
        if (!in_domain) {
            var b = self.errWith(a.main_tok, .E0358);
            b.msg("`{s} = \"{s}\"`", .{ name, got });
            b.help("§2.9.2 lists the values for `{s}`: {s}", .{ name, try joinQuoted(self.arena, allowed) });
            try b.emit();
        }
    }
}

/// `"a", "b" or "c"` — the LRM's own listing style, for E0358's help line.
fn joinQuoted(arena: std.mem.Allocator, items: []const []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |it, i| {
        if (i != 0) try out.appendSlice(arena, if (i + 1 == items.len) " or " else ", ");
        try out.print(arena, "\"{s}\"", .{it});
    }
    return out.toOwnedSlice(arena);
}

/// §3.4.8/§3.3's nested assignment pattern, flattened to one expression per
/// cell of `dims` in the same row-major order `shapeSubscripts` walks. §3.3's
/// own example is
///
///     string paths[0:2][0:1] = '{ '{"dir1","fileA"}, '{"dir2","fileA"}, … };
///
/// — an element list per dimension, so the flattening is one recursion per
/// dimension rather than a single `args` read. A cell the pattern does not
/// reach is `.none`, which every caller reads as §3.2's zero (or "").
/// A `.concat` is accepted alongside `.assign_pattern` because the parser folds
/// `{a,b}` to the same node shape and §3.4.4's diagnostic (E0349) already
/// covers the spelling.
fn flattenPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds) Oom![]const Ast.ExprId {
    const out = try self.arena.alloc(Ast.ExprId, shapeCells(dims));
    self.fillPattern(e, dims, out);
    return out;
}

fn fillPattern(self: *Lower, e: Ast.ExprId, dims: []const Bounds, out: []Ast.ExprId) void {
    if (dims.len == 0) {
        out[0] = e;
        return;
    }
    const ex = &self.file.exprs;
    const elems: []const Ast.ExprId = if (e != .none and
        (ex.tag(e) == .assign_pattern or ex.tag(e) == .concat))
        ex.args(e)
    else
        &.{};
    const stride = shapeCells(dims[1..]);
    for (0..@intCast(dims[0].count())) |k| {
        const child = if (k < elems.len) elems[k] else Ast.ExprId.none;
        self.fillPattern(child, dims[1..], out[k * stride ..][0..stride]);
    }
}

const Bounds = struct {
    lo: i64,
    hi: i64,
    descending: bool = false,

    fn count(b: Bounds) i64 {
        return b.hi - b.lo + 1;
    }
};

/// §3.2/§3.2.2/§3.4.4 `{ [msb:lsb] }` — one `Bounds` per declared dimension,
/// outermost first, so `flag_array[0:8][0:3]` is `{{0,8},{0,3}}`.
///
/// §3.2 puts no limit on the count and neither does this: a multidimensional
/// array is scalarized cell by cell (see `shapeCells`), exactly as the
/// one-dimensional case always was, so a second dimension costs a longer key
/// and nothing else.
fn dimsBounds(self: *Lower, dims: []const Ast.Dim, tok: u32, name: []const u8) Oom!?[]const Bounds {
    if (dims.len == 0) {
        try self.err(tok, .E0307, "`{s}` has no dimensions", .{name});
        return null;
    }
    const out = try self.arena.alloc(Bounds, dims.len);
    for (dims, out) |d, *b| {
        const a = self.constEval(d.msb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        const c = self.constEval(d.lsb) orelse {
            try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
            return null;
        };
        const x = a.asInt();
        const y = c.asInt();
        b.* = .{ .lo = @min(x, y), .hi = @max(x, y), .descending = x > y };
    }
    return out;
}

/// How many scalars a declared shape becomes.
fn shapeCells(dims: []const Bounds) usize {
    var n: usize = 1;
    for (dims) |d| n *= @intCast(d.count());
    return n;
}

/// The subscripts of the `k`th cell of a ROW-MAJOR walk — the last dimension
/// varies fastest, which is the order §3.4.8's nested assignment pattern lists
/// its elements in (`'{ '{a,b}, '{c,d} }` is rows of columns).
fn shapeSubscripts(dims: []const Bounds, k: usize, out: []i64) void {
    var rest = k;
    var i = dims.len;
    while (i > 0) {
        i -= 1;
        const n: usize = @intCast(dims[i].count());
        const offset: i64 = @intCast(rest % n);
        out[i] = if (dims[i].descending) dims[i].hi - offset else dims[i].lo + offset;
        rest /= n;
    }
}

/// How many subscripts fit on the stack. NOT a proved bound — §3.2 puts no limit
/// on a declaration's dimension count, though its own examples go two deep — so
/// this is the spill shape and not a fixed buffer: eight covers everything real
/// and anything wider allocates. `indexChain` uses the same spill threshold.
const max_stack_dims = 8;

/// Scratch for ONE cell's subscripts, sized once for a whole `shapeSubscripts`
/// walk. Eight copies of this line were written out inline across seven loops
/// (`copyWholeArray` has both halves of a copy), each re-deciding the threshold
/// — and each INSIDE its loop, so a nine-dimensional array paid an arena
/// allocation per cell rather than one for the walk.
fn subscriptBuf(self: *Lower, buf: *[max_stack_dims]i64, n: usize) Oom![]i64 {
    return if (n <= buf.len) buf[0..n] else try self.arena.alloc(i64, n);
}

/// The scalarized key for one array element, `name[i]` / `name[i][j]`
/// (§3.2, §3.2.2, §3.4.4).
///
/// Only the two DECLARATION sites need this: `vars` and `param_index` retain
/// the key, so it has to outlive the call. Every *lookup* goes through
/// `elemKey` instead — see there.
fn elemName(self: *Lower, name: []const u8, idx: []const i64) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(self.arena, name);
    for (idx) |i| try out.print(self.arena, "[{d}]", .{i});
    return out.toOwnedSlice(self.arena);
}

/// Widest `name[i][j]…` a legal model can produce without spilling: §2.7 caps
/// an identifier at 1024 characters (the same source bound
/// `naming.max_name_len` is sized from), plus four subscripts of `[`, a
/// 20-character `i64` and `]`. A deeper array spills to the arena — see
/// `elemKey`.
const elem_key_len = 1024 + 22 * 4;

/// `name[i][j]` for a *lookup*, formatted into the caller's stack buffer.
///
/// `HashMap.get` only compares the key, it never retains it, so the arena copy
/// `elemName` makes is pure waste on this path — and it was paid once per
/// *reference*, so a `c[0]` read in a loop body leaked a fresh string every
/// time it was lowered. Now the arena sees `c[0]` once per compilation, at the
/// declaration. Same trick as `naming.zig`'s fixed key buffer, and safe for the
/// same reason: the slice never escapes the caller's frame.
///
/// ponytail: an over-long identifier, or an array of more than four dimensions,
/// falls back to the arena rather than carrying a diagnostic of its own — the
/// first is already rejected upstream, the second is legal §3.2 and only pays
/// one allocation per reference. Silently truncating the key would alias two
/// distinct elements, which is the one outcome that must not happen.
fn elemKey(self: *Lower, buf: *[elem_key_len]u8, name: []const u8, idx: []const i64) Oom![]const u8 {
    if (name.len > buf.len) return try self.elemName(name, idx);
    @memcpy(buf[0..name.len], name);
    var n = name.len;
    for (idx) |i| {
        const s = std.fmt.bufPrint(buf[n..], "[{d}]", .{i}) catch
            return try self.elemName(name, idx);
        n += s.len;
    }
    return buf[0..n];
}

// ---- §3.2 variables and scopes ---------------------------------------------

fn closeScope(self: *Lower, mark: usize) void {
    while (self.scope_log.items.len > mark) {
        const e = self.scope_log.pop().?;
        if (e.prev) |p| {
            self.vars.putAssumeCapacity(e.name, p);
        } else {
            _ = self.vars.remove(e.name);
        }
        if (e.prev_array) |a| {
            self.arrays.putAssumeCapacity(e.name, a);
        } else {
            _ = self.arrays.remove(e.name);
        }
    }
}

fn shadowName(self: *Lower, name: []const u8) Oom!void {
    try self.scope_log.append(self.arena, .{
        .name = name,
        .prev = self.vars.get(name),
        .prev_array = self.arrays.get(name),
    });
    _ = self.vars.remove(name);
    _ = self.arrays.remove(name);
}

fn declareArray(self: *Lower, name: []const u8, info: ArrayInfo) Oom!void {
    try self.shadowName(name);
    try self.arrays.put(self.arena, name, info);
}

/// Bind `name` to a fresh SSA place, remembering what it shadowed (§5.3.2).
fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot {
    const slot: VarSlot = .{ .place = self.builder.newPlace(), .ty = ty };
    try self.shadowName(name);
    try self.vars.put(self.arena, name, slot);
    return slot;
}

/// §6.8: "An identifier shall be used to declare only one item within a scope.
/// This rule means it is ILLEGAL TO DECLARE TWO OR MORE VARIABLES WHICH HAVE THE
/// SAME NAME, or to name a task the same as a variable within the same module, or
/// to give an instance the same name as the name of the net connected to its
/// output."
///
/// The first clause of that sentence, which is the one that has a second
/// declaration to point at. Without it the second `put` in `declareVar` rebinds
/// the name and the first declaration's initializer is silently unreachable —
/// and the legal case looks identical from the map's side, which is why the test
/// is over ONE DECLARATION LIST rather than over `self.vars`: a list is exactly
/// the declarations of one scope (§6.8 lists what opens one; a second declaration
/// is not on it), so shadowing an outer name cannot reach this.
///
/// ponytail: O(n²) over one scope's variables, which is a handful. A set would
/// need an allocation per scope to save comparisons that cost nothing.
fn checkOneItemPerScope(self: *Lower, vars: []const Ast.VarDecl) Oom!void {
    for (vars, 0..) |v, i| {
        for (vars[0..i]) |earlier| {
            if (earlier.name != v.name) continue;
            var b = self.errWith(v.main_tok, .E0362);
            b.msg("`{s}`", .{self.file.str(v.name)});
            b.note("§6.8: one identifier declares one item in a scope — the earlier declaration is unreachable", .{});
            try b.emit();
            break;
        }
    }
}

/// Where a `declareVarDecl` sits. §5.3.2 gives a persistent §5.10 slot to a
/// module variable and to a NAMED block's local; an unnamed `begin`'s
/// declaration is neither, and `block_path` is "" for it.
const VarScope = enum { module, local };

/// §3.2 declare and initialize. Verilog-AMS variables start at zero, so a read
/// on a path that never assigned is 0 rather than the SSA builder's `.undef`
/// (which codegen could not emit).
fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void {
    const name = self.file.str(decl.name);
    const ty = astTy(decl.ty);
    // §5.3.2: "All named block variables are static — that is, an unique
    // location exists for all variables and leaving or entering the block do
    // not affect the values stored in them." The location is (scope, name), so
    // the key `markHeldVars` recorded carries the block path; the empty prefix
    // is module scope, and an UNNAMED block gets no slot because the clause
    // grants one to named blocks only.
    const prefix = if (scope == .module) "" else self.block_path;
    const held_key = if (prefix.len == 0)
        name
    else
        try std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, name });
    // §5.10. `.string` is deliberately excluded: a string never reaches the
    // residual (§3.3 strings only feed §9.4 tasks, which re-run every
    // evaluation anyway), so a persistent slot for one would be storage
    // nothing can observe.
    const hold = (scope == .module or prefix.len != 0) and ty != .string and
        self.held_names.contains(held_key);

    if (decl.dims.len != 0) {
        const dims = try self.dimsBounds(decl.dims, decl.main_tok, name) orelse return;
        try self.declareArray(name, .{ .dims = dims, .ty = ty });
        // §3.3's own example is `string names[1:3] = '{"first","middle","last"}`:
        // the declaration takes an initializer exactly like the §3.4.4 array
        // PARAMETER does, and dropping it silently zeroed every element. The
        // pattern is positional over the declared range, so element k lands at
        // its left bound first, following the declared direction, and
        // one list per dimension for a multidimensional array (§3.3, §3.4.8).
        const elems = try self.flattenPattern(decl.init, dims);
        var sub: [max_stack_dims]i64 = undefined;
        const idx = try self.subscriptBuf(&sub, dims.len);
        for (elems, 0..) |elem, k| {
            shapeSubscripts(dims, k, idx);
            // §3.2.2 arrays are scalarized, so a held array is just one held
            // slot per element — `markHeldVars` records the base name and every
            // element takes a slot, since the index may be a runtime `case`.
            const en = try self.elemName(name, idx);
            const slot = try self.declareVar(en, ty);
            // §3.2 an element the pattern does not reach keeps the zero start.
            const init_val: Mir.Value = if (elem != .none)
                try self.coerceTo(elem, ty, try self.lowerExpr(elem))
            else
                zeroOf(ty);
            try self.builder.writeVariable(slot.place, self.cur, if (hold)
                try self.holdSlot(try self.qualifyHeld(prefix, en), ty, init_val, slot.place)
            else
                init_val);
        }
        return;
    }

    const slot = try self.declareVar(name, ty);
    const init_val: Mir.Value = if (decl.init == .none)
        zeroOf(ty)
    else
        try self.coerceTo(decl.init, ty, try self.lowerExpr(decl.init));
    try self.builder.writeVariable(slot.place, self.cur, if (hold)
        try self.holdSlot(held_key, ty, init_val, slot.place)
    else
        init_val);
}

/// The `Instance` field name of a held slot carries the block path too, because
/// codegen derives one struct field per `held_vars` entry from it and two
/// blocks may spell a local the same way (§5.3.2's whole point).
fn qualifyHeld(self: *Lower, prefix: []const u8, name: []const u8) Oom![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(self.arena, "{s}{s}", .{ prefix, name });
}

/// §5.10. Give one event-assigned variable its persistent `Instance` slot and
/// return the Value that READS that slot.
///
/// The read replaces the declared initializer AT THE DECLARATION, which is the
/// whole reason the decision is made here and not at the assignment that
/// reveals it: a read of the variable that lexically precedes the `@(...)` must
/// also see the retained value, and by the time lowering reaches that
/// assignment the earlier read has already been resolved against the
/// initializer and memoized. Patching the entry def afterwards would leave it
/// stale.
///
/// `$held_real` / `$held_int` are synthetic callees — no LRM function has these
/// names, and `naming.isStatefulAnalogOp` rejects them, so they create no unit
/// and renumber no existing `Instance` state. The single argument is the index
/// into `held_vars`, which is how codegen recovers the field.
fn holdSlot(self: *Lower, name: []const u8, ty: Ty, init_val: Mir.Value, place: Ssa.Place) Oom!Mir.Value {
    // Emitted into the DECLARATION's block — `.entry`, unless the initializer
    // itself opened a diamond (§4.2.7 `&&`/`||` short-circuit), in which case it
    // is that diamond's join. Either way it dominates every statement of the
    // module, which is all the seed has to do.
    const idx: i64 = @intCast(self.held_vars.items.len);
    // Codegen makes one `Instance` field per entry out of `name`, so the name
    // has to be unique. It is — until a §6.6.1 unrolled `for` lowers the SAME
    // named block twice, which is two executions of one source declaration and
    // so, by §5.3.2, two locations that happen to share a path.
    var field = name;
    for (self.held_vars.items) |h| {
        if (!std.mem.eql(u8, h.name, name)) continue;
        field = try std.fmt.allocPrint(self.arena, "{s}.{d}", .{ name, idx });
        break;
    }
    const seed = try self.call(if (ty == .integer) "$held_int" else "$held_real", &.{try self.mir.addIntConst(self.arena, idx)});
    try self.held_vars.append(self.arena, .{
        .name = field,
        .ty = ty,
        .init = init_val,
        .seed = seed,
        .place = place,
    });
    return seed;
}

/// §5.10. Collect the variables assigned inside an `@(<event>)` body, before
/// any of them is declared.
fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.analog) |blk| try self.scanHeld(blk.body, false);
    self.held_frames.clearRetainingCapacity();
}

/// §5.3.2: "The block names give a means of uniquely identifying all variables
/// at any simulation time." Which location an assignment target names is
/// decided by the NEAREST declaration of it, so the walk looks outward from the
/// innermost named block and falls back to the bare (module-scope) name — a
/// module variable assigned from inside a block is still the module's.
fn heldKey(self: *Lower, name: []const u8) Oom![]const u8 {
    var i = self.held_frames.items.len;
    while (i > 0) {
        i -= 1;
        const f = self.held_frames.items[i];
        for (f.vars) |v| {
            if (!self.file.strings.eql(v.name, name)) continue;
            return std.fmt.allocPrint(self.arena, "{s}{s}", .{ f.prefix, name });
        }
    }
    return name;
}

/// One walk, two modes: outside an event body we are only looking for the
/// `@(...)`; inside one, every assignment target names a variable that has to
/// survive to the next evaluation.
fn scanHeld(self: *Lower, id: Ast.StmtId, in_event: bool) Oom!void {
    if (id == .none) return;
    switch (self.file.stmt(id)) {
        .block => |b| {
            // §5.3.2 only a NAMED block's locals are static, so only a label
            // opens a frame; an unnamed `begin`'s declarations are ordinary.
            const named = b.name != .none;
            if (named) {
                const outer = if (self.held_frames.getLastOrNull()) |f| f.prefix else "";
                try self.held_frames.append(self.arena, .{
                    .prefix = try std.fmt.allocPrint(self.arena, "{s}{s}.", .{ outer, self.file.str(b.name) }),
                    .vars = b.vars,
                });
            }
            for (b.body) |s| try self.scanHeld(s, in_event);
            if (named) _ = self.held_frames.pop();
        },
        .assign => |a| {
            if (!in_event) return;
            const ex = &self.file.exprs;
            // §3.2.2 `x[i] = …` holds the ARRAY; `declareVarDecl` scalarizes it.
            const t = if (ex.tag(a.target) == .index) ex.lhs(a.target) else a.target;
            if (ex.tag(t) != .ident) return;
            try self.held_names.put(self.arena, try self.heldKey(self.file.str(ex.strOf(t))), {});
        },
        .if_stmt => |s| {
            try self.scanHeld(s.then_s, in_event);
            try self.scanHeld(s.else_s, in_event);
        },
        .case_stmt => |s| for (s.arms) |arm| try self.scanHeld(arm.body, in_event),
        .for_stmt => |s| {
            try self.scanHeld(s.init, in_event);
            try self.scanHeld(s.step, in_event);
            try self.scanHeld(s.body, in_event);
        },
        .while_stmt => |s| try self.scanHeld(s.body, in_event),
        .repeat_stmt => |s| try self.scanHeld(s.body, in_event),
        // §5.10 forbids nesting, so `true` is never re-entered; lowering
        // diagnoses that (E0703) and this walk does not need to.
        .event_control => |s| try self.scanHeld(s.body, true),
        else => {},
    }
}

fn zeroOf(ty: Ty) Mir.Value {
    return switch (ty) {
        .real => .f_zero,
        .integer => .zero,
        .string => .undef,
    };
}

// ---------------------------------------------------------------------------
// Class 4 — statements (LRM §5)
// ---------------------------------------------------------------------------

/// Dispatch one statement. LRM §5.
pub fn lowerStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const tok = self.file.stmtTok(id);
    // Same provenance cursor as `lowerExpr`, for the instructions a statement
    // emits outside any expression (phis, jumps, accumulator writes).
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = tok;
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| try self.lowerSeqBlock(b), // §5.3
        .assign => |a| try self.lowerAssign(a.target, a.value), // §5.7
        .contribute => |c| try self.lowerContribute(c.lhs, c.rhs), // §5.6
        .indirect => |c| try self.lowerIndirect(tok, c.lhs, c.probe, c.eqn), // §5.6.7
        .if_stmt => |s| {
            if (s.is_generate) try self.checkGenScheme(tok, s.cond); // §6.6
            try self.lowerIf(s.cond, s.then_s, s.else_s); // §5.8
        },
        .case_stmt => |s| {
            if (s.is_generate) try self.checkGenScheme(tok, s.scrutinee); // §6.6
            try self.lowerCase(tok, s.kind, s.scrutinee, s.arms); // §5.8.3
        },
        .for_stmt => |s| try self.lowerFor(s.init, s.cond, s.step, s.body), // §5.9.2
        .while_stmt => |s| try self.lowerWhile(s.cond, s.body), // §5.9.1
        .repeat_stmt => |s| try self.lowerRepeat(s.count, s.body), // §5.9
        .event_control => |s| try self.lowerEventControl(s.event, s.body), // §5.10
        .event_trigger => |s| try self.lowerEventTrigger(tok, self.file.str(s.name)), // §5.10.4
        .disable => |s| try self.lowerDisable(tok, self.file.str(s.name)),
        .sys_task => |s| try self.lowerSysTask(tok, self.file.str(s.name), s.args),
        .jump => |j| try self.lowerJump(tok, j.kind, j.value),
    }
}

/// §5.10.4 / A.6.5 `event_trigger ::= -> hierarchical_event_identifier ;`.
/// Sets the event's flag for this timepoint; `@(ev)` reads it.
///
/// A.6.4 lists `event_trigger` under `analog_event_statement` and not under
/// `analog_statement`, so a trigger on the analog spine has no derivation. That
/// is NOT gated here: unlike `disable` (E0401), no fixture pins it, and the
/// accepted form is harmless — an unconditional trigger means "this event is
/// active every timepoint", which is what the source says. Add the
/// `!in_event_stmt` gate beside `lowerDisable`'s when a fixture asks.
fn lowerEventTrigger(self: *Lower, tok: u32, name: []const u8) Oom!void {
    const place = self.events.get(name) orelse
        return self.err(tok, .E0705, "`{s}`", .{name});
    try self.builder.writeVariable(place, self.cur, .one);
}

/// A.6.5 `disable_statement`. It is an alternative of A.6.4
/// `analog_event_statement` and of the digital A.6.4 `statement`, and is ABSENT
/// from `analog_statement` — so `@(<event>) disable <block>;` is the only form
/// an analog block can legally contain. There is no clause-5 section for
/// `disable` (5.11 is `jump_statement`: return/break/continue), so annex A is
/// the citation.
fn lowerDisable(self: *Lower, tok: u32, name: []const u8) Oom!void {
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    // A.6.5's operand is a block (or task) identifier and nothing else, so a
    // name that reaches no enclosing block label has no derivation. Searched
    // INNERMOST-first: §6.7 makes a block label a scope name, and the nearest
    // one is the one in scope.
    var i = self.named_blocks.items.len;
    while (i > 0) {
        i -= 1;
        const nb = self.named_blocks.items[i];
        if (!std.mem.eql(u8, nb.name, name)) continue;
        // §5.3: "the control shall pass out of the block after the last
        // statement is executed" — a disable passes out of it EARLY, which is
        // the same destination, so the statements AFTER the block still run.
        try self.gotoBlock(nb.exit);
        return self.startUnreachable();
    }
    // ponytail: hierarchical spellings (`disable top.dut.seg`) are not resolved
    // — elaboration flattens a label into the instance path, so an enclosing
    // block's flat name is what `name` already is. Walk the instance tree here
    // when a fixture disables a block it does not lexically enclose.
    var b = self.errWith(tok, .E0402);
    b.msg("`{s}` names no named block in scope", .{name});
    b.help("`disable` takes the label of an enclosing named block", .{});
    return b.emit();
}

/// §5.3.2 named sequential block: its declarations shadow for the block only.
fn lowerSeqBlock(self: *Lower, b: Ast.SeqBlock) Oom!void {
    const mark = self.scope_log.items.len;
    defer self.closeScope(mark);
    // §5.3.2's key for a local's static location, in step with `scanHeld`'s.
    const outer_path = self.block_path;
    defer self.block_path = outer_path;
    if (b.name != .none)
        self.block_path = try std.fmt.allocPrint(self.arena, "{s}{s}.", .{ outer_path, self.file.str(b.name) });
    for (b.params) |*p| try self.lowerParamDecl(p); // §5.3.2 local parameters
    try self.checkOneItemPerScope(b.vars);
    for (b.vars) |*v| try self.declareVarDecl(v, .local);
    if (b.name != .none) try self.publishBlockLocals(self.file.str(b.name), b);
    // §6.7 a labelled block is a scope, and A.6.5 lets `disable` name it. The
    // exit block is where control lands both ways — falling off the end and
    // being disabled — so the join is the same one either way.
    const exit: ?Mir.Block = if (b.name == .none) null else blk: {
        const e = try self.mir.addBlock(self.arena);
        try self.named_blocks.append(self.arena, .{ .name = self.file.str(b.name), .exit = e });
        break :blk e;
    };
    // ponytail: the only statement-list caller keeps its source-order loop here.
    for (b.body) |s| try self.lowerStmt(s);
    if (exit) |e| {
        _ = self.named_blocks.pop();
        try self.gotoBlock(e);
        try self.builder.sealBlock(e);
        self.cur = e;
    }
}

/// §5.3.2: "All identifiers declared within a named sequential block can be
/// accessed outside the scope in which they are declared." The block's scope is
/// popped by `closeScope`, so the outside spelling needs a SECOND binding that
/// is not shadow-logged — under `<label>.<local>`, which is the path
/// `flatName` already builds for `myscope.localVar`.
///
/// The assign direction stays closed: "Named block variables cannot be assigned
/// outside the scope of the block in which they are declared", which `lowerAssign`
/// refuses as E0316 because a `.hier_ident` is never an lvalue.
///
/// ponytail: last declaration wins when the same label runs twice (a §6.6.1
/// unrolled `for` body). Nothing can name one iteration's copy apart from
/// another, so there is nothing for an ordinal to disambiguate yet.
fn publishBlockLocals(self: *Lower, label: []const u8, b: Ast.SeqBlock) Oom!void {
    for (b.vars) |v| {
        const local = self.file.str(v.name);
        // Arrays are scalarized into `name[i]` entries, which have no scalar
        // slot under the bare name; §5.3.2's example is a scalar and no fixture
        // names an element hierarchically.
        const slot = self.vars.get(local) orelse continue;
        const q = try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ label, Elaborate.sep, local });
        try self.vars.put(self.arena, q, slot);
        try self.block_locals.put(self.arena, q, {});
    }
    // "Parameters declared within a named block have local scope" — local to
    // ASSIGNMENT, which §6.3 override already cannot reach; the read is the
    // same "all identifiers" sentence. They live in `consts`, so E0910 (a
    // variable read) never sees them.
    for (b.params) |p| {
        const c = self.consts.get(self.file.str(p.name)) orelse continue;
        const q = try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ label, Elaborate.sep, self.file.str(p.name) });
        try self.consts.put(self.arena, q, c);
    }
}

/// §5.7 procedural assignment. The target is an lvalue expression so array
/// elements (§3.2.2) work; both sides are coerced to the target's type
/// (§4.2.1.1/§4.2.1.2).
fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    // §3.2.2 whole-array assignment from an assignment pattern (§4.2.13):
    // both sides are scalarized, so this is an element-wise copy.
    if (ex.tag(target) == .ident and (ex.tag(value) == .assign_pattern or ex.tag(value) == .concat)) {
        const name = self.file.str(ex.strOf(target));
        if (self.arrays.get(name)) |info| {
            const elems = try self.flattenPattern(value, info.dims);
            var key_buf: [elem_key_len]u8 = undefined;
            var sub: [max_stack_dims]i64 = undefined;
            const idx = try self.subscriptBuf(&sub, info.dims.len);
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                shapeSubscripts(info.dims, k, idx);
                const slot = self.vars.get(try self.elemKey(&key_buf, name, idx)) orelse continue;
                const tv = try self.lowerExpr(elem);
                const v = try self.coerceTo(elem, slot.ty, tv);
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
            return;
        }
    }
    // §5.7 whole-array assignment from another ARRAY, `A = B`. The clause is a
    // shape rule, checked here and nowhere else because this is the only place
    // both shapes are in scope; when it holds the copy is element-wise, since
    // both sides are scalarized and there is no array Value to move.
    if (ex.tag(target) == .ident and ex.tag(value) == .ident) {
        const dst_name = self.file.str(ex.strOf(target));
        if (self.arrays.get(dst_name)) |dst| {
            if (try self.copyWholeArray(target, value, dst_name, dst)) return;
        }
    }
    // §3.2.2 `a[i] = …` with a RUNTIME index. The array is scalarized, so there
    // is no memory to store into: the write becomes one masked write per element,
    // which is the mirror image of the select chain `lowerIndex` already folds for
    // a runtime READ. §4.7.1's Example 3 (`arrayadd`) is why this has to exist —
    // its body is `for (i…) a[i] = a[i] + b[i]`, and `i` is an ordinary variable,
    // not a genvar, so nothing unrolls it.
    if (ex.tag(target) == .index) {
        if (try self.assignRuntimeIndex(target, value)) return;
    }
    const slot = try self.resolveLvalue(target) orelse {
        _ = try self.lowerExpr(value); // keep collecting errors from the rhs
        return;
    };
    const tv = try self.lowerExpr(value);
    const v = try self.coerceTo(value, slot.ty, tv);
    try self.builder.writeVariable(slot.place, self.cur, v);
    // §4.6.4: remember that this name now carries a noise source, so a later
    // `I(a,b) <+ n;` still exports the generator. Recorded AFTER the rhs is
    // lowered so the walk below sees the same expression the value came from.
    if (ex.tag(target) == .ident) {
        var srcs: std.ArrayList(NoiseSrc) = .empty;
        try self.noiseSrcsOf(value, &srcs);
        if (srcs.items.len != 0) {
            const g = try self.var_noise.getOrPut(self.arena, self.file.str(ex.strOf(target)));
            if (g.found_existing) {
                // Union by identity: re-lowering a loop body or a second
                // assignment through the same call is still one generator.
                for (g.value_ptr.*) |s| try addNoiseSrc(self.arena, &srcs, s);
            }
            g.value_ptr.* = srcs.items;
        }
    }
}

/// Runtime scalar-element assignment. Each cell receives `select(index == k,
/// value, old)`, leaving all other cells unchanged, including on an invalid index.
/// ponytail: N masked writes per assignment; replace scalarization with explicit
/// array storage if large mutable arrays make this compile-time expansion costly.
fn assignRuntimeIndex(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    var subs: [max_stack_dims]Ast.ExprId = undefined;
    const chain = (try self.indexChain(target, &subs)) orelse return false;
    var dynamic = false;
    for (chain.subs) |s| dynamic = dynamic or self.foldExpr(s, false) == null;
    if (!dynamic) return false;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse return false;
    if (!try self.checkSubscriptCount(target, name, info, chain.subs.len)) return true;

    const iv = try self.runtimeArrayIndex(chain.subs, info.dims);
    const tv = try self.lowerExpr(value);
    const new = try self.coerceTo(value, info.ty, tv);
    var key_buf: [elem_key_len]u8 = undefined;
    var sub: [max_stack_dims]i64 = undefined;
    const at = try self.subscriptBuf(&sub, info.dims.len);
    for (0..shapeCells(info.dims)) |k| {
        shapeSubscripts(info.dims, k, at);
        const key = try self.elemKey(&key_buf, name, at);
        const slot = self.vars.get(key) orelse {
            try self.err(self.file.exprs.mainTok(target), .E0312, "`{s}`", .{name});
            return true;
        };
        const old = try self.builder.readVariable(slot.place, self.cur);
        const c = try self.emit(.ieq, &.{ iv, try self.mir.addIntConst(self.arena, @intCast(k)) });
        try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ c, new, old }));
    }
    return true;
}

/// Flatten a full subscript tuple in declaration order. Check EACH dimension:
/// flattening unchecked `[i][j]` would let `j == columns` alias `[i+1][0]`.
/// Invalid tuples use -1; masked writes then preserve every element.
fn runtimeArrayIndex(self: *Lower, subs: []const Ast.ExprId, dims: []const Bounds) Oom!Mir.Value {
    var flat = Mir.Value.zero;
    var valid = Mir.Value.one;
    for (subs, dims) |s, d| {
        const index = try self.toInt(try self.lowerExpr(s));
        const lo = try self.mir.addIntConst(self.arena, d.lo);
        const hi = try self.mir.addIntConst(self.arena, d.hi);
        const in_range = try self.emit(.logand, &.{
            try self.emit(.ige, &.{ index, lo }),
            try self.emit(.ile, &.{ index, hi }),
        });
        valid = try self.emit(.logand, &.{ valid, in_range });
        // Keep invalid index arithmetic bounded too, even before the final mask.
        const bounded = try self.emit(.select, &.{ in_range, index, lo });
        const offset = if (d.descending)
            try self.emit(.isub, &.{ hi, bounded })
        else
            try self.emit(.isub, &.{ bounded, lo });
        flat = try self.emit(.iadd, &.{
            try self.emit(.imul, &.{ flat, try self.mir.addIntConst(self.arena, d.count()) }),
            offset,
        });
    }
    return self.emit(.select, &.{ valid, flat, try self.mir.addIntConst(self.arena, -1) });
}

/// §5.7 unpacked array assignment, `A = B`: "Array assignments shall only be
/// done with arrays that are compatible. An array, or a slice of such an array,
/// shall be assignment compatible with any other such array or slice if all the
/// following conditions are satisfied: — The element types of source and target
/// shall be equivalent. — Every dimension of the source array shall have the
/// same number of elements as the target array."
///
/// The clause counts ELEMENTS, not indices, and prints its own worked verdict:
/// `int A[10:1]; int B[0:9]; int C[24:1]; A = B;` is legal and `A = C` is not.
/// So the test is `count()` per dimension and never `lo`/`hi`.
///
/// Returns false when the right-hand side is not an array at all, so the
/// ordinary scalar path keeps its own diagnostics.
fn copyWholeArray(
    self: *Lower,
    target: Ast.ExprId,
    value: Ast.ExprId,
    dst_name: []const u8,
    dst: ArrayInfo,
) Oom!bool {
    const src_name = self.file.str(self.file.exprs.strOf(value));
    const src = self.arrays.get(src_name) orelse return false;

    if (src.dims.len != dst.dims.len) {
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        b.msg("array `{s}` has {d} dimensions and `{s}` has {d}", .{
            dst_name, dst.dims.len, src_name, src.dims.len,
        });
        try b.emit();
        return true;
    }
    for (dst.dims, src.dims, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        // The element COUNTS, not the bounds: `dimsBounds` normalizes `[10:1]`
        // to lo/hi, so printing them back is not the source's own spelling and
        // sends the reader looking for a declaration that is not there.
        b.msg("dimension {d} of array `{s}` holds {d} elements and `{s}` holds {d}", .{
            k, dst_name, d.count(), src_name, s.count(),
        });
        b.note("§5.7 counts elements, not indices: `A[10:1] = B[0:9]` is legal", .{});
        try b.emit();
        return true;
    }
    // "The element types of source and target shall be equivalent." §4.2.1.1's
    // integer/real conversions are NOT that: a `real` array and an `integer`
    // array hold different objects, and the clause has no coercion in it.
    if (src.ty != dst.ty) {
        var b = self.errWith(self.file.exprs.mainTok(target), .E0429);
        b.msg("array `{s}` holds `{s}` and `{s}` holds `{s}`", .{
            dst_name, @tagName(dst.ty), src_name, @tagName(src.ty),
        });
        try b.emit();
        return true;
    }

    var key_buf: [elem_key_len]u8 = undefined;
    var d_sub: [max_stack_dims]i64 = undefined;
    var s_sub: [max_stack_dims]i64 = undefined;
    const di = try self.subscriptBuf(&d_sub, dst.dims.len);
    const si = try self.subscriptBuf(&s_sub, src.dims.len);
    const n = shapeCells(dst.dims);
    for (0..n) |k| {
        shapeSubscripts(dst.dims, k, di);
        shapeSubscripts(src.dims, k, si);
        const v = (try self.arrayElemValue(src_name, si)) orelse continue;
        const slot = self.vars.get(try self.elemKey(&key_buf, dst_name, di)) orelse continue;
        // The element types are already known equivalent, so there is no
        // conversion to make here — only the source's `Value` to re-bind.
        try self.builder.writeVariable(slot.place, self.cur, v.v);
    }
    return true;
}

/// An assignable location: `x` or `x[<constant>]` (§3.2.2). Anything else is a
/// diagnostic rather than a silent no-op.
fn resolveLvalue(self: *Lower, e: Ast.ExprId) Oom!?VarSlot {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |s| return s;
            if (self.param_index.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0312);
                b.msg("`{s}`", .{name});
                b.help("declare a `real` variable if the value changes during the solve", .{});
                try b.emit();
                return null;
            }
            var b = self.errWith(self.file.exprs.mainTok(e), .E0313);
            b.msg("`{s}`", .{name});
            const near = diag.didYouMeanMap(name, self.vars) orelse
                diag.didYouMeanMap(name, self.param_index);
            if (near) |s| b.suggestHere(s);
            try b.emit();
            return null;
        },
        .index => {
            var subs: [max_stack_dims]Ast.ExprId = undefined;
            const chain = (try self.indexChain(e, &subs)) orelse {
                try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
                return null;
            };
            const name = self.file.str(chain.name);
            var idx: [max_stack_dims]i64 = undefined;
            const at = try self.subscriptBuf(&idx, chain.subs.len);
            for (chain.subs, at) |s, *o| {
                const c = self.constEval(s) orelse {
                    try self.err(self.file.exprs.mainTok(e), .E0311, "indexing `{s}`", .{name});
                    return null;
                };
                o.* = c.asInt();
            }
            return self.arrayElem(e, name, at);
        },
        // §5.7's third restriction: "Hierarchical assignment of a variable from
        // another scope/module is not allowed." Its own code because the generic
        // arm below would say "only `x` and `x[<constant>]`", which reads as a
        // VerA limitation — this one is a rule, and a variable in another scope
        // stays unwritable however much of §6.8 is implemented.
        .hier_ident => {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0316);
            b.msg("a hierarchical name is not an assignment target", .{});
            b.note("§5.7: \"Hierarchical assignment of a variable from another scope/module is not allowed\"", .{});
            try b.emit();
            return null;
        },
        // A.6.3: `{a, b} = ...` is net_lvalue/variable_lvalue, a different
        // production from the §4.2.13 expression, and it is not in the analog
        // subset (annex C). Named so the message does not blame the rhs.
        .concat, .multi_concat => {
            try self.err(self.file.exprs.mainTok(e), .E0317, "", .{});
            return null;
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
            return null;
        },
    }
}

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, idx: []const i64) Oom!?VarSlot {
    const info = self.arrays.get(name) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return null;
    };
    if (!try self.checkSubscripts(e, name, info, idx)) return null;
    var key_buf: [elem_key_len]u8 = undefined;
    return self.vars.get(try self.elemKey(&key_buf, name, idx));
}

/// The base identifier and the subscripts of `name[i][j]…` (§3.2), outermost
/// first. `null` when the base is not a plain name — `f(x)[0]` has no
/// scalarized element to resolve to.
///
/// Count the nested indices, then fill their slots from the end so the result
/// follows source order. Deep chains spill into the compilation arena.
const IndexChain = struct { name: Ast.StrId, subs: []const Ast.ExprId };
fn indexChain(self: *Lower, e: Ast.ExprId, buf: []Ast.ExprId) Oom!?IndexChain {
    const ex = &self.file.exprs;
    var n: usize = 0;
    var cur = e;
    while (ex.tag(cur) == .index) : (cur = ex.lhs(cur)) n += 1;
    if (ex.tag(cur) != .ident or ex.strOf(cur) == .none) return null;
    const subs = if (n <= buf.len) buf[0..n] else try self.arena.alloc(Ast.ExprId, n);
    const name = ex.strOf(cur);
    cur = e;
    var i = n;
    while (i > 0) {
        i -= 1;
        subs[i] = ex.rhs(cur);
        cur = ex.lhs(cur);
    }
    return .{ .name = name, .subs = subs };
}

/// §3.2: a reference supplies one subscript per declared dimension. Separate
/// from the range check below because a runtime subscript has a COUNT but no
/// value — and a caller that checked only the range would read `flag_array[3]`,
/// a whole ROW, as if it were a scalar.
fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool {
    if (n == info.dims.len) return true;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0356);
    b.msg("`{s}` is declared with {d} dimension(s) and is indexed with {d}", .{
        name, info.dims.len, n,
    });
    try b.emit();
    return false;
}

/// §3.2.2: each subscript inside its own dimension's declared bounds.
fn checkSubscripts(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, idx: []const i64) Oom!bool {
    if (!try self.checkSubscriptCount(e, name, info, idx.len)) return false;
    for (idx, info.dims, 0..) |i, d, k| {
        if (i >= d.lo and i <= d.hi) continue;
        try self.err(self.file.exprs.mainTok(e), .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
            i, k, name, d.lo, d.hi,
        });
        return false;
    }
    return true;
}

/// §4.7.1 `return`, §5.9 `break` / `continue`. All three close the current
/// block and continue into dead code, so statements after them are lowered but
/// unreachable (and dropped by codegen).
fn lowerJump(self: *Lower, tok: u32, kind: Ast.Stmt.JumpKind, value: Ast.ExprId) Oom!void {
    switch (kind) {
        .ret => {
            const rc = self.ret orelse {
                try self.err(tok, .E0403, "", .{});
                return;
            };
            if (value != .none) {
                const tv = try self.lowerExpr(value);
                const v = if (rc.slot.ty == .real) try self.toReal(tv) else try self.toInt(tv);
                try self.builder.writeVariable(rc.slot.place, self.cur, v);
            }
            try self.gotoBlock(rc.exit);
        },
        .brk, .cont => {
            const l = self.loops.getLastOrNull() orelse {
                try self.err(tok, .E0404, "`{s}`", .{if (kind == .brk) "break" else "continue"});
                return;
            };
            try self.gotoBlock(if (kind == .brk) l.brk else l.cont);
        },
    }
    try self.startUnreachable();
}

// ---------------------------------------------------------------------------
// Class 4 — contributions (LRM §5.6)
// ---------------------------------------------------------------------------

/// LRM §5.6. Resolve the branch, split the rhs into its resistive and reactive
/// halves (§5.6.1.2) and ACCUMULATE both into the target's places (§5.6.1.3).
///
/// Reference direction (§1.3.1.2) is carried by the (hi, lo) order alone —
/// codegen stamps `+val` at hi and `-val` at lo.
pub fn lowerContribute(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0405, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Contribution statements cannot be used inside an event control
    // block because it can generate discontinuity in analog signals"; A.6.4
    // `analog_event_statement` states it structurally.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0406, "", .{});
        return;
    }
    // §5.9, the third blanket restriction on `repeat`/`while`/non-genvar `for`:
    // "Contribution statements are not allowed". The set of branches a device
    // stamps is fixed before the solve, and a runtime trip count is not.
    //
    // `self.loops` is exactly the right question: only the three CFG loops push
    // onto it, and §5.9.3's genvar `for` is unrolled by `tryUnrollFor` before
    // `lowerFor` ever gets there — so an `analog for (i = 0; i < 4; ...)` over a
    // genvar contributes four times and never reaches here.
    if (self.loops.items.len != 0) {
        try self.err(self.file.exprs.mainTok(lhs), .E0426, "", .{});
        return;
    }
    const ex = &self.file.exprs;
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+." (§4.4 says the same of branch assignment.)
    if (ex.tag(lhs) == .port_access) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0407);
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        _ = try self.lowerExpr(rhs);
        return;
    }
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0408, "", .{});
        _ = try self.lowerExpr(rhs);
        return;
    }
    try self.checkZeroTransitionZFilter(rhs);
    const target = try self.branchOf(lhs) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot be
    // contributed to using the branch contribution operator <+."
    if (self.indirectOn(target.hi, target.lo)) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0409);
        b.msg("`{s}({s},{s})`", .{
            if (target.access == .potential) "V" else "I",
            self.nodeName(target.hi),
            self.nodeName(target.lo),
        });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }
    // §1.3.4.1 "In that case, potential contributions may not be made to
    // `input` ports"; §1.3.4.2 says the same of flow contributions. The port's
    // direction IS the direction of its one quantity, so an `input` is supplied
    // from outside and driving it has no meaning. Only `input` — contributing
    // to an `output` is the whole point of a signal-flow port, and an `inout`
    // signal-flow port never gets this far: E0360 refuses the declaration.
    for ([_]u16{ target.hi, target.lo }) |n| {
        if (n >= self.node_dir.items.len or self.node_dir.items[n] != .input) continue;
        if (!self.isSignalFlow(self.node_disciplines.items[n])) continue;
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0425);
        b.msg("`{s}` is an `input` port of discipline `{s}`", .{ self.node_order.items[n], self.node_disciplines.items[n] });
        try b.emit();
        return;
    }
    if (target.access == .flow) try self.checkMfactorDoubleScaling(lhs, rhs);
    const idx = try self.contribIndex(target, self.file.exprs.mainTok(lhs));

    // §5.6.6: while THIS statement's right-hand side lowers, a read of its own
    // target is the implicit form — see `contrib_target`.
    self.contrib_target = target;
    defer self.contrib_target = null;
    const split = try self.splitContribution(rhs);
    if (split.resist) |v| try self.checkFiniteContribution(lhs, v); // §7.3.2.1
    if (split.react) |v| try self.checkFiniteContribution(lhs, v);
    const acc = self.accum.items[idx];
    // §5.6.1.3 value retention, the half that is a REPLACEMENT and not a sum.
    // Before this statement's own value is added, anything retained for the
    // OTHER quantity of the same branch is thrown away.
    try self.discardOpposite(target);
    // §1.3.1.2: `I(n,p) <+ e` drives the same branch as `I(p,n) <+ -e`, so the
    // reversed spelling accumulates into the same source with the sign flipped.
    // Checked AFTER §7.3.2.1, which is about the value the source names and
    // does not care which way the branch was written.
    if (split.resist) |v0| {
        const v = if (target.neg) try self.emit(.fneg, &.{v0}) else v0;
        const old = try self.builder.readVariable(acc.resist, self.cur);
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    if (split.react) |v0| {
        const v = if (target.neg) try self.emit(.fneg, &.{v0}) else v0;
        const old = try self.builder.readVariable(acc.react, self.cur);
        try self.builder.writeVariable(acc.react, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    // §5.6.1.3 this statement RETAINS a value for its quantity on every path
    // that executes it — even `<+ 0.0`, whose retained zero is §5.6.5's closed
    // switch and not an absent source. A constant write: no MIR instruction,
    // and on a straight line no phi either.
    try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    // §4.6.4 the noise generators belong to the target, not to one statement,
    // and they ACCUMULATE: two `<+` lines on one branch declare two sources —
    // unless they reach the SAME source through a variable (§4.6.4.6), which
    // the identity dedup in `addNoiseSrc` keeps as one generator.
    {
        var srcs: std.ArrayList(NoiseSrc) = .empty;
        try srcs.appendSlice(self.arena, self.contributions.items[idx].noise_srcs);
        try self.noiseSrcsOf(rhs, &srcs);
        // §4.6.4.6 the per-use coefficient. It ADDS across statements, because
        // two `<+` lines on one branch sum into one source: `V(a,b) <+ c1*n`
        // followed by `V(a,b) <+ c2*n` drives the branch with (c1+c2)·n, and
        // `addNoiseSrc` has already collapsed them onto one row.
        //
        // Read off `split.resist`: a noise function is an amplitude, not a
        // reactive quantity, so the generator only ever appears in the
        // resistive half. The §1.3.1.2 sign flip is applied for the same
        // reason it is applied above — `I(n,p) <+ c*n` drives the branch
        // with −c, and the sign is what separates correlation from
        // anti-correlation.
        if (split.resist) |v0| {
            for (srcs.items) |*s| {
                if (s.nonlinear) continue;
                const g = self.noise_val.get(s.id) orelse continue;
                switch (try self.noiseCoeff(v0, g, 0)) {
                    .absent => {},
                    // No factor describes this use. Fall back to 1, which is
                    // what the export carried before coefficients existed, and
                    // stop accumulating so a later statement cannot make the
                    // row claim more than it knows.
                    .nonlinear => {
                        s.nonlinear = true;
                        s.coeff = .f_one;
                    },
                    .value => |d| {
                        const signed = if (target.neg) try self.coeffNeg(d) else d;
                        s.coeff = if (s.coeff == .f_zero) signed else try self.emit(.fadd, &.{ s.coeff, signed });
                    },
                }
            }
        }
        self.contributions.items[idx].noise_srcs = srcs.items;
    }
}

/// §6.3.6 the double-scaling misuse, which the clause states about a specific
/// printed module and calls an ERROR there:
///
///   "The first example, badres, misuses the $mfactor such that the contributed
///   current would be multiplied by $mfactor twice, once by the explicit
///   multiplication and once by the automatic scaling rule. The simulator will
///   generate an error for this module."
///
/// The automatic rule is the clause's first bullet — "all contributions to a
/// branch flow quantity in the analog block shall be multiplied by $mfactor" —
/// and the clause adds that "Verilog-AMS does not provide a method to disable"
/// it. So an explicit factor of $mfactor in a FLOW contribution cannot be an
/// opt-out; it can only be the second multiplication.
///
/// THE PREDICATE IS SCALING, NOT PRESENCE, and that is what keeps §6.3.6's own
/// legal companion legal: `parares` reads $mfactor in the CONDITION of an `if`
/// (`r/$mfactor < 1e-3`) and the clause says outright that "no error will be
/// generated for this module". So the test is `$mfactor` as an operand of a `*`
/// or a `/` inside the contributed value — division included, since dividing the
/// contribution by $mfactor is the same misuse read as an attempt to cancel the
/// automatic rule out.
///
/// Flow only: §6.3.6's automatic scaling is stated for flow contributions, so a
/// potential contribution has nothing for an explicit factor to double.
///
/// ponytail: the ceiling is a FLATTENED child, where elaboration has already
/// substituted `$mfactor` for the running product (elaborate.zig
/// `rewriteSysCall`) and there is no `sys_call` left to find. It only bites when
/// some ancestor actually specified a `.$mfactor(...)` — with none specified the
/// read is left as-is and this check sees it. The upgrade is to run this scan in
/// the clone, which needs the discipline table elaboration does not have.
fn checkMfactorDoubleScaling(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (!self.scalesByMfactor(rhs)) return;
    var b = self.errWith(self.file.exprs.mainTok(lhs), .E0912);
    b.msg("this flow contribution multiplies by `$mfactor`", .{});
    b.note("§6.3.6: every flow contribution is scaled by $mfactor automatically, and \"Verilog-AMS does not provide a method to disable\" it — so an explicit factor scales it twice", .{});
    b.help("delete the `$mfactor` factor; read it in a guard if the equation needs to know the multiplicity", .{});
    try b.emit();
}

/// Is the CONTRIBUTED VALUE a product in which `$mfactor` is a factor?
///
/// The walk follows the product SPINE of the right-hand side — mul, div and the
/// sign operators — and no further. That is the clause's own sentence read
/// literally: "the contributed current would be multiplied by $mfactor twice".
/// A `$mfactor` that multiplies one addend of a sum does not multiply the
/// contributed current; `mfactor.va` writes `I(p) <+ V(p) + 0.0 * $mfactor;` on
/// purpose, to read the parameter from the residual path, and that contribution
/// is `V(p)` — scaling it once is all that happens to it.
///
/// The precedent for stopping at the spine is `checkZeroTransitionZFilter` above:
/// where the LRM states a rule about the value assigned to a branch, a scan of
/// the whole subtree invents a rule about expressions the clause declines to
/// state. The known hole is `I <+ V/r * $mfactor + off`, which is a misuse this
/// does not catch; the LRM gives no rule for the mixed case and `badres` is not
/// it.
fn scalesByMfactor(self: *Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .mul, .div => self.isMfactorRead(ex.lhs(e)) or self.isMfactorRead(ex.rhs(e)) or
                self.scalesByMfactor(ex.lhs(e)) or self.scalesByMfactor(ex.rhs(e)),
            else => false,
        },
        .unary => switch (ex.unOp(e)) {
            .plus, .minus => self.scalesByMfactor(ex.lhs(e)),
            else => false,
        },
        else => false,
    };
}

/// A read of §9.18's `$mfactor`, under either of its two spellings: the system
/// function itself, or the §3.4.7 `aliasparam m = $mfactor;` name for it — the
/// alias is a second name for one location, so it is the same read.
fn isMfactorRead(self: *Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "$mfactor"),
        .ident => if (self.mfactor_param) |pi|
            self.param_index.get(self.file.str(ex.strOf(e))) == pi
        else
            false,
        else => false,
    };
}

/// §4.5.12, the two sentences that are one rule: "If the transition time is
/// specified as zero (0), then the output is abruptly discontinuous. A Z-filter
/// with zero (0) transition time shall not be directly assigned to a branch."
///
/// A zero τ is LEGAL — the same clause makes τ optional and "nonnegative", and
/// reading the discontinuous output into a variable is fine. What is banned is
/// putting the discontinuity straight into the equation system, where a branch
/// quantity that steps instantaneously has no derivative for Newton-Raphson.
/// So the target of the rule is the STATEMENT, which is why the check lives
/// here and not beside the operator's other argument checks.
///
/// DIRECTLY: the filter call has to BE the right-hand side. `V(x) <+ 2*zi_zp(…)`
/// is arithmetic over the filter's output and the clause does not reach it —
/// the LRM says "directly assigned", and a scan of the whole subtree would
/// invent a rule about expressions the clause declines to state.
///
/// An absent τ is not a zero one: it means the sampler's own default, which is
/// the simulator's business (§4.5.12 leaves it unstated) and is not the
/// "specified as zero" the sentence conditions on.
fn checkZeroTransitionZFilter(self: *Lower, rhs: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    if (ex.tag(rhs) != .filter_call) return;
    if (!std.mem.startsWith(u8, self.file.str(ex.strOf(rhs)), "zi_")) return;
    // zi_*(expr, numerator, denominator, T [, τ [, t0]]) — A.8.2.
    const args = ex.args(rhs);
    if (args.len < 5 or args[4] == .none) return;
    const tau = self.constEval(args[4]) orelse return;
    if (tau.asReal() != 0.0) return;
    var b = self.errWith(self.file.exprs.mainTok(rhs), .E0518);
    b.msg("a Z-filter with zero (0) transition time shall not be directly assigned to a branch", .{});
    b.help("read it into a variable first, then contribute the variable", .{});
    try b.emit();
}

/// §7.3.2.1: "While use of these special numbers in digital expressions is not
/// an error, it is illegal to assign these values to a branch through
/// contribution in the analog context."
///
/// Compile time only, and that boundary is the clause's own scope rather than a
/// limitation to apologise for: §7.3.2.1 is about a value the SOURCE names, and
/// with `inf` confined by annex A to a value_range_expression the only way to
/// write one is the IEEE arithmetic the clause itself describes — 1.0/0.0,
/// -1.0/0.0, 0.0/0.0. A value that goes infinite only at some operating point
/// is W0650's business, and W0650 is a different claim: "not provably finite",
/// not "provably not finite".
///
/// SUBEXPRESSIONS, not the whole contribution. A branch value almost always
/// contains a probe, so `bad + 0.0*V(p)` folds to nothing as a unit; the scan
/// folds every subtree it can and accuses the first one that is not finite.
fn checkFiniteContribution(self: *Lower, lhs: Ast.ExprId, v: Mir.Value) Oom!void {
    var bad: ?f64 = null;
    _ = self.scanFinite(v, 0, &bad);
    const x = bad orelse return;
    try self.err(self.file.exprs.mainTok(lhs), .E0424, "{s}", .{
        if (std.math.isNan(x)) "contribution of a NaN" else "contribution of an infinite value",
    });
}

/// Fold `v0` where it is constant, recording the first non-finite result in
/// `bad`. Returns null for anything not constant — a probe, a parameter (the
/// host overrides it, so its declared default proves nothing), a call — but
/// keeps walking into it, because the offending constant is normally one
/// operand of a sum that is not constant.
///
/// Not `analysis.foldConst`: that wants a built `Analysis`, which does not
/// exist until lowering has finished, and this rule has to be reported on the
/// `<+` that broke it.
///
/// ponytail: arithmetic and sign only. `exp(1000)` overflows to +inf as well,
/// but §7.3.2.1's examples are IEEE division and every operator added here
/// widens the surface for a false accusation. Add the transcendentals the day a
/// model writes one.
fn scanFinite(self: *const Lower, v0: Mir.Value, depth: u32, bad: *?f64) ?f64 {
    if (depth > 32) return null;
    const v = self.mir.resolveAlias(v0);
    const r: ?f64 = switch (self.mir.valueDef(v)) {
        .float_const => |x| x,
        .int_const => |x| @as(f64, @floatFromInt(x)),
        .inst_result => |inst| blk: {
            const row = self.mir.instRow(inst);
            switch (Mir.opClass(row.op)) {
                .unary => {
                    const a = self.scanFinite(@enumFromInt(row.a), depth + 1, bad) orelse break :blk null;
                    break :blk switch (row.op) {
                        .fneg, .ineg => -a,
                        .fabs, .iabs => @abs(a),
                        .if_cast, .opt_barrier => a,
                        else => null,
                    };
                },
                .binary => {
                    // Both sides walked before either is tested: the scan is
                    // the point, the fold is only how it gets there.
                    const a = self.scanFinite(@enumFromInt(row.a), depth + 1, bad);
                    const b = self.scanFinite(@enumFromInt(row.b), depth + 1, bad);
                    const x = a orelse break :blk null;
                    const y = b orelse break :blk null;
                    break :blk switch (row.op) {
                        .fadd => x + y,
                        .fsub => x - y,
                        .fmul => x * y,
                        .fdiv => x / y,
                        else => null,
                    };
                },
                else => break :blk null,
            }
        },
        else => null,
    };
    if (r) |x| {
        if (!std.math.isFinite(x) and bad.* == null) bad.* = x;
    }
    return r;
}

/// LRM §5.6.7 indirect branch contribution — `V(out) : V(in) == e;`, read
/// "drive V(out) so that V(in) == e".
///
/// Topologically identical to a direct potential contribution: `out` is driven
/// by a source whose current is a solver unknown, and codegen stamps that
/// current at hi/lo. Only the constitutive row differs — it is
///
///     <probe> − <equation>
///
/// with NO `V(hi,lo)` term, because "the source voltage needs to be adjusted so
/// that the given equation is satisfied": the branch voltage is the free
/// variable, not a term of the constraint. Row ORIENTATION is probe − equation
/// (not the reverse); for a symmetric equation like the ideal opamp both signs
/// converge to the same point, but an asymmetric one does not.
///
/// "Any branches referenced in the equation are only probed and not driven" —
/// that falls out for free: `lowerExpr` on `V(in)` produces a probe, and only
/// the entry appended here ever reaches codegen's stamping loop.
fn lowerIndirect(self: *Lower, tok: u32, lhs: Ast.ExprId, probe_e: Ast.ExprId, eqn: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0410, "not allowed in {s}", .{ctx});
        return;
    }
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0411, "", .{});
        return;
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional or
    // looping statements, unless the conditional expression is a constant
    // expression." A constant condition never reaches here (see `cond_depth`).
    if (self.cond_depth != 0) {
        try self.err(tok, .E0412, "the condition is not a constant expression", .{});
        return;
    }
    const ex = &self.file.exprs;
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0413, "", .{});
        return;
    }
    // §5.6.7 "The left-hand side of the equality operator must either be an
    // access function, or ddt, idt or idtmod applied to an access function."
    if (!self.isIndirectProbe(probe_e)) {
        var b = self.errWith(self.file.exprs.mainTok(probe_e), .E0414);
        b.help("use an access function, or `ddt`/`idt`/`idtmod` applied to one", .{});
        try b.emit();
        return;
    }
    const target = try self.branchOf(lhs) orelse return;
    // §5.6.7.2 incompatible with a direct contribution across the same pair of
    // analog nets — checked on the accumulator ENTRY, since `<+` statements are
    // deduped across statements and across if-arms.
    for (self.contributions.items) |c| {
        if (c.kind != .direct) continue;
        if (!samePair(c.hi, c.lo, target.hi, target.lo)) continue;
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0415);
        b.msg("`({s},{s})`", .{ self.nodeName(target.hi), self.nodeName(target.lo) });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }

    const p = try self.toReal(try self.lowerExpr(probe_e));
    const e = try self.toReal(try self.lowerExpr(eqn));
    const row = try self.emit(.fsub, &.{ p, e });

    // Its own entry, never `contribIndex`: §5.6.7.1 allows several indirect
    // contributions, each of which is a separate source and equation.
    const idx = try self.newContrib(.indirect, target, self.file.exprs.mainTok(lhs));
    try self.builder.writeVariable(self.accum.items[idx].resist, self.cur, row);
}

/// §1.3.1: "The potential and flow of a probe branch may not both appear in
/// expressions in a given module." §5.4.2.1 states it as the ban — "using both
/// the potential and the flow of a probe branch is illegal" — and gives the
/// reason: it pins ONE of a probe's quantities at zero, the potential of a flow
/// probe or the flow of a potential probe, and which one is decided by which
/// the module reads. Reading both asks for two zeros at once.
///
/// A SWEEP and not a test at the read, because the classification depends on
/// contributions that may be lowered later: §1.3.1 makes a branch a probe by
/// nothing ever appearing on the left of its `<+`, which is only knowable once
/// the whole module is lowered. A source branch is exempt — §5.4.2.2 makes both
/// of its quantities accessible.
fn checkProbeBranches(self: *Lower) Oom!void {
    // ponytail: O(reads²) over one module's access functions. A pair map keyed
    // on the unordered node pair if a model ever makes this measurable.
    for (self.branch_reads.items, 0..) |a, i| {
        for (self.branch_reads.items[i + 1 ..]) |b| {
            if (a.access == b.access or !samePair(a.hi, a.lo, b.hi, b.lo)) continue;
            if (self.contributedOn(a.hi, a.lo)) continue;
            var d = self.errWith(b.tok, .E0423);
            d.msg("both quantities of the probe branch (`{s}`, `{s}`) are read", .{
                self.nodeName(a.hi), self.nodeName(a.lo),
            });
            d.note("nothing is contributed to that branch, so §1.3.1 makes it a probe; contribute to it to make it a source, or read only one quantity", .{});
            try d.emit();
            return; // one report per module: the second pair is the same defect
        }
    }
}

/// Is anything contributed to this node pair — directly (§5.6.1) or indirectly
/// (§5.6.7)? That is exactly §1.3.1's test for "not a probe".
fn contributedOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.contributions.items) |c| {
        if (samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// §5.6.7.2 "the same pair of analog nets (or any of its parallel branches)" —
/// unordered, since (a,b) and (b,a) are the same pair with opposite reference
/// directions (§1.3.1.2).
fn samePair(a_hi: u16, a_lo: u16, b_hi: u16, b_lo: u16) bool {
    return (a_hi == b_hi and a_lo == b_lo) or (a_hi == b_lo and a_lo == b_hi);
}

fn indirectOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.contributions.items) |c| {
        if (c.kind == .indirect and samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// A.8.3 `indirect_expression`: a branch/port probe, or ddt/idt/idtmod of one.
/// The optional tolerance/initial-condition arguments are ordinary expressions
/// and are not restricted.
fn isIndirectProbe(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (e == .none) return false;
    switch (ex.tag(e)) {
        .branch_access, .port_access => return true,
        .filter_call => {},
        else => return false,
    }
    const name = self.file.str(ex.strOf(e));
    const is_op = std.mem.eql(u8, name, "ddt") or
        std.mem.eql(u8, name, "idt") or
        std.mem.eql(u8, name, "idtmod");
    if (!is_op) return false;
    const args = ex.args(e);
    if (args.len == 0) return false;
    return switch (ex.tag(args[0])) {
        .branch_access, .port_access => true,
        else => false,
    };
}

/// A resolved access. `hi`/`lo` are in CANONICAL order (`hi < lo` as node_order
/// indices, which puts `ground` — `maxInt(u16)` — last, so `V(n)` is untouched);
/// `neg` says the source wrote the terminals the other way round.
///
/// §1.3.1.2 associated reference directions: "A positive flow enters a branch
/// through the port marked with the plus sign and exits the branch through the
/// port marked with the minus sign." So `a,b` and `b,a` are ONE branch named
/// twice, and its two spellings differ by a sign — for the flow and for the
/// potential alike.
///
/// Canonicalising here rather than at each use is what makes that true
/// everywhere at once: `flowUnknown` mints one unknown per branch instead of an
/// independent second one for the reversed pair, `contribIndex` accumulates
/// both spellings into one source, and codegen — which reconstructs the
/// `flow(a,b)` NAME from a contribution's `hi`/`lo` to find the slot lowering
/// already allocated — only ever sees the one spelling, so nothing downstream
/// needs to know the rule exists.
const Target = struct {
    access: Access,
    hi: u16,
    lo: u16,
    neg: bool = false,
    /// §5.4.1 the branch this reference names — a `BranchInfo.id` for a declared
    /// name, `unnamed_branch` for the pair's one implicit branch. Carried beside
    /// the pair rather than instead of it: the pair is what codegen stamps and
    /// what §5.6.7.2's "or any of its parallel branches" is stated over.
    br: u32 = unnamed_branch,
};

/// The key a branch reference has in `branches`: `br` for a scalar branch,
/// `br[k]` for one element of a §3.12 vector branch. `null` when the
/// expression cannot name a branch at all (a two-terminal access, a
/// non-constant index), which is not an error here — `nodeOf` reads the same
/// expression as a net reference and reports whatever is wrong with it.
fn branchKey(self: *Lower, buf: *[elem_key_len]u8, e: Ast.ExprId) Oom!?[]const u8 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        // §5.5.5 "A module is allowed to access the potential and flow of a
        // branch in another module instance", and §6.7.1's first bullet says it
        // of the name: "Potential and flow access for named and unnamed
        // branches (including port branches) can be done hierarchically." The
        // resolution is `nodeOf`'s exactly: elaboration cloned the child's
        // BranchDecl under `path.name` (Ruling E), so the §6.7 path IS the key
        // `branches`/`port_branches` already hold, and `flatName` is the whole
        // join. A miss is not an error HERE — the caller falls through to
        // `nodeOf`, whose `.hier_ident` arm owns E0901 and, like this path,
        // mints nothing on failure (a wrong path names no branch anywhere).
        // Arena rather than `buf`: cold, one path per source reference.
        .hier_ident => try self.flatName(e),
        // Into the caller's buffer, not the arena: both consumers do nothing
        // with the result but `branches.get`/`port_branches.get`, which never
        // retain a key — and this runs once per §4.4.1 ACCESS, so `br[0]` in an
        // unrolled loop body was minting a fresh string per iteration. `elemKey`.
        .index => blk: {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) break :blk null;
            const i = self.constEval(ex.rhs(e)) orelse break :blk null;
            break :blk try self.elemKey(buf, self.file.str(ex.strOf(base)), &.{i.asInt()});
        },
        else => null,
    };
}

/// The port a §3.12.1 port branch names, when the single argument of an access
/// function is one. `null` for everything else, including a two-argument
/// access — a port branch is a name, never a pair.
fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u16 {
    if (self.file.exprs.rhs(e) != .none) return null;
    var key_buf: [elem_key_len]u8 = undefined;
    const key = try self.branchKey(&key_buf, self.file.exprs.lhs(e)) orelse return null;
    return self.port_branches.get(key);
}

fn canonical(access: Access, hi: u16, lo: u16, br: u32) Target {
    return if (hi <= lo)
        .{ .access = access, .hi = hi, .lo = lo, .br = br }
    else
        .{ .access = access, .hi = lo, .lo = hi, .neg = true, .br = br };
}

/// §4.4.1 resolve `V(a)`, `V(a,b)`, `I(br)` to (access, node pair).
fn branchOf(self: *Lower, e: Ast.ExprId) Oom!?Target {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return null;
    };
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+", and §3.12.1 makes a named port branch the same
    // function under another name. `lowerBranchAccess` — the READ path, the one
    // place a port branch means something — has already peeled it off above, so
    // everything still arriving here is an lvalue or an indirect-assignment
    // probe. ponytail: `ddx(f, I(pb))` also lands here and gets this message,
    // which names the right clause and the wrong position; no fixture writes it,
    // and the honest fix is §4.5.6 deciding whether a port flow is a valid
    // derivative unknown at all.
    if (try self.portBranchOf(e)) |_| {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0407);
        b.msg("`{s}` is a port branch (3.12.1)", .{self.file.str(ex.strOf(ex.lhs(e)))});
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        return null;
    }
    const first = ex.lhs(e);
    // §3.12 a single argument naming a declared branch — `br`, or `br[k]` for
    // an element of a vector branch, which `declareVectorBranch` registered
    // under exactly that scalarised name. The miss falls through to `nodeOf`,
    // which owns every diagnostic about a bad index.
    if (ex.rhs(e) == .none) {
        var key_buf: [elem_key_len]u8 = undefined;
        if (try self.branchKey(&key_buf, first)) |key| {
            if (self.branches.get(key)) |b| {
                try self.checkAccessMatch(e, name, access, b.hi);
                return canonical(access, b.hi, b.lo, b.id);
            }
        }
    }
    const hi = try self.nodeOf(first);
    const lo = if (ex.rhs(e) == .none) ground else try self.nodeOf(ex.rhs(e));
    try self.checkAccessMatch(e, name, access, hi);
    // §3.11's own example of the rule: "if an access function has two nets as
    // arguments, they must be compatible".
    try self.checkNetCompat(ex.mainTok(e), hi, lo);
    // §4.4 Table 4-16 gives both `V(n1,n1)` and `I(n1,n1)` as `Error`, and the
    // prose under it is normative for the flow half: "If two net expressions
    // are given as arguments to a flow access function, they shall not evaluate
    // to the same signal." A branch from p to p is not a zero-potential branch;
    // it is not a branch. Annex G Table G.1 records why the spelling exists at
    // all — `I(a,a)` was the OVI v1.0 port flow, replaced by `I(<a>)`.
    //
    // Only the TWO-argument form: `V(n)` is `V(n, gnd)` by §1.3.1.1 and is not
    // written with a repeated signal, so `V(gnd)` stays legal.
    //
    // Ground is exempt as a PAIR, not as an oversight. §1.3.1.1 collapses every
    // `ground` net onto the one global reference node, so `V(g1, g2)` over two
    // separately declared grounds lands on hi == lo == ground while naming two
    // different signals — which Table 4-16 does not forbid, and which
    // ch01_intro/24 and annex_h_glossary/08 both assert reads 0.
    // ponytail: that also lets the literal `V(g1, g1)` through. Catching it
    // needs a name comparison the interned index has already thrown away, and
    // no fixture writes it.
    if (ex.rhs(e) != .none and hi == lo and hi != ground) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}({s}, {s})` names one signal twice", .{ name, self.nodeName(hi), self.nodeName(lo) });
        if (access == .flow)
            b.help("the flow into a port is `{s}(<{s}>)` (5.4.3)", .{ name, self.nodeName(hi) });
        try b.emit();
        return null;
    }
    return canonical(access, hi, lo, unnamed_branch);
}

/// §5.5.1 Syntax 5-3 `nature_access_function ::= nature_attribute_identifier |
/// potential | flow`. Spelled out as constants because they are the one pair of
/// access names that is not read out of a §3.6.1.4 `access =` attribute.
const generic_potential = "potential";
const generic_flow = "flow";

/// §4.4: "The access function name shall match the discipline declaration for
/// the nets, ports, or branch given in the argument expression list."
///
/// `access_kind` alone cannot answer this — it is the global set of access
/// names, so every name that belongs to SOME discipline resolves on EVERY net,
/// and `V(n)` quietly read a net whose discipline names its potential something
/// else. The discipline of the node is what decides.
///
/// Three separate failures live here, and they are three because a net can be
/// wrong in three different ways:
///
///  - E0337, no discipline at all. §3.6.5 makes the implicit net legal AS A
///    DECLARATION, so this cannot fire where the net is created — only here, on
///    the access, which is what §3.6.3 ("such nets can not be used in analog
///    behavioral descriptions") and §6.5.2.1 ("can only be used in a structural
///    description") actually forbid.
///  - E0501 with no `want`, the discipline binds no nature for this half:
///    natureless (`ddiscrete`, `\logic`, a bare `discipline x; enddiscipline`)
///    or the wrong half of a signal-flow pair (`I` on annex D's `voltage`).
///    §1.3.4 puts it plainest — "flow for such a node is not defined".
///  - E0501 with a `want`, the §3.6.1.4 name mismatch.
///
/// The last two share a code because they are one sentence of §4.4: the name
/// does not match the discipline. They differ only in whether there is a
/// spelling to suggest, which is a note, not a rule.
fn checkAccessMatch(self: *Lower, e: Ast.ExprId, name: []const u8, access: Access, node: u16) Oom!void {
    if (node == ground) return;
    const dname = self.node_disciplines.items[node];
    if (dname.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0337);
        b.msg("`{s}` has no discipline, so `{s}` names nothing on it", .{ self.nodeName(node), name });
        b.note("§3.6.2.4 treats a net with no discipline that is referenced in behavioral code as discrete; declare one, e.g. `electrical {s};`", .{self.nodeName(node)});
        try b.emit();
        return;
    }
    const info = self.disciplines.get(dname) orelse return;
    const want = switch (access) {
        .potential => info.potential_access,
        .flow => info.flow_access,
    };
    const half = if (access == .potential) "potential" else "flow";
    if (want.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}` is not an access function of `{s}`", .{ name, self.nodeName(node) });
        b.note("`{s}` is of discipline `{s}`, which binds no {s} nature, so `{s}` has no {s} to access", .{
            self.nodeName(node), dname, half, self.nodeName(node), half,
        });
        try b.emit();
        return;
    }
    if (std.mem.eql(u8, want, name)) return;
    // §4.4: "As an alternative to using the access attribute specified in the
    // discipline, the generic potential and flow access functions are also
    // supported." So `potential`/`flow` are exempt from the name match, and
    // ONLY from it — the two checks above still apply, and must: §5.5.1's
    // generic spelling reaches a nature, not a bare node, so a natureless or
    // half-bound discipline has nothing for it to read either.
    if (std.mem.eql(u8, name, generic_potential) or std.mem.eql(u8, name, generic_flow)) return;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
    b.msg("`{s}` is not an access function of `{s}`", .{ name, self.nodeName(node) });
    b.suggestHere(want);
    b.note("`{s}` is of discipline `{s}`, whose {s} nature declares `access = {s}`", .{
        self.nodeName(node),
        dname,
        half,
        want,
    });
    try b.emit();
}

/// Find or create the accumulator pair for one contribution target. A pair
/// that receives BOTH a potential and a flow contribution (in different arms)
/// is the §5.6.5 switch branch — two entries, one per access.
fn contribIndex(self: *Lower, t: Target, tok: u32) Oom!u32 {
    for (self.contributions.items, 0..) |c, i| {
        // §5.6.7.2 an indirectly-assigned branch is never an accumulation
        // target, so its entry can never absorb a `<+` (which `lowerIndirect`
        // rejects outright anyway).
        if (c.kind != .direct) continue;
        // §5.4.1: the pair does not identify the branch, so `br` is part of the
        // key. Two named branches over one pair get one accumulator each; every
        // spelling of the pair's UNNAMED branch shares the one §5.4.1 Example 2
        // allows it.
        if (c.access == t.access and c.hi == t.hi and c.lo == t.lo and c.br == t.br) return @intCast(i);
    }
    return self.newContrib(.direct, t, tok);
}

/// Append a fresh contribution + its accumulator pair. The two tables stay
/// parallel; see the UNIT ORDERING note in proof.zig.
fn newContrib(self: *Lower, kind: Kind, t: Target, tok: u32) Oom!u32 {
    const idx: u32 = @intCast(self.contributions.items.len);
    try self.contributions.append(self.arena, .{
        .access = t.access,
        .br = t.br,
        .tok = tok,
        .hi = t.hi,
        .lo = t.lo,
        .kind = kind,
        .unit = self.cur_unit,
    });
    const acc: Accum = .{
        .resist = self.builder.newPlace(),
        .react = self.builder.newPlace(),
        .wrote = self.builder.newPlace(),
    };
    // Seeded in the entry block, which dominates everything: a contribution
    // that only happens on one arm of an `if` reads 0 on the other (§5.8) —
    // and per §5.6.1.3 retains nothing there, which is what `wrote` starts as.
    try self.builder.writeVariable(acc.resist, .entry, .f_zero);
    try self.builder.writeVariable(acc.react, .entry, .f_zero);
    try self.builder.writeVariable(acc.wrote, .entry, .f_zero);
    try self.accum.append(self.arena, acc);
    return idx;
}

/// §5.6.1.3 "Contributing a flow to a branch which already has a value retained
/// for the potential results in the potential being discarded and the branch
/// being converted to a flow source. Similarly, contributing a potential to a
/// branch which already has a flow retained results in the flow being
/// discarded." Only contributions of the SAME kind are additive, so a kind
/// mismatch replaces rather than accumulates — which is the whole difference
/// between the clause's own worked example answering 7.0 (1 discarded by the
/// flow, the flow discarded by the 3, then 3 + 4) and answering 8.0.
///
/// Zeroing the other accumulator is the whole implementation, because a zeroed
/// accumulator emits NO row: `emitResidual` skips a contribution whose folded
/// value is `.f_zero`. So an unconditional discard deletes the source from the
/// device, which is what "discarded" means, and a zero FLOW source is in any
/// case §5.4.4's open circuit — the state the branch is in when nothing is
/// retained for it.
///
/// Under a conditional the discard survives as a phi rather than a constant —
/// and so does the `wrote` flag cleared beside it, which is the whole §5.6.5
/// switch branch: codegen reads both ends' flags and selects the branch row's
/// content at run time (retained potential → potential source, retained flow →
/// flow source, neither → §5.6.1.3's open circuit).
fn discardOpposite(self: *Lower, t: Target) Oom!void {
    const other: Access = if (t.access == .potential) .flow else .potential;
    for (self.contributions.items, self.accum.items) |c, acc| {
        if (c.kind != .direct or c.access != other or c.hi != t.hi or c.lo != t.lo) continue;
        // §5.6.1.3 is stated of "a branch", so only the OTHER quantity of THIS
        // branch is discarded. A parallel named branch over the same pair is a
        // different source and keeps what it retained.
        if (c.br != t.br) continue;
        // And so is a parallel INSTANCE over the same pair. §5.4.1 gives branch
        // identity per module instance; flattening collapses every instance's
        // unnamed branch onto the node pair, so without this a load wired across
        // a source deletes the source — `resistor load(p,n)` beside
        // `vsine v1(p,n)`, which is the first circuit anyone draws.
        if (c.unit != self.cur_unit) continue;
        try self.builder.writeVariable(acc.resist, self.cur, .f_zero);
        try self.builder.writeVariable(acc.react, self.cur, .f_zero);
        try self.builder.writeVariable(acc.wrote, self.cur, .f_zero);
    }
}

const Split = struct { resist: ?Mir.Value, react: ?Mir.Value };

/// LRM §5.6.1.2 — separate the ddt terms (§4.5.3) into the reactive part.
///
/// The split is structural, on the ADDITIVE terms of the rhs: a term free of
/// `ddt` is resistive; a term containing one is reactive, and its reactive
/// value is the term with the `ddt` stripped (`C*ddt(V)` → `C*V`), i.e. the
/// charge/flux whose time derivative codegen's q() differentiates. That is
/// exact whenever `ddt` appears once along a multiplicative spine of the term,
/// which is what §5.6.1.2's charge formulation means. Anything else (`ddt`
/// inside a call, two `ddt`s multiplied) is a diagnostic — never silently the
/// wrong physics.
fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split {
    var out: Split = .{ .resist = null, .react = null };
    try self.splitTerm(rhs, false, &out);
    return out;
}

fn splitTerm(self: *Lower, e: Ast.ExprId, negate: bool, out: *Split) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .add => {
                try self.splitTerm(ex.lhs(e), negate, out);
                try self.splitTerm(ex.rhs(e), negate, out);
                return;
            },
            .sub => {
                try self.splitTerm(ex.lhs(e), negate, out);
                try self.splitTerm(ex.rhs(e), !negate, out);
                return;
            },
            else => {},
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return self.splitTerm(ex.lhs(e), negate, out),
            .minus => return self.splitTerm(ex.lhs(e), !negate, out),
            else => {},
        },
        else => {},
    }

    if (self.containsDdt(e)) {
        const t = try self.lowerReactive(e) orelse return;
        try self.accumulate(&out.react, try self.finishReactive(t), negate);
    } else {
        const v = try self.toReal(try self.lowerExpr(e));
        try self.accumulate(&out.resist, v, negate);
    }
}

fn accumulate(self: *Lower, slot: *?Mir.Value, v: Mir.Value, negate: bool) Oom!void {
    if (slot.*) |old| {
        slot.* = try self.emit(if (negate) .fsub else .fadd, &.{ old, v });
    } else {
        slot.* = if (negate) try self.emit(.fneg, &.{v}) else v;
    }
}

/// Does this subtree contain a `ddt` (§4.5.3)? Cheap recursive scan — the
/// expression store is SoA, so this is a few column reads per node.
fn containsDdt(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .filter_call, .call, .builtin_call, .sys_call, .noise_call => {
            if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return true;
            for (ex.args(e)) |a| if (self.containsDdt(a)) return true;
            return false;
        },
        .ternary => return self.containsDdt(ex.lhs(e)) or self.containsDdt(ex.rhs(e)) or
            self.containsDdt(ex.ternaryElse(e)),
        else => return self.containsDdt(ex.lhs(e)) or self.containsDdt(ex.rhs(e)),
    }
}

/// One reactive term with its multiplicative spine split apart: `b` is the
/// `ddt` operand, `coeff` the accumulated product of everything that rode
/// outside the ddt (null = 1), `coeff_nonconst` whether any factor depends
/// on an unknown (literals/params have zero gradient and need no site).
const ReactiveTerm = struct { b: Mir.Value, coeff: ?Mir.Value = null, coeff_nonconst: bool = false };

fn coeffIsConst(self: *const Lower, v: Mir.Value) bool {
    return switch (self.mir.valueKind(v)) {
        .float_const, .int_const, .undef, .param_ref => true,
        else => false,
    };
}

/// LRM semantics of `A*ddt(B)` is A·dB/dt — the CAPACITANCE form: the
/// stamped current carries no B·dA/dt (measured with the plain-product
/// lowering: MESA Cgg inflated up to 2.17x, oscillator period 21% slow).
/// A non-constant A becomes a path-integrated charge, ngspice's own
/// construction (NIintegrate on the increment, mesaload.c:341-344):
///
///     q = pq + A·(B − pb)      pb = B at last accept, pq = Σ committed A·ΔB
///
/// The base (pb, pq) is FIXED across one Newton attempt and advances only at
/// `stateCtl(.commit)` (operating-point exit, transient accepted step), so
///  - the committed charge increment is A·ΔB: capacitance-form physics;
///  - at any committed point ΔB = 0, so the C-plane is exactly A·∂B/∂x (AC);
///  - within a step the residual is one smooth function whose AD Jacobian
///    carries dA only as (dA/dx)·ΔB — the legitimate Newton term that
///    vanishes as dt→0. The earlier per-iterate freeze latch instead solved
///    the product-form residual with the dA term deleted from the Jacobian:
///    a quasi-Newton whose error gain grows with α = 1/dt, which is exactly
///    the mesa_oscillator/hfet_inverter/mos6_inverter timestep wedge.
fn finishReactive(self: *Lower, t: ReactiveTerm) Oom!Mir.Value {
    const c = t.coeff orelse return t.b; // plain ddt(B): q = B, exact
    // Constant/param coefficient: dA ≡ 0, the plain product IS the
    // capacitance form (and pq/pb with zero init would reproduce it).
    if (!t.coeff_nonconst) return try self.emit(.fmul, &.{ c, t.b });
    const pb = try self.emit(.path_prev, &.{t.b});
    const d = try self.emit(.fmul, &.{ c, try self.emit(.fsub, &.{ t.b, pb }) });
    return try self.emit(.fadd, &.{ try self.emit(.path_acc, &.{d}), d });
}

fn mulCoeff(self: *Lower, t: *ReactiveTerm, c: Mir.Value, op: Mir.Opcode) Oom!void {
    t.coeff = if (t.coeff) |old|
        try self.emit(op, &.{ old, c })
    else if (op == .fdiv)
        try self.emit(.fdiv, &.{ try self.mir.addFloatConst(self.arena, 1.0), c })
    else
        c;
    t.coeff_nonconst = t.coeff_nonconst or !self.coeffIsConst(c);
}

/// The charge/flux of a reactive term: strip exactly one `ddt` from a
/// multiplicative spine (§5.6.1.2), collecting the spine's coefficients
/// LIVE (no gradient suppression — `finishReactive` decides the form).
fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?ReactiveTerm {
    const ex = &self.file.exprs;
    spine: switch (ex.tag(e)) {
        .filter_call => {
            if (self.file.strings.eql(ex.strOf(e), "ddt")) {
                const args = ex.args(e);
                // A.8.2 gives a filter no `analog_expression_or_null` form, so
                // an OMITTED slot (`ddt(,1.0)`) is as wrong as no argument at
                // all. `lowerFilter` already rejects it on the non-reactive
                // path; this reactive spine bypasses that call and has to
                // agree (§4.5.14).
                if (args.len == 0 or args[0] == .none) {
                    try self.err(self.file.exprs.mainTok(e), .E0502, "", .{});
                    return null;
                }
                // args[1] (abstol/nature, §4.5.3) only affects tolerance, so
                // it is not lowered — but it still has to be LEGAL, on the same
                // grounds as the E0502 agreement above: this spine bypasses
                // `lowerFilter`, where §5.5.3's ban on a non-constant attribute
                // reference is otherwise reached through `lowerExpr`.
                if (args.len > 1) _ = try self.lowerAbstolArg(args[1]);
                return .{ .b = try self.toReal(try self.lowerExpr(args[0])) };
            }
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return self.lowerReactive(ex.lhs(e)),
            .minus => {
                var t = try self.lowerReactive(ex.lhs(e)) orelse return null;
                // Sign rides the coefficient (constness unchanged: negation
                // adds no unknown dependence).
                t.coeff = if (t.coeff) |old| try self.emit(.fneg, &.{old}) else try self.mir.addFloatConst(self.arena, -1.0);
                return t;
            },
            else => {},
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                const l_has = self.containsDdt(ex.lhs(e));
                const r_has = self.containsDdt(ex.rhs(e));
                if (l_has and r_has) break :spine;
                if (l_has) {
                    var t = try self.lowerReactive(ex.lhs(e)) orelse return null;
                    try self.mulCoeff(&t, try self.toReal(try self.lowerExpr(ex.rhs(e))), .fmul);
                    return t;
                }
                const c = try self.toReal(try self.lowerExpr(ex.lhs(e)));
                var t = try self.lowerReactive(ex.rhs(e)) orelse return null;
                try self.mulCoeff(&t, c, .fmul);
                return t;
            },
            .div => {
                if (self.containsDdt(ex.rhs(e))) break :spine; // ddt in a divisor
                var t = try self.lowerReactive(ex.lhs(e)) orelse return null;
                try self.mulCoeff(&t, try self.toReal(try self.lowerExpr(ex.rhs(e))), .fdiv);
                return t;
            },
            else => {},
        },
        else => {},
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0503);
    b.help("assign the derivative to a variable, then use that variable in the contribution", .{});
    try b.emit();
    return null;
}

/// §4.6.4 every small-signal noise source in one expression, appended to `out`
/// in first-appearance order, deduplicated by generator identity.
///
/// A SET and a full walk, not the first hit: `I(a,b) <+ white_noise(k) +
/// flicker_noise(kf, 1.0)` declares two generators on one branch, and so do two
/// separate `<+` lines (see `NoiseSrc`). Dedup is by `id`, so a variable named
/// in both arms of a ?: still counts its generator once, while two textually
/// separate calls of the same kind stay two generators (§4.6.4.6: "each noise
/// function generates noise which is uncorrelated").
/// §4.6.4.1/.2/.3 the optional `name`, read straight off the AST rather than
/// recorded by `lowerNoise`: the label is a string LITERAL in the source, so
/// the call node still carries it here and a side map would only be a second
/// copy to keep in step.
///
/// The name is the TRAILING string argument of a call that has more than one,
/// which is the one rule all three forms share — `white_noise(pwr, name)`,
/// `flicker_noise(pwr, exp, name)`, `noise_table(input, name)`. The arity test
/// is what keeps §4.6.4.3's one-argument `noise_table("file.tbl")` a FILENAME
/// and not a label.
fn noiseName(self: *const Lower, e: Ast.ExprId) []const u8 {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) return "";
    const last = args[args.len - 1];
    if (last == .none or ex.tag(last) != .str_literal) return "";
    return self.file.str(ex.strOf(last));
}

/// §4.6.3 `ac_stim`'s LEADING string argument — the analysis the stimulus is
/// active in. A.8.2 puts the quotation marks inside the production
/// (`ac_stim ( [ " analysis_identifier " …`), so a literal is the only spelling
/// there is; "ac" is the clause's own default for the absent one.
///
/// The opposite end of the call from `noiseName`, and that is the whole
/// difference between the two: §4.6.4's label is trailing and optional, §4.6.3's
/// analysis name is leading and selects the analysis. Sharing one reader would
/// have read `ac_stim("ac", 2.0, 0.0)` as unnamed and `ac_stim("noise")` as a
/// noise LABEL rather than as the analysis it names.
fn acAnalysisName(self: *const Lower, e: Ast.ExprId) []const u8 {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len == 0 or args[0] == .none or ex.tag(args[0]) != .str_literal) return "ac";
    return self.file.str(ex.strOf(args[0]));
}

fn noiseSrcsOf(self: *const Lower, e: Ast.ExprId, out: *std.ArrayList(NoiseSrc)) error{OutOfMemory}!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a STIMULUS,
            // not a noise source; listing it in `noise_gens` would invent a
            // noise generator the model never declared. It is the ONLY name in
            // this grammar that is not a generator — §4.6.4.3/.4's tables are
            // generators whose PSD happens to be a table, and they carry it in
            // `NoiseSrc.table` rather than in `pwr`/`exp`. It is collected
            // HERE, on the same walk, and separated by `kind` in codegen, which
            // is what gives the stimulus §4.6.4.6's "assigned to a variable
            // first" path without a second copy of this function.
            const kind: NoiseKind = if (std.mem.eql(u8, n, "white_noise"))
                .thermal // §4.6.4.1
            else if (std.mem.eql(u8, n, "flicker_noise"))
                .flicker // §4.6.4.2
            else if (std.mem.eql(u8, n, "noise_table"))
                .table // §4.6.4.3
            else if (std.mem.eql(u8, n, "noise_table_log"))
                .table_log // §4.6.4.4
            else if (std.mem.eql(u8, n, "ac_stim"))
                .ac_stim // §4.6.3
            else
                return;
            const psd = self.noise_psd.get(@intFromEnum(e)) orelse
                if (kind == .ac_stim) [2]Mir.Value{ .f_one, .f_zero } // §4.6.3 mag 1, phase 0
                else [2]Mir.Value{ .f_zero, .f_one };
            try addNoiseSrc(self.arena, out, .{
                .kind = kind,
                .id = @intFromEnum(e),
                .pwr = psd[0],
                .exp = psd[1],
                .table = self.noise_tab.get(@intFromEnum(e)) orelse &.{},
                .tok = ex.mainTok(e),
                .name = if (kind == .ac_stim) self.acAnalysisName(e) else self.noiseName(e),
            });
        },
        // §4.6.4.6's own spelling: the source was assigned to a variable and
        // the contribution names the variable. Without this the walk stops at
        // the identifier and the generator is never exported — and the shared
        // `id` the map carries is what keeps two such uses ONE generator.
        .ident => {
            const srcs = self.var_noise.get(self.file.str(ex.strOf(e))) orelse return;
            for (srcs) |s| try addNoiseSrc(self.arena, out, s);
        },
        .call, .builtin_call, .sys_call, .filter_call => {
            for (ex.args(e)) |a| try self.noiseSrcsOf(a, out);
        },
        // §4.2.12 ?: — its third operand lives in `extra`, which the lhs/rhs
        // catch-all cannot see (same shape as `containsDdt`). Both arms count:
        // a SET of declared generators is what this walk collects, and which
        // arm the solve takes does not undeclare the other one.
        .ternary => {
            try self.noiseSrcsOf(ex.lhs(e), out);
            try self.noiseSrcsOf(ex.rhs(e), out);
            try self.noiseSrcsOf(ex.ternaryElse(e), out);
        },
        else => {
            try self.noiseSrcsOf(ex.lhs(e), out);
            try self.noiseSrcsOf(ex.rhs(e), out);
        },
    }
}

/// Append one generator unless its identity is already in the list.
fn addNoiseSrc(arena: std.mem.Allocator, out: *std.ArrayList(NoiseSrc), s: NoiseSrc) error{OutOfMemory}!void {
    for (out.items) |x| if (x.id == s.id) return;
    try out.append(arena, s);
}

// ---------------------------------------------------------------------------
// Class 4 — control flow (LRM §5.8, §5.9)
// ---------------------------------------------------------------------------

/// §6.6: "All expressions in generate schemes shall be constant expressions,
/// deterministic at elaboration time." The scheme of an if-generate is its
/// condition and of a case-generate its selector; the loop generate's three
/// parts are E0417-E0419, judged in `tryUnrollFor` where the unroll needs them.
///
/// `constEval`, NOT `foldExpr(..., false)`: a `parameter` is a `constant_primary` (A.8.4)
/// and §6.6's stated purpose is "the ability for parameter values to affect the
/// structure of the model", so a parameterized scheme is exactly what the clause
/// is for. What it excludes is a module variable or anything reading the
/// solution — the things `constEval` returns null for.
///
/// Reported and then lowered anyway: a scheme VerA cannot fold is still lowered
/// as the §5.8 runtime branch it looks like, so a second mistake inside the
/// selected arm is reported in the same run.
///
/// ponytail: a scheme this accepts is not necessarily FOLDED. `foldExpr(..., false)` keeps
/// refusing a parameter on purpose — folding it to its declared default would
/// compile the arm the model card did not ask for — so a parameterized generate
/// becomes a runtime diamond over both arms instead of one elaborated arm. Same
/// behavior, different structure, and nothing VerA emits can observe the
/// difference until §6.6.1's per-instance declarations exist.
fn checkGenScheme(self: *Lower, tok: u32, scheme: Ast.ExprId) Oom!void {
    if (self.constEval(scheme) != null) return;
    var b = self.errWith(tok, .E0428);
    b.help("a generate scheme may read parameters and genvars, not variables", .{});
    try b.emit();
}

/// §5.8 conditional. A constant-foldable condition lowers only the taken arm —
/// that is also what makes `generate if` (§6.6.2) collapse at elaboration.
fn lowerIf(self: *Lower, cond: Ast.ExprId, then_s: Ast.StmtId, else_s: Ast.StmtId) Oom!void {
    if (self.foldExpr(cond, false)) |c| {
        return self.lowerStmt(if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try self.lowerExpr(cond));
    try self.lowerBranchStmt(c, then_s, else_s, self.isAnalysisOrConst(cond));
}

/// Lower a body that only runs under a RUNTIME condition. The wrapper carries
/// §5.6.7's ban on indirect contributions in a non-constant conditional or loop
/// and §5.8.1/§5.9's ban on analog operators in one; the constant-folded paths
/// (`lowerIf`'s fold, `tryUnrollFor`) call `lowerStmt` directly and are
/// therefore unrestricted, which is exactly the "unless the conditional
/// expression is a constant expression" carve-out.
///
/// `static` is the WEAKER §5.8.1 carve-out — an `analysis_or_constant_expression`
/// rather than a constant one. It relaxes E0514 alone; `cond_depth` still rises,
/// so the two constant-only rules keep rejecting the same code they did.
fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try self.lowerStmt(body);
}

/// A.8.3 `analysis_or_constant_expression` — the §5.8.1 carve-out. True when
/// nothing in the tree can change between one Newton iteration and the next:
/// literals, `parameter`s and `analysis()` calls, combined with operators.
///
/// Deliberately NOT `foldExpr(..., false)`: that folds to a VALUE and refuses a parameter
/// on purpose (a model card overrides it), while this asks the different
/// question of whether the value is fixed for the whole analysis. A parameter
/// is `constant_primary` in A.8.4 and cannot move mid-solve, so it qualifies.
fn isAnalysisOrConst(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk false;
            break :blk self.param_index.contains(name) or self.consts.contains(name);
        },
        // A.8.2 analysis_function_call. Its value is fixed for the analysis,
        // which is the whole reason §5.8.1 spells out "analysis_or_constant".
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "analysis"),
        .unary => self.isAnalysisOrConst(ex.lhs(e)),
        .binary => self.isAnalysisOrConst(ex.lhs(e)) and self.isAnalysisOrConst(ex.rhs(e)),
        .ternary => self.isAnalysisOrConst(ex.lhs(e)) and
            self.isAnalysisOrConst(ex.rhs(e)) and
            self.isAnalysisOrConst(ex.ternaryElse(e)),
        else => false,
    };
}

fn lowerBranchStmt(
    self: *Lower,
    cond: Mir.Value,
    then_s: Ast.StmtId,
    else_s: Ast.StmtId,
    static: bool,
) Oom!void {
    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);

    try self.branchTo(cond, then_b, else_b, true);

    self.cur = then_b;
    try self.lowerCondBody(then_s, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    try self.lowerCondBody(else_s, static);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.8.3 case — lowered as the equality chain the LRM defines it to be: the
/// first matching arm wins, `default` is the final else. `casex`/`casez` have
/// no meaning for a real scrutinee (annex C).
fn lowerCase(
    self: *Lower,
    tok: u32,
    kind: Ast.CaseKind,
    scrutinee: Ast.ExprId,
    arms: []const Ast.CaseArm,
) Oom!void {
    if (kind != .normal) {
        var b = self.errWith(tok, .E0416);
        b.help("use `case`", .{});
        try b.emit();
        return;
    }
    const sv = try self.lowerExpr(scrutinee);
    var default_arm: Ast.StmtId = .none;
    var defaults: usize = 0;
    for (arms) |a| {
        if (a.labels.len != 0) continue;
        defaults += 1;
        default_arm = a.body;
    }
    // §5.8.3: "The default statement is optional. Use of multiple default
    // statements in one case statement is illegal." Nothing in the clause
    // orders them, so a second one leaves the fall-through arm ambiguous —
    // which is why this is a well-formedness rule and not a preference.
    // Reported once for the statement, and lowering carries on with the last
    // one so a second, unrelated mistake in the same case is still reported.
    if (defaults > 1) {
        var b = self.errWith(tok, .E0427);
        b.msg("{d} `default` arms", .{defaults});
        try b.emit();
    }
    // §5.8.1 applies to `case` word for word: the arm LABELS are constants by
    // A.6.7, so whether an arm is decided before the solve turns entirely on
    // the scrutinee.
    try self.lowerCaseChain(sv, arms, default_arm, self.isAnalysisOrConst(scrutinee));
}

fn lowerCaseChain(
    self: *Lower,
    sv: TypedValue,
    arms: []const Ast.CaseArm,
    default_arm: Ast.StmtId,
    static: bool,
) Oom!void {
    if (arms.len == 0) return self.lowerStmt(default_arm);
    const a = arms[0];
    if (a.labels.len == 0) return self.lowerCaseChain(sv, arms[1..], default_arm, static);

    // §5.8.3 an arm with several labels matches any of them.
    var cond: ?Mir.Value = null;
    for (a.labels) |l| {
        const eq = try self.cmp(.eq, sv, try self.lowerExpr(l));
        cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(cond.?, then_b, else_b, true);

    self.cur = then_b;
    try self.lowerCondBody(a.body, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    try self.lowerCaseChain(sv, arms[1..], default_arm, static);
    self.static_cond_depth -= @intFromBool(static);
    self.cond_depth -= 1;
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.9.1 `while`. Braun order: the header is sealed only after the back edge.
fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, NOT `header`: a §4.2.7 short-circuit (`while (i<=4 && f(x))`)
    // splits the condition across blocks of its own and leaves `cur` at the
    // join. Branching from `header` regardless appended a SECOND terminator to
    // a block that already ended in the `&&`'s branch — the join and the rhs
    // block then had no predecessor, codegen never emitted them, and the loop
    // branched on a temporary nothing ever assigned. Same hazard as `?:` in a
    // condition. Pinned by codegen.zig's test "§5.9.1 a short-circuit loop
    // condition still reaches the loop's branch".
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = header });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(header);
    _ = self.loops.pop();

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// §5.9 `repeat (n)` — the LRM's counted loop, lowered as an integer countdown.
fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const n = try self.toInt(try self.lowerExpr(count));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, n);

    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    const cur_i = try self.builder.readVariable(place, step_b);
    try self.builder.writeVariable(place, step_b, try self.emit(.isub, &.{ cur_i, .one }));
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// §5.9.2 `for`. If the loop variable is a genvar (§3.5) the whole loop is
/// unrolled at elaboration (§6.6.1) — that is the only form allowed to appear
/// in a generate region, and it is what makes `genvar`-indexed nets work.
fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void {
    if (try self.tryUnrollFor(init_s, cond, step, body)) return;

    try self.lowerStmt(init_s);
    const header = try self.mir.addBlock(self.arena);
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.mir.addBlock(self.arena);
    const step_b = try self.mir.addBlock(self.arena);
    const exit = try self.mir.addBlock(self.arena);
    // `self.cur`, not `header` — see `lowerWhile`: the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    try self.branchTo(c, body_b, exit, false);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    try self.lowerStmt(step);
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Bound on §6.6.1 unrolling: a runaway genvar loop is a source bug, not a
/// reason to emit a million instructions.
const max_unroll: u32 = 4096;

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop).
fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    const gv = self.genvarOf(init_s) orelse return false;
    const start = self.constEval(self.assignValueOf(init_s).?) orelse {
        try self.err(self.file.exprs.mainTok(cond), .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    try self.consts.put(self.arena, gv, start);
    // Visible to `queueDisplay`'s snapshot while the body lowers.
    try self.active_genvars.append(self.arena, gv);
    defer _ = self.active_genvars.pop();

    var n: u32 = 0;
    while (n < max_unroll) : (n += 1) {
        const c = self.constEval(cond) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        try self.lowerStmt(body);
        const next = self.constEval(self.assignValueOf(step) orelse .none) orelse {
            try self.err(self.file.exprs.mainTok(cond), .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    if (n == max_unroll)
        try self.err(self.file.exprs.mainTok(cond), .E0420, "gave up after {d} iterations", .{max_unroll});
    _ = self.consts.remove(gv);
    return true;
}

/// The genvar assigned by a `for` init statement, if any (§3.5).
fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    const m = self.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    return null;
}

fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    if (s == .none) return null;
    const st = self.file.stmt(s);
    return if (st == .assign) st.assign.value else null;
}

// ---------------------------------------------------------------------------
// Class 7 — events (LRM §5.10)
// ---------------------------------------------------------------------------

/// LRM §5.10. An analog event control runs its body only when the event is
/// active, so it lowers to a guard: the event itself becomes a `call` whose
/// integer result codegen answers from the simulator state (§5.10.2 global
/// events, §5.10.3 monitored events).
pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(event), .E0702, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Nested event control statements are not allowed" — and A.6.4
    // agrees: `analog_event_statement` has no
    // `analog_event_control_statement` alternative.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(event), .E0703, "", .{});
        return;
    }
    // §5.8 "Event control statements (e.g.: timer, cross) cannot be used inside
    // conditional statements unless the conditional expression is a constant
    // expression"; §5.9 bans them in repeat/while/non-genvar for outright;
    // §5.10.3.1 repeats it for `cross`. STRICTER than E0514 on purpose — the
    // carve-out here is a constant expression, so `analysis("dc")` does not
    // license it and `static_cond_depth` is deliberately not consulted.
    if (self.cond_depth != 0) {
        var b = self.errWith(self.file.exprs.mainTok(event), .E0707);
        b.help("put `@(...)` on the spine and make the statement it guards conditional", .{});
        try b.emit();
    }
    const cond = try self.lowerEventExpr(event) orelse return;
    const prev = self.in_event_stmt;
    self.in_event_stmt = true;
    defer self.in_event_stmt = prev;
    // §5.10 an event's `hit` flag changes during the solve, so it is never static.
    try self.lowerBranchStmt(cond, body, .none, false);
}

/// §5.10.1 or-lists, §5.10.2 initial_step/final_step, §5.10.3 cross/above/timer.
fn lowerEventExpr(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        // §5.10.1 `@(a or b)` — active when either is.
        .event_or => {
            const a = try self.lowerEventExpr(ex.lhs(e)) orelse return null;
            const b = try self.lowerEventExpr(ex.rhs(e)) orelse return null;
            return try self.emit(.logor, &.{ a, b });
        },
        // §5.10.2 global events; the analysis-name arguments select which
        // analyses they fire in (`initial_step("dc","tran")`).
        .event_initial_step, .event_final_step => {
            const name = if (ex.tag(e) == .event_initial_step) "initial_step" else "final_step";
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            if (ex.extraOf(e) < ex.pool.items.len) {
                for (ex.nameParts(e)) |p|
                    try args.append(self.arena, try self.mir.addStrConst(self.arena, self.file.str(p)));
            }
            return try self.call(name, args.items);
        },
        // §5.10.3 monitored events.
        .event_function => {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "absdelta")) {
                // §5.10.3 absdelta monitors a digital-domain delta; it has no
                // analog kernel semantics. (Wording pinned by
                // tests/fixtures/ch05_analog_behavior/absdelta_digital_only.)
                try self.err(self.file.exprs.mainTok(e), .E0513, "", .{});
                return null;
            }
            try self.checkEventArgBounds(e, name); // §5.10.3.1/§5.10.3.2
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            for (ex.args(e)) |a| {
                // A.6.5 permits omitted arguments; keep the position.
                if (a == .none) {
                    try args.append(self.arena, .f_zero);
                    continue;
                }
                try args.append(self.arena, try self.toReal(try self.lowerExpr(a)));
            }
            return try self.call(name, args.items);
        },
        .event_posedge, .event_negedge => {
            try self.err(self.file.exprs.mainTok(e), .E0704, "", .{});
            return null;
        },
        // §5.10.4 `@ hierarchical_event_identifier` — the event's flag IS the
        // guard. IN SCOPE for Verilog-A: §5.10 lists named events as one of the
        // three kinds of ANALOG event, and annex C.7 excludes only DIGITAL
        // behavior and events (§5.10.5's named events are the ones a digital
        // process triggers, which is the mixed-signal case).
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.events.get(name)) |p| return try self.builder.readVariable(p, self.cur);
            try self.err(self.file.exprs.mainTok(e), .E0705, "`{s}`", .{name});
            return null;
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0706, "", .{});
            return null;
        },
    }
}

/// §5.10.3.1/§5.10.3.2 argument rules for the monitored events, quoted in full
/// under E0517. Three rules, and they are three because they fail apart: a
/// non-integer direction, a negative tolerance, and a tolerance with no
/// direction beside it.
///
/// `timer` is deliberately absent. §5.10.3.3 gives it start_time/period/
/// time_tol with no direction slot at all, and its own sentences about them are
/// about scheduling, not sign — so it gets no rule here rather than a borrowed
/// one.
///
/// Same restraint as `checkFilterArgBounds`: Syntax 5-16 types every one of
/// these `analog_expression`, so only what folds is judged.
fn checkEventArgBounds(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    const is_cross = std.mem.eql(u8, name, "cross");
    if (!is_cross and !std.mem.eql(u8, name, "above")) return;
    const args = self.file.exprs.args(e);
    // §5.10.3.2 above() has no direction: its tolerances start one slot earlier.
    const dir: ?usize = if (is_cross) 1 else null;
    const tol_first: usize = if (is_cross) 2 else 1;

    if (dir) |d| if (d < args.len and args[d] != .none) {
        if (self.constEval(args[d])) |c| {
            const v = c.asReal();
            // "shall evaluate to integers". Only a folded NON-integral value is
            // refused: 0.5 selects no direction, while a real spelled 1.0 does
            // evaluate to one and the clause's complaint would be typographic.
            if (c != .str and v != @round(v))
                try self.err(self.file.exprs.mainTok(args[d]), .E0517, "`cross()` direction shall evaluate to an integer, got {d}", .{v});
        }
    };

    var tol_given = false;
    for (tol_first..@min(tol_first + 2, args.len)) |i| {
        if (args[i] == .none) continue;
        tol_given = true;
        const c = self.constEval(args[i]) orelse continue;
        if (c == .str) continue;
        const v = c.asReal();
        if (v >= 0) continue;
        try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`{s}()` {s} shall be non-negative, got {d}", .{
            name,
            if (i == tol_first) "time_tol" else "expr_tol",
            v,
        });
    }

    // "If either or both tolerances are defined, then the direction shall also
    // be defined." Elision as such is legal — §5.10.3.1's own `sh` example
    // writes `cross(V(smpl) - thresh, dir, , , en === 1'b1)` — so the accusation
    // is the missing DIRECTION and not the comma.
    if (tol_given) if (dir) |d| {
        if (d >= args.len or args[d] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
            b.msg("a tolerance is given but the direction slot is empty", .{});
            b.help("write the direction explicitly; `0` is \"either edge\"", .{});
            try b.emit();
        }
    };
}

// ---------------------------------------------------------------------------
// ch9 — system tasks (statement position)
// ---------------------------------------------------------------------------

/// §5.12/ch9 analog system task. Display/file tasks are void calls codegen may
/// drop; the deliberately-unsupported set is rejected by exact name.
fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(tok, .E0806, "`{s}`", .{name});
        return;
    }
    // §9.7.2, final sentence: "The $stop task shall not be used within an
    // analog initial block." Positional, not a support question — $stop in an
    // ordinary analog block is legal, and §9.7.1 goes out of its way to define
    // what its sibling $finish means in an analog initial block.
    if (self.in_analog_initial and std.mem.eql(u8, name, "$stop")) {
        try self.err(tok, .E0807, "", .{});
        return;
    }
    // §9.13 Table 9-10 in statement position. They are FUNCTIONS, so a bare
    // `$random(s);` is only ever written for the seed's inout side effect — which
    // is exactly what `lowerRandom` performs; the variate is dropped.
    if (try self.lowerRandom(tok, name, args)) |_| return;
    // §9.4.3's pairing rule is stated for the display tasks and §9.5.2 defines
    // the file ones as "the same as their counterparts", so it covers both — and
    // `checkFormatPairing` picks the format as "the first argument that folds to a
    // string", which steps over the descriptor without being told about it.
    if (isDisplayTask(name) or isFileOutTask(name)) try self.checkFormatPairing(tok, args);
    // §9.5.3/§9.5.4.2: all three of these write through an argument, which is
    // not something a `call` result can do — see `lowerStringWrite`/`lowerScan`.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat"))
        return self.lowerStringWrite(tok, name, args);
    if (std.mem.eql(u8, name, "$sscanf")) {
        _ = try self.lowerScan(tok, args); // the count is the value; a statement drops it
        return;
    }
    // §9.5.4: the same shape as `$sscanf` for the same reason — a destination
    // argument. In statement position the count is dropped, the write is not.
    if (try self.lowerFileRead(tok, name, args)) |_| return;
    if (try self.lowerKernelCtl(tok, name, args)) return; // §9.17
    // §9.4.1 the display/severity/control family on the unconditional spine:
    // its call is minted at the end of the block, and an operand that reads a
    // branch flow is EVALUATED there — see `queueDisplay`. The conditional and
    // restricted cases stay on the path below, whose entries the chain drops
    // (W0851) or whose context owns the diagnostic (E0421 fires at the
    // statement, where `restrict` is still set).
    if ((isDisplayTask(name) or isSimCtlTask(name)) and
        self.cond_depth == 0 and self.restrict == null)
        return self.queueDisplay(tok, name, args);
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    for (args) |a| {
        if (a == .none) continue; // A.6.9 empty argument slot
        const tv = try self.lowerTaskArg(a, name);
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    if (isFileOutTask(name)) {
        self.uses_file_tasks = true;
        // The §9.4.3 formatter renders into a scratch row before the write, so a
        // module with a §9.5.2 output task needs the string kernels too.
        self.uses_str_tasks = true;
    }
    if (isDisplayTask(name) or isFileOutTask(name)) {
        // §9.4.3's other pairing half — each conversion against its operand's
        // TYPE. After the loop, because the types are what lowering computed.
        try self.prepareFormatArgs(live.items, tys.items, vals.items);
    }
    const v = try self.call(name, vals.items);
    // ponytail: printing and simulation control share one display-chain append.
    if (isDisplayTask(name) or isFileOutTask(name) or isSimCtlTask(name)) {
        // §9.7.1/§9.7.2 simulation control joins the same per-accepted-point
        // side-effect phase as the display tasks: both clauses tie the task to
        // the SOLVE ("during an accepted iteration"), which is exactly what the
        // display phase is, and §9.7.3's $fatal — "an implicit call to $finish"
        // — already travels this way as a member of the severity family. In the
        // printing artifact the call terminates the run at its position among
        // the prints (cg_display.emitSimCtl); in a device it is dropped like a
        // print, with the same W0850, because eval has no channel to stop a
        // host's solve. A conditional call is dropped under W0851 exactly as a
        // conditional $strobe is — §9.4.6's argument applies verbatim.
        try self.displays.append(self.arena, .{
            .val = v,
            .name = name,
            .tok = tok,
            .conditional = self.cond_depth != 0,
        });
    }
}

/// §9.4.1 sequence one unconditional display-family statement: capture its
/// operands, mint its `call` at the END of the analog block.
///
/// WHY THE END. "$strobe provides the ability to display simulation data when
/// the simulator has converged on a solution for all nodes" (§9.4.1), and
/// §5.4.2.2 makes "both the potential and the flow of a source branch ...
/// accessible in expressions anywhere in the module" — anywhere, not from the
/// statement after the `<+` on. For a FLOW source the accessible value is the
/// §5.6.1.2 retained accumulator, which §5.6.1.3 only settles at the end of
/// the cycle's execution path — so a display operand that reads one is lowered
/// in `finishDisplays`, where `lowerBranchAccess`'s `flowAccum` read IS the
/// final retained value (the same end-of-block state the core exports as
/// `Contribution.resist_val`/`wrote_val`, §5.6.1.3 retention-select phis
/// included). A read placed above the `<+` therefore reports what the branch
/// retained this cycle, not the 0 of a prefix of the block.
///
/// ONLY those operands move. An operand with no branch-flow read keeps its
/// at-statement value (`pre`), so `x = 1; $strobe("%g", x); x = 2;` still
/// prints 1 — §5.6.1.2's sequential semantics stay untouched for everything
/// that is not converged simulation data, and assignments/contributions are
/// not affected at all. The split is per OPERAND because it cannot be finer:
/// once a tree contains the end-of-block accumulator value, SSA dominance
/// puts the whole tree after it.
///
/// $display AND $strobe. §9.4.1 distinguishes their timing ("each time the
/// simulator executes" vs converged), but VerA's printing artifact runs the
/// display chain once per ACCEPTED point — one converged snapshot — so the
/// two collapse onto the same phase and the rule is applied to the whole §9.4
/// family uniformly, §9.7's control/severity tasks included since they travel
/// the same chain. The §9.5.2 file writers do NOT take this route: §9.5.9
/// sequences them against `$fgets`/`$ftell` side effects at statement order,
/// and re-pointing a retained-flow read is not worth reordering a descriptor.
///
/// The call is minted at the end even when NO operand defers, so the §9.4
/// prints keep source order among themselves in the emitted unit body.
fn queueDisplay(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    const pre = try self.arena.alloc(?TypedValue, args.len);
    var any_deferred = false;
    for (args, pre) |a, *p| {
        p.* = null;
        if (a == .none) continue; // A.6.9 empty argument slot
        if (self.containsFlowRead(a)) {
            any_deferred = true;
            continue;
        }
        p.* = try self.lowerTaskArg(a, name);
    }
    // §5.9.3 an unrolled body's genvar bindings are gone from `consts` by
    // `finishDisplays`; a deferred operand snapshots them. Only when one
    // exists — the common module has neither.
    var genvars: []const GenvarBind = &.{};
    if (any_deferred and self.active_genvars.items.len != 0) {
        const gs = try self.arena.alloc(GenvarBind, self.active_genvars.items.len);
        for (self.active_genvars.items, gs) |gname, *g|
            g.* = .{ .name = gname, .c = self.consts.get(gname).? };
        genvars = gs;
    }
    try self.deferred_displays.append(self.arena, .{
        .name = name,
        .tok = tok,
        .args = args,
        .pre = pre,
        .genvars = genvars,
        .display = @intCast(self.displays.items.len),
    });
    // The placeholder keeps `displays` in source order — W0850 reporting and
    // the chain both walk it — and `lowerDeferredDisplays` fills `.val`.
    try self.displays.append(self.arena, .{
        .val = .undef,
        .name = name,
        .tok = tok,
        .conditional = false,
    });
}

/// Does this operand tree read a branch FLOW (§4.4.1 `I(...)` under any
/// §3.6.1.4 spelling)? That is the one read whose value is position-dependent
/// inside the block (§5.6.1.2 retention); potentials and §5.4.3 port flows
/// resolve to solver unknowns and read the same value everywhere, so they do
/// not force an operand to the end. Same walk shape as `containsDdt`.
fn containsFlowRead(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .branch_access => {
            const kind = self.access_kind.get(self.file.str(ex.strOf(e))) orelse return false;
            return kind == .flow;
        },
        .filter_call, .call, .builtin_call, .sys_call, .noise_call => {
            for (ex.args(e)) |a| if (self.containsFlowRead(a)) return true;
            return false;
        },
        .ternary => return self.containsFlowRead(ex.lhs(e)) or self.containsFlowRead(ex.rhs(e)) or
            self.containsFlowRead(ex.ternaryElse(e)),
        else => return self.containsFlowRead(ex.lhs(e)) or self.containsFlowRead(ex.rhs(e)),
    }
}

/// The end-of-block half of `queueDisplay`: lower what was deferred, mint each
/// call, fill its `displays` placeholder. Runs at the top of `finishDisplays`,
/// with `self.cur` past the last statement and past `lowerModule`'s final
/// accumulator reads — so a `flowAccum` read here is the §5.6.1.3 end-of-cycle
/// retention state, phis and all.
fn lowerDeferredDisplays(self: *Lower) Oom!void {
    for (self.deferred_displays.items) |dd| {
        // Provenance: instructions minted here belong to the display
        // statement, not to whatever token the block ended on.
        self.mir.cur_tok = dd.tok;
        for (dd.genvars) |g| try self.consts.put(self.arena, g.name, g.c);
        var vals: std.ArrayList(Mir.Value) = .empty;
        defer vals.deinit(self.arena);
        var live: std.ArrayList(Ast.ExprId) = .empty;
        defer live.deinit(self.arena);
        var tys: std.ArrayList(Ty) = .empty;
        defer tys.deinit(self.arena);
        for (dd.args, dd.pre) |a, p| {
            if (a == .none) continue;
            const tv = p orelse try self.lowerTaskArg(a, dd.name);
            try vals.append(self.arena, tv.v);
            try live.append(self.arena, a);
            try tys.append(self.arena, tv.ty);
        }
        for (dd.genvars) |g| _ = self.consts.remove(g.name);
        // §9.4.3 conversion-vs-type pairing, postponed with the operands.
        try self.prepareFormatArgs(live.items, tys.items, vals.items);
        self.displays.items[dd.display].val = try self.call(dd.name, vals.items);
    }
}

/// §9.7.1 `$finish` and §9.7.2 `$stop` — the two IEEE 1364 simulation-control
/// tasks the analog context inherits. NOT `isDisplayTask`: they print only
/// their Table 9-25 diagnostics, take no §9.4.3 format, and what defines them
/// is what they do to the RUN. The §9.7.3 severity family ($fatal included) is
/// in `isDisplayTask`, because its whole content is a formatted message.
pub fn isSimCtlTask(name: []const u8) bool {
    return std.mem.eql(u8, name, "$finish") or std.mem.eql(u8, name, "$stop");
}

/// §9.5 Sequence one file-family call into the per-point I/O phase.
///
/// Every §9.5 call has a side effect on a descriptor — an open, a position, a
/// byte written — and §9.5.9 puts those at the ACCEPTED point, not inside the
/// iteration ("the file write operations shall not be performed unless the
/// iteration is accepted"). The display chain IS that phase: it is the one job
/// `planCommon` keeps out of the shared core, precisely so its side effects
/// cannot run per Newton iteration.
///
/// So a file call joins the chain whether or not its value is read. That is the
/// difference between this and `isDisplayTask`'s append, whose calls are void by
/// nature: `$fgets` returns a count `049_ftell.va` throws away, and the READ it
/// performed is what the `$ftell` two lines later measures.
///
/// The chain carries reals (`fadd`), and every §9.5 function is integer-valued,
/// so the carrier is `$itor` — a call codegen already renders, rather than a new
/// synthetic name for a conversion that already has one.
fn sequenceFileCall(self: *Lower, tok: u32, name: []const u8, v: Mir.Value) Oom!void {
    self.uses_file_tasks = true;
    try self.displays.append(self.arena, .{
        .val = try self.call("$itor", &.{v}),
        .name = name,
        .tok = tok,
        .conditional = self.cond_depth != 0,
    });
}

/// §9.5.4.1 `code = $fgets( str, fd )`, §9.5.4.2 `code = $fscanf( fd, format,
/// args )` and §9.7.3-adjacent §9.5.7 `errno = $ferror( fd, str )` — the three
/// §9.5 calls that write through an argument as well as returning a value.
///
/// Same rewrite as `lowerScan`, for the same reason: an out-parameter has no
/// spelling in an SSA expression tree. One source call becomes the count (or the
/// errno) plus one reader per destination, and every reader takes that count as
/// its first operand — which both sequences the pair (a data dependency the
/// emitter cannot reorder) and carries the clause's own "nothing was assigned"
/// rule into the reader.
///
/// Null when `name` is not one of the three.
fn lowerFileRead(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?Mir.Value {
    const eq = std.mem.eql;
    const gets = eq(u8, name, "$fgets");
    const scan = eq(u8, name, "$fscanf");
    const ferr = eq(u8, name, "$ferror");
    if (!gets and !scan and !ferr) return null;
    self.uses_file_tasks = true;
    // §9.5.4.2's conversions are §9.5.3's conversions, so the scanner is the
    // string one and the string kernels have to be there.
    if (scan) self.uses_str_tasks = true;

    // Syntax 9-6/9-7/9-9: `$fgets` and `$ferror` take the destination FIRST and
    // second respectively; `$fscanf` takes the descriptor, the format, then the
    // destinations. One shape, described rather than branched on three times.
    const fd_at: usize = if (gets) 1 else 0;
    if (args.len <= fd_at or args[fd_at] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a file descriptor", .{name});
        return try self.mir.addIntConst(self.arena, 0);
    }
    const fd = (try self.lowerSysArg(args[fd_at], false)).v; // a descriptor, never a net
    // §9.5.4.2 alone has a control string, and it is an operand of every reader
    // as well as of the count.
    const fmt: ?Mir.Value = if (scan) blk: {
        if (args.len < 2 or args[1] == .none) {
            try self.err(tok, .E0813, "`$fscanf` needs a format string", .{});
            break :blk null;
        }
        // Only a literal format can be checked — `lowerScan`'s reasoning, and
        // its diagnostic, apply verbatim to the file source of the same scan.
        if (self.constEval(args[1])) |c| switch (c) {
            .str => |s| if (try self.checkScanFormat(tok, s)) break :blk null,
            else => {},
        };
        break :blk (try self.lowerExpr(args[1])).v;
    } else null;
    if (scan and fmt == null) return try self.mir.addIntConst(self.arena, 0);

    const n = if (gets)
        try self.call("$fgets", &.{fd})
    else if (ferr)
        try self.call("$ferror", &.{fd})
    else
        try self.call("$fscanf", &.{ fd, fmt.? });
    try self.sequenceFileCall(tok, name, n);

    const dests = if (gets) args[0..1] else if (ferr) args[1..] else args[2..];
    var item: i64 = 0;
    for (dests) |a| {
        if (a == .none) continue;
        const slot = try self.resolveLvalue(a) orelse continue;
        // §9.5.4.1/§9.5.7 write a STRING; only §9.5.4.2 has typed items, and
        // there the destination's declared type picks the callee exactly as
        // `lowerScan` does — the name IS the type, so `sysFuncTy` and
        // `analysis.callTy` cannot disagree about it.
        if (gets or ferr) {
            if (slot.ty != .string) {
                try self.err(self.file.exprs.mainTok(a), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
                continue;
            }
            const v = try self.call(if (gets) "$fgets$str" else "$ferror$str", &.{ n, fd });
            try self.builder.writeVariable(slot.place, self.cur, v);
            continue;
        }
        const callee: []const u8 = switch (slot.ty) {
            .integer => "$fscanf$int",
            .string => "$fscanf$str",
            .real => "$fscanf$real",
        };
        const v = try self.call(callee, &.{ n, fd, fmt.?, try self.mir.addIntConst(self.arena, item) });
        try self.builder.writeVariable(slot.place, self.cur, v);
        item += 1;
    }
    return n;
}

/// §9.5.2's five output tasks: `$display`/`$write`/`$strobe`/`$monitor`/`$debug`
/// "with one additional argument, which is either a multichannel descriptor or a
/// file descriptor", plus the two §9.5.1/§9.5.6 tasks that take a descriptor and
/// return nothing. Every one of them is a STATEMENT, so its value is dead and it
/// only survives into the emitted device by joining the display chain.
pub fn isFileOutTask(name: []const u8) bool {
    const tasks = [_][]const u8{
        "$fdisplay", "$fwrite", "$fstrobe", "$fmonitor",
        "$fdebug",   "$fclose", "$fflush",
    };
    for (tasks) |t| if (std.mem.eql(u8, name, t)) return true;
    return false;
}

/// The §9.5 names that RETURN something: §9.5.1 `$fopen`, §9.5.4 `$fgets` and
/// `$fscanf`, §9.5.5 `$ftell`/`$fseek`/`$rewind`, §9.5.7 `$ferror`, §9.5.8
/// `$feof`. Every one is integer-valued (`sysFuncTy`), and every one has a SIDE
/// EFFECT on the descriptor — so each joins the display chain too, whether or not
/// anything reads its value: `049_ftell.va` drops the `$fgets` count on the floor
/// and then asserts the position that read moved to.
pub fn isFileFunc(name: []const u8) bool {
    const fns = [_][]const u8{
        "$fopen", "$fgets",  "$fscanf", "$ftell",
        "$fseek", "$rewind", "$ferror", "$feof",
    };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

/// Every §9.5 spelling that reaches the emitter: the two classifications above,
/// plus the synthetic readers `lowerFileRead` splits out of the three calls that
/// write through an argument. One predicate, because three consumers ask the same
/// question — the emitter's dispatch, its live-operand rule, and `proof`.
pub fn isFileCall(name: []const u8) bool {
    if (isFileOutTask(name) or isFileFunc(name)) return true;
    const synth = [_][]const u8{
        "$fgets$str", "$ferror$str", "$fscanf$int", "$fscanf$real", "$fscanf$str",
    };
    for (synth) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// §9.4.1 display family + §9.7.3 severity family: the tasks whose whole content
/// is text on the simulator's output. The §9.5 file family is NOT here — it is
/// `isFileOutTask`/`isFileFunc`, because a descriptor operation is sequenced with
/// the prints but rendered by different kernels — and neither is
/// `$monitoron`/`$monitoroff`, which toggle a mode rather than print.
pub fn isDisplayTask(name: []const u8) bool {
    const printing = [_][]const u8{
        "$display", "$displayb", "$displayo", "$displayh",
        "$write",   "$writeb",   "$writeo",   "$writeh",
        "$strobe",  "$strobeb",  "$strobeo",  "$strobeh",
        "$monitor", "$debug",    "$fatal",    "$error",
        "$warning", "$info",
    };
    for (printing) |p| if (std.mem.eql(u8, name, p)) return true;
    return false;
}

/// §9.4.3: "for each % character (except %m, %% and %l) that appears in a
/// string, a corresponding expression argument shall be supplied after the
/// string."
///
/// Only a shortfall is diagnosed. The same clause gives a surplus a meaning
/// ("displayed using the default decimal format"), and §9.7.3 puts a
/// non-string first in `$fatal(n, "…")` — so the format is "the first
/// argument that folds to a string", exactly the rule `cg_display.emitDisplayTask`
/// uses to pick one, and a task with no string at all has nothing to count.
///
/// A format built at run time folds to null and nothing is said.
fn checkFormatPairing(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!void {
    const at, const fmt = for (args, 0..) |a, i| {
        if (try self.outputLiteral(a)) |text| break .{ i, text };
        if (self.constEval(a)) |c| switch (c) {
            .str => |s| break .{ i, s },
            else => {},
        };
    } else return;

    var need: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) break;
        // §9.4.3 `%[flags][width][.precision]conv`; the conversion letter is
        // what decides, so everything before it is skipped unread.
        while (i < fmt.len and (std.mem.indexOfScalar(u8, "-+ 0.", fmt[i]) != null or
            (fmt[i] >= '0' and fmt[i] <= '9'))) : (i += 1)
        {}
        if (i >= fmt.len) break;
        const conv = std.ascii.toLower(fmt[i]);
        i += 1;
        if (conv == '%' or conv == 'm' or conv == 'l') continue; // the three that consume nothing
        need += 1;
    }

    // A null argument (`,,`) is still an argument — §9.4.1 gives it a
    // rendering — so the supply is the slot count, not the non-empty one.
    const have = args.len - (at + 1);
    if (have >= need) return;
    var b = self.errWith(tok, .E0810);
    b.msg("the format string has {d} consuming format specifiers but {d} arguments follow it", .{ need, have });
    try b.emit();
}

/// Preserve the source integer width before SSA replaces variables with their
/// values. The synthetic identity is consumed by the display formatter only;
/// other conversions still see the same numeric value.
fn formatOperand(self: *Lower, e: Ast.ExprId, tv: TypedValue) Oom!Mir.Value {
    const bits = self.formatBits(e) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0819, "numeric `%s` needs a preserved integral width; this expression's sizing is not implemented", .{});
        return tv.v;
    };
    return self.call("$display$width", &.{ tv.v, try self.mir.addIntConst(self.arena, bits) });
}

/// Only return widths the current analog IR preserves. A guessed carrier width
/// can silently truncate a wide conditional or sign-extend a small operand.
fn formatBits(self: *Lower, e: Ast.ExprId) ?u7 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => @intCast(if (ex.intLiteral(e).width == 0) 64 else ex.intLiteral(e).width),
        .unary => switch (ex.unOp(e)) {
            .plus => self.formatBits(ex.lhs(e)),
            .minus, .bit_not => if ((self.formatBits(ex.lhs(e)) orelse return null) <= 32) self.formatBits(ex.lhs(e)) else null,
            else => 1,
        },
        .ternary => blk: {
            const lhs = self.formatBits(ex.rhs(e)) orelse return null;
            const rhs = self.formatBits(ex.ternaryElse(e)) orelse return null;
            // Mixed-width branches also need signedness propagation before
            // selection. The current IR carries neither fact across a phi.
            break :blk if (lhs == rhs) lhs else null;
        },
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk 32; // §3.2 integer variable
            const pi = self.param_index.get(name) orelse return null;
            const module = self.module orelse return null;
            for (module.params) |decl| {
                if (!std.mem.eql(u8, self.file.str(decl.name), self.params.items[pi].name)) continue;
                if (decl.ty == .integer) break :blk 32;
                // §3.4.1: an untyped parameter derives its type from the FINAL
                // override. The host's numeric parameter ABI has no width.
                if (!decl.is_local) break :blk null;
                // Host derivation preserves equal-width conditional arms;
                // unsupported dependent expressions diagnose at code generation.
                break :blk self.formatBits(decl.default);
            }
            break :blk null;
        },
        .sys_call => if (std.mem.eql(u8, self.file.str(ex.strOf(e)), "$realtobits")) 64 else 32,
        .binary => switch (ex.binOp(e)) {
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => 1,
            // General arithmetic needs expression-width propagation, not the
            // analog arithmetic emitter's current unconditional wrap32.
            else => null,
        },
        else => null,
    };
}

/// §9.4.3's OTHER pairing rule: each conversion against its operand's TYPE.
/// `checkFormatPairing` counts; this one checks that the pairs it counted can
/// be RENDERED (see E0819), and each used to sail through here
/// and fail the generated device's own build as an "engine bug".
///
/// Walk every format run as `cg_display.buildArgs` does, skipping consumed
/// operands so a string used by `%s` does not become a new format. Numeric
/// `%s` operands also retain their source width through an identity call.
/// A shortfall stops where the operands stop; E0810 already owns it.
fn prepareFormatArgs(self: *Lower, live: []const Ast.ExprId, tys: []const Ty, vals: []Mir.Value) Oom!void {
    std.debug.assert(live.len == tys.len);
    var at: usize = 0;
    while (at < live.len) {
        // Use the actual lowered bytes, including direct literal NUL escapes,
        // so validation and emission inspect the same format.
        const lowered = self.mir.valueDef(vals[at]);
        const fmt = if (lowered == .str_const) lowered.str_const else if (self.constEval(live[at])) |c| switch (c) {
            .str => |str| str,
            else => {
                at += 1;
                continue;
            },
        } else {
            at += 1;
            continue;
        };
        var next = at + 1;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
            i = p + 1;
            if (i >= fmt.len) break;
            while (i < fmt.len and (std.mem.indexOfScalar(u8, "-+ 0.", fmt[i]) != null or
                (fmt[i] >= '0' and fmt[i] <= '9'))) : (i += 1)
            {}
            if (i >= fmt.len) break;
            const conv = std.ascii.toLower(fmt[i]);
            i += 1;
            if (conv == '%' or conv == 'm' or conv == 'l') continue; // the three that consume nothing
            if (next >= tys.len) return; // ran out of operands: E0810's finding, not ours
            const ty = tys[next];
            const arg = live[next];
            next += 1;
            // What `cg_display.appendConv` renders per (conversion, type):
            //   %d/%b/%o/%h/%x — any type; a string takes §2.7's integer view.
            //   %c             — an integer's low byte (Table 9-22); a real rounds.
            //   %s             — text, or §9.4.5's integer ASCII byte sequence.
            //                    Real operands still need a defined conversion.
            //   %e/%f/%g/%r and the %t/%u/%z/%v decimal defaults — numbers only.
            //   anything else  — the operand's natural form, every type.
            const bad = switch (conv) {
                's' => ty != .string and ty != .integer,
                'c' => ty == .string,
                'e', 'f', 'g', 'r', 't', 'u', 'z', 'v' => ty == .string,
                else => false,
            };
            if (!bad) {
                if (conv == 's') {
                    if (ty == .integer) {
                        vals[next - 1] = try self.formatOperand(arg, .{ .v = vals[next - 1], .ty = ty });
                    } else if (self.mir.valueDef(vals[next - 1]) == .str_const) {
                        // §9.4.5 suppresses leading zero bytes of a literal's
                        // packed byte sequence, before field padding. Stored
                        // strings already exclude every NUL (§3.3).
                        const bytes = self.mir.valueDef(vals[next - 1]).str_const;
                        vals[next - 1] = try self.mir.addStrConst(self.arena, std.mem.trimStart(u8, bytes, &.{0}));
                    }
                }
                continue;
            }
            var b = self.errWith(self.file.exprs.mainTok(arg), .E0819);
            b.msg("`%{c}` on a {s} operand", .{ conv, @tagName(ty) });
            if (conv == 's') {
                b.help("print the number with `%g` or `%d`", .{});
            } else if (conv == 'c') {
                b.help("`%c` takes a character code; use `%s` for the text", .{});
            } else {
                b.help("use `%s` for the text, or `%d` for the string's integer value", .{});
            }
            try b.emit();
        }
        at = next;
    }
}

/// §9.5.3 `$swrite(str, …)` / `$sformat(str, fmt, …)` — the §9.4.3 formatter
/// with a string variable where the transcript would be: "the first argument to
/// $swrite shall be a string variable to which the resulting string shall be
/// written, instead of a variable specifying the file to which to write".
///
/// Lowered as an ASSIGNMENT, not as a void call, because the write IS the task.
/// A call whose result nothing reads is dead code the moment codegen slices a
/// unit out of the MIR — which is precisely how the old stub could return
/// `S.con(0.0)` and lose the text. Rendering the formatter is then the same job
/// as rendering a `$display`, and `cg_display` does both.
fn lowerStringWrite(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (args.len == 0 or args[0] == .none) {
        try self.err(tok, .E0813, "`{s}` needs a string variable to write into", .{name});
        return;
    }
    const slot = try self.resolveLvalue(args[0]) orelse return;
    if (slot.ty != .string) {
        try self.err(self.file.exprs.mainTok(args[0]), .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
        return;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    var live: std.ArrayList(Ast.ExprId) = .empty;
    defer live.deinit(self.arena);
    var tys: std.ArrayList(Ty) = .empty;
    defer tys.deinit(self.arena);
    // Types are preserved, not coerced: the conversion `cg_display.appendConv`
    // picks depends on the operand's own type (§9.4.3 `%d` on a real is a
    // §4.2.1.1 conversion, `%s` on a string is the text).
    for (args[1..]) |a| {
        if (a == .none) continue;
        const tv = try self.lowerFormatArg(a);
        try vals.append(self.arena, tv.v);
        try live.append(self.arena, a);
        try tys.append(self.arena, tv.ty);
    }
    try self.checkFormatPairing(tok, args[1..]);
    try self.prepareFormatArgs(live.items, tys.items, vals.items);
    self.uses_str_tasks = true;
    const v = try self.call("$sformat", vals.items);
    try self.builder.writeVariable(slot.place, self.cur, v);
}

/// §9.5.4.2 `code = $sscanf( str, format, args )`. One source call becomes one
/// `$sscanf` (the count) plus one `$sscanf$<ty>` assignment per output argument,
/// each naming the item it wants by index among the ASSIGNED items — so a `%*d`
/// suppressed field shifts nothing, because it is not assigned.
///
/// An out-parameter has no spelling in an SSA expression tree, and the scan is a
/// pure function of the two strings, so N+1 evaluations compute what one call
/// with N writes would. `str_kernels.zig` says the same from the runtime side.
///
/// Returns the count value; a statement-position call drops it.
fn lowerScan(self: *Lower, tok: u32, args: []const Ast.ExprId) Oom!Mir.Value {
    if (args.len < 2 or args[0] == .none or args[1] == .none) {
        try self.err(tok, .E0813, "$sscanf needs a string to read and a format string", .{});
        return self.mir.addIntConst(self.arena, 0);
    }
    const src = (try self.lowerExpr(args[0])).v;
    const fmt = (try self.lowerExpr(args[1])).v;
    // Only a literal format can be checked, and only a literal one is worth
    // checking: a conversion code the scanner does not implement would consume
    // nothing and still be counted, so the model would read a plausible number.
    if (self.constEval(args[1])) |c| switch (c) {
        .str => |s| if (try self.checkScanFormat(tok, s)) return self.mir.addIntConst(self.arena, 0),
        else => {},
    };
    self.uses_str_tasks = true;
    var item: i64 = 0;
    for (args[2..]) |a| {
        if (a == .none) continue;
        const slot = try self.resolveLvalue(a) orelse continue;
        // The destination's declared type picks the callee, exactly as §5.10's
        // `holdSlot` does: the name IS the type, so `analysis.callTy` and
        // `sysFuncTy` cannot disagree about it.
        const callee: []const u8 = switch (slot.ty) {
            .integer => "$sscanf$int",
            .string => "$sscanf$str",
            .real => "$sscanf$real",
        };
        const v = try self.call(callee, &.{ src, fmt, try self.mir.addIntConst(self.arena, item) });
        try self.builder.writeVariable(slot.place, self.cur, v);
        item += 1;
    }
    return self.call("$sscanf", &.{ src, fmt });
}

// ---------------------------------------------------------------------------
// §9.13 probabilistic distributions
// ---------------------------------------------------------------------------

/// One row of Table 9-10's probabilistic family: the source spelling, the
/// synthetic kernel `rng_kernels.zig` implements, and the argument rules
/// §9.13.1/§9.13.2 state for it. Pub because `elaborate.rewriteParamsetDist`
/// judges the same argument rules for a call written inside a §6.4 paramset.
pub const Dist = struct {
    /// Source spelling, `$` included.
    name: []const u8,
    /// `rng_kernels.zig` entry point.
    kernel: []const u8,
    /// Arguments AFTER the seed. §9.13.1's two take none and their seed is
    /// itself optional; every §9.13.2 distribution requires its seed.
    nparam: u8,
    /// §9.13.2: "$dist_ ... return integer values", "$rdist_ ... All functions
    /// return a real value."
    ty: Ty,
    /// Bit i set = parameter i "shall be greater than zero (0). Otherwise an
    /// error shall be reported." (§9.13.2 for the $rdist_ family; IEEE 1364
    /// §17.9.2 states the same domain for the integer twins.)
    positive: u8 = 0,
    /// First parameter is df/stages, whose reference algorithm uses a count.
    count: bool = false,
    /// §9.13.2 "The start value shall be smaller than the end value." Only the
    /// uniform pair, and it is a relation between two arguments rather than a
    /// domain on one, which is why it is a separate flag.
    ordered: bool = false,
};

/// Table 9-10, all 17 names. `$simprobe` is §9.16 and stays out.
const dists = [_]Dist{
    // §9.13.1. `kernel` is the same for both: "$arandom is upwardly compatible
    // with $random ... and has the same behavior."
    .{ .name = "$random", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    .{ .name = "$arandom", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    // §9.13.2, the integer family (IEEE 1364 §17.9.2).
    .{ .name = "$dist_uniform", .kernel = "$rng$i_uniform", .nparam = 2, .ty = .integer, .ordered = true },
    .{ .name = "$dist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .integer },
    .{ .name = "$dist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_t", .kernel = "$rng$t", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .integer, .positive = 0b11, .count = true },
    // §9.13.2, the real family.
    .{ .name = "$rdist_uniform", .kernel = "$rng$uniform", .nparam = 2, .ty = .real, .ordered = true },
    .{ .name = "$rdist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .real },
    .{ .name = "$rdist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_t", .kernel = "$rng$t", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .real, .positive = 0b11, .count = true },
};

pub fn distOf(name: []const u8) ?*const Dist {
    for (&dists) |*d| if (std.mem.eql(u8, name, d.name)) return d;
    return null;
}

/// The name §9.13.2 gives parameter `i` of `d`, for the diagnostics.
pub fn distParamName(d: *const Dist, i: usize) []const u8 {
    if (d.ordered) return if (i == 0) "start" else "end";
    if (std.mem.endsWith(u8, d.name, "chi_square") or std.mem.endsWith(u8, d.name, "_t"))
        return "degree_of_freedom";
    if (std.mem.endsWith(u8, d.name, "erlang")) return if (i == 0) "k_stage" else "mean";
    if (std.mem.endsWith(u8, d.name, "normal")) return if (i == 0) "mean" else "standard_deviation";
    return "mean";
}

/// §9.13 Table 9-10, whose "supported in analog context" column reads Yes for
/// every one of the 17 names. One source call becomes TWO pure calls over the
/// seed's incoming value — the variate, and the updated seed §9.13.1/§9.13.2
/// require to be written back through the inout argument — for the reason
/// `lowerScan` splits `$sscanf`: a unit body is an SSA expression tree and an
/// out-parameter has no spelling in one.
///
/// That split is also what makes a draw legal inside a residual at all. Both
/// halves are functions of the SAME input, so re-evaluating the analog block at
/// one operating point re-derives the same pair — which is simultaneously
/// §9.13.2's "shall always return the same value given the same seed" and the
/// determinism Newton needs. `rng_kernels.zig`'s header argues this at length.
///
/// Returns null when `name` is not one of the 17.
fn lowerRandom(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?TypedValue {
    const d = distOf(name) orelse return null;
    const ex = &self.file.exprs;
    self.uses_rng = true;

    // Drop A.6.9 empty slots first, so the arity below counts what was written.
    var given: std.ArrayList(Ast.ExprId) = .empty;
    defer given.deinit(self.arena);
    for (args) |a| if (a != .none) try given.append(self.arena, a);

    // §9.13.1 Syntax 9-8 / §9.13.2 Syntax 9-9: the optional trailing
    // `type_string` ("instance" or "global") "shall only be used in calls to a
    // distribution function from within a paramset". The in-paramset calls were
    // already handled at elaboration — `elaborate.rewriteParamsetDist` validates
    // the string and folds or strips the call while cloning a §6.4 paramset body
    // — so any string still in the last slot here was written OUTSIDE one, and
    // is the scope error §9.13.2's sentence describes.
    if (given.items.len > 0) {
        const last = given.items[given.items.len - 1];
        if (ex.tag(last) == .str_literal) {
            try self.err(self.file.exprs.mainTok(last), .E0816, "`{s}`'s `type_string` argument is only meaningful within a paramset (§6.4)", .{name});
            return poison;
        }
    }

    const want: usize = @as(usize, d.nparam) + 1;
    // §9.13.1's two are the only ones whose seed "may be omitted, in which case
    // the simulator picks a seed"; Syntax 9-9 makes it mandatory everywhere else.
    const min: usize = if (d.nparam == 0) 0 else want;
    if (given.items.len < min or given.items.len > want) {
        try self.err(tok, .E0816, "`{s}` takes {s}{d} argument{s}, got {d}", .{
            name,
            if (min < want) "at most " else "",
            want,
            if (want == 1) "" else "s",
            given.items.len,
        });
        return poison;
    }

    // ---- the seed -----------------------------------------------------------
    var seed: Mir.Value = undefined;
    // Set only for §9.13.2's "If it is an integer VARIABLE, then it is an inout
    // argument"; a parameter, a constant and an omitted seed all leave it null,
    // which is §9.13.1's "the system function does not update the parameter
    // value".
    var write_back: ?VarSlot = null;
    if (given.items.len > 0) {
        const sa = given.items[0];
        const tv = try self.lowerExpr(sa);
        // §9.13.2: "For each system function, the seed argument shall be an
        // integer", and Syntax 9-9 says the same as grammar —
        // `seed ::= integer_variable_identifier | integer_parameter_identifier
        // | [ sign ] decimal_number`. A real is none of the three, and the
        // inout half of the rule needs somewhere to put an updated INTEGER.
        if (tv.ty != .integer) {
            try self.err(self.file.exprs.mainTok(sa), .E0816, "the seed argument shall be an integer, and this one is {s}", .{@tagName(tv.ty)});
            return poison;
        }
        seed = tv.v;
        if (ex.tag(sa) == .ident) if (self.vars.get(self.file.str(ex.strOf(sa)))) |s| {
            if (s.ty == .integer) write_back = s;
        };
    }
    if (write_back == null) {
        // The seedless and constant-seed forms. §9.13.1: "an internal seed is
        // created which is assigned the initial value of the parameter or
        // constant ... this internal seed gets updated every time the call ... is
        // made", and with no source variable there is nowhere in the model to put
        // it. So it is a latch in `Instance`, advanced by `updateState` on the
        // ACCEPTED step and only read here — the residual stays a pure function
        // of x, which a draw advancing per Newton iteration would destroy.
        const site = self.rng_auto_sites;
        self.rng_auto_sites += 1;
        const latch = try self.call("$rng$auto", &.{try self.mir.addIntConst(self.arena, site)});
        seed = if (given.items.len > 0)
            // The declared constant/parameter still SEEDS the stream, so it is
            // mixed in rather than dropped: two call sites with the same literal
            // seed are two streams (the "every time the call is made" sentence),
            // and two sites with different literals differ from the first draw.
            try self.emit(.iadd, &.{ seed, try self.toInt(.{ .v = latch, .ty = .real }) })
        else
            try self.toInt(.{ .v = latch, .ty = .real });
    }

    // ---- the parameters, and the rules §9.13.2 states about them ------------
    // §4.2.3 suppresses errors in skipped operands. Entry is a conservative
    // proof that the call executes unconditionally; later blocks keep runtime
    // checks even when they would also be safe to diagnose here. Function-local
    // constants can depend on host parameters, so they also stay runtime.
    const eager = self.cur == .entry and self.inlining.items.len == 0;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, seed);
    for (given.items[@min(1, given.items.len)..], 0..) |a, i| {
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, try self.toReal(tv));
        // A declared parameter default is not the final host-supplied value.
        // Keep static signature/type checks above, and defer numeric checks
        // unless both execution and the argument value are known here.
        if (!eager) continue;
        const c = self.foldExpr(a, false) orelse continue;
        if (c == .str) continue;
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(c.asReal() > 0))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{
                name, distParamName(d, i), c.asReal(),
            });
        if (d.count and i == 0 and c.asReal() > 0 and
            (!(c.asReal() <= 2147483647.0) or c.asReal() != @trunc(c.asReal())))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s fractional or out-of-range `{s}` is unsupported; the reference count domain is 1..2147483647", .{ name, distParamName(d, i) });
    }
    if (eager and d.ordered and d.ty == .real and vals.items.len == 3) {
        const lo = self.foldExpr(given.items[1], false);
        const hi = self.foldExpr(given.items[2], false);
        if (lo != null and hi != null and lo.? != .str and hi.? != .str and
            !(lo.?.asReal() < hi.?.asReal()))
        {
            var b = self.errWith(self.file.exprs.mainTok(given.items[1]), .E0816);
            b.msg("the start value shall be smaller than the end value, got {d} and {d}", .{ lo.?.asReal(), hi.?.asReal() });
            b.note("§9.13.2: start and end \"bound the values returned\", and an interval with start above end is empty", .{});
            try b.emit();
        }
    }

    // A required runtime error remains observable even when neither the value
    // nor final seed is used. Share the guarded source-order effect chain with
    // table captures, but do not force an unused distribution's draw loop.
    const rules: u4 = @as(u4, @intCast(d.positive)) |
        (if (d.count) @as(u4, 4) else 0) |
        (if (d.ordered and d.ty == .real) @as(u4, 8) else 0);
    if (rules != 0) {
        if (self.table_effect_place == null) {
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, .entry, .f_zero);
            self.table_effect_place = place;
        }
        const place = self.table_effect_place.?;
        const previous = try self.builder.readVariable(place, self.cur);
        const checked = try self.call("$rng$check", &.{
            previous,
            try self.mir.addIntConst(self.arena, rules),
            vals.items[1],
            if (d.nparam > 1) vals.items[2] else .f_zero,
        });
        try self.builder.writeVariable(place, self.cur, checked);
    }

    // ---- the two calls ------------------------------------------------------
    const v = try self.call(d.kernel, vals.items);
    // §9.13.1/§9.13.2: "a value is passed to the function and A DIFFERENT VALUE
    // IS RETURNED. The variable is initialized by the user and only updated by
    // the system function." Written AFTER the variate is computed, so both read
    // the same incoming seed however the two calls end up ordered in the MIR.
    //
    // The write-back is the kernel's OWN `_next` twin over the SAME argument
    // list, not a generic step: IEEE 1364 §17.9.3's routines consume a
    // data-dependent number of LCG draws (`normal` rejects pairs, `poisson`
    // loops, `chi_square`/`t`/`erlang` walk the degrees), and §9.13.3 binds
    // this family to that listing — so the updated seed must land exactly
    // where the reference's `long *seed` did, or the SECOND call on the
    // variable would leave the reference stream.
    if (write_back) |s| {
        const next_name = try std.fmt.allocPrint(self.arena, "{s}_next", .{d.kernel});
        const next = try self.call(next_name, vals.items);
        try self.builder.writeVariable(s.place, self.cur, try self.toInt(.{ .v = next, .ty = .real }));
    }
    return .{ .v = if (d.ty == .integer) try self.toInt(.{ .v = v, .ty = .real }) else v, .ty = d.ty };
}

/// §9.5.4.2's conversion codes, and nothing else. True when the format was
/// refused. The suppression `*` and the maximum field width are part of the
/// specification and are read past here; `str_kernels.zScan` implements them.
///
/// CASE-SENSITIVE, unlike §9.4.3's display table. Table 9-22 spells every
/// display conversion twice ("%h or %H"); §9.5.4.2's code table spells each
/// scan code once, in lower case, and says "if an invalid conversion character
/// follows the %, the results of the operation are implementation dependent".
/// A `toLower` here let `%D` past the check and straight into `zScan`, which
/// compares the raw byte, matches nothing, and returns zero items — no
/// diagnostic and no data. Refusing is the implementation-dependent result
/// worth having.
fn checkScanFormat(self: *Lower, tok: u32, fmt: []const u8) Oom!bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, fmt, i, '%')) |p| {
        i = p + 1;
        if (i >= fmt.len) break;
        if (fmt[i] == '%') { // a literal percent, matched not converted
            i += 1;
            continue;
        }
        if (fmt[i] == '*') i += 1;
        while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
        if (i >= fmt.len) break;
        const conv = fmt[i];
        i += 1;
        if (std.mem.indexOfScalar(u8, "dohxbcfegs", conv) != null) continue;
        var b = self.errWith(tok, .E0813);
        b.msg("$sscanf does not support the conversion `%{c}`", .{conv});
        b.note("§9.5.4.2's codes are %d %o %h %x %b %c %f %e %g %s", .{});
        try b.emit();
        return true;
    }
    return false;
}

/// §9.17 analog kernel control. Handled here rather than as an ordinary void
/// call because both tasks WRITE TO THE HOST: a plain call would render as
/// `S.con(0.0)` in an eval unit and the request would be silently dropped.
/// Returns true when `name` was one of them.
fn lowerKernelCtl(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    // §9.17.2 `$bound_step ( expression ) ;` — "the simulator shall ensure that
    // the next time step taken is no larger than the smallest $bound_step()
    // argument currently active", so the accumulation is a running minimum.
    if (std.mem.eql(u8, name, "$bound_step")) {
        if (args.len != 1 or args[0] == .none) {
            try self.err(tok, .E0802, "got {d}", .{args.len});
            return true;
        }
        // "The expression argument shall be non-negative" (§9.17.2); `abs`
        // would silently repair a model that violates it, so a provably
        // negative constant is a diagnostic and anything else is taken as
        // written.
        if (self.constEval(args[0])) |c| {
            if (c.asReal() < 0.0) {
                try self.err(self.file.exprs.mainTok(args[0]), .E0803, "got {d}", .{c.asReal()});
                return true;
            }
        }
        const p = try self.kernelCtlPlace(&self.bound_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try self.lowerExpr(args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // §9.17.1 `$discontinuity [ ( constant_expression ) ] ;` — the argument is
    // the DEGREE, "a discontinuity in the i'th derivative", so a smaller degree
    // is the more severe announcement and the running minimum is what the host
    // needs. `$discontinuity` with no argument is degree 0.
    if (std.mem.eql(u8, name, "$discontinuity")) {
        const real_args = for (args) |a| {
            if (a != .none) break args;
        } else args[0..0];
        if (real_args.len > 1) {
            try self.err(tok, .E0804, "got {d}", .{real_args.len});
            return true;
        }
        var degree: i64 = 0;
        if (real_args.len == 1) {
            const c = self.constEval(real_args[0]) orelse {
                try self.err(self.file.exprs.mainTok(real_args[0]), .E0805, "", .{});
                return true;
            };
            // Same hole as the subscript path: §4.2.1.1 gives an infinity no
            // nearest integer, so there is no degree here to compare against
            // -1. E0820 is the clause's own verdict for a degree it cannot
            // accept, and reporting it keeps the rest of the file compiling.
            degree = c.asIntExact() orelse {
                try self.err(tok, .E0820, "got {e}", .{c.asReal()});
                return true;
            };
        }
        if (degree == -1) {
            if (self.reject_iteration_place == null) {
                const p = self.builder.newPlace();
                try self.builder.writeVariable(p, .entry, .zero);
                self.reject_iteration_place = p;
            }
            try self.builder.writeVariable(self.reject_iteration_place.?, self.cur, .one);
            return true;
        }
        if (degree < -1) {
            try self.err(tok, .E0820, "got {d}", .{degree});
            return true;
        }
        const p = try self.kernelCtlPlace(&self.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.mir.addFloatConst(self.arena, @floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

/// §9.2. Every Chapter 9 table carries a "supported in analog context" column,
/// and these are the names whose cell says No. Seven tables, one list, because
/// the tables differ only in which subclause they sit under — the verdict and
/// the call site are the same for all of them (E0806 spells out the reason per
/// family).
///
/// There is no analog/digital context FLAG to consult, and deliberately so:
/// `parseAnalog` is the only producer of statements VerA lowers (A.6.2
/// `analog_construct`), and an analog function body (§4.7.2) is inlined into
/// one. VerA compiles a continuous-time device — every statement it ever sees
/// is in the analog context, so the column collapses to a name test. A flag
/// would be a field that is `true` on every read.
/// ponytail: add the flag the day a §7 digital block is lowered, not before.
fn isDigitalOnlySysFunc(name: []const u8) bool {
    const digital_only = [_][]const u8{
        // Table 9-1 (§9.4.1) — radix variants and the $monitor mode switches.
        "$displayb",         "$displayh",         "$displayo",
        "$strobeb",          "$strobeh",          "$strobeo",
        "$writeb",           "$writeh",           "$writeo",
        "$monitorb",         "$monitorh",         "$monitoro",
        "$monitoron",        "$monitoroff",
        // Table 9-2 (§9.5) — the same radix story against a descriptor, plus
        // the byte/vector reads and the two digital-netlist loaders.
              "$fdisplayb",
        "$fdisplayh",        "$fdisplayo",        "$fwriteb",
        "$fwriteh",          "$fwriteo",          "$fstrobeb",
        "$fstrobeh",         "$fstrobeo",         "$fmonitorb",
        "$fmonitorh",        "$fmonitoro",        "$swriteb",
        "$swriteh",          "$swriteo",          "$fgetc",
        "$ungetc",           "$fread",            "$readmemb",
        "$readmemh",         "$sdf_annotate",
        // Table 9-3 (§9.6) — the timescale tick, which the analog kernel has
        // no notion of.
            "$printtimescale",
        "$timeformat",
        // Table 9-5 (§9.8) — "Verilog AMS HDL does not extend the PLA modeling
        // tasks defined in IEEE Std 1364 Verilog." All sixteen spellings; the
        // `$` inside the name is an ordinary identifier character (§2.8.3), so
        // each of these is one token.
              "$async$and$array",  "$async$and$plane",
        "$async$nand$array", "$async$nand$plane", "$async$or$array",
        "$async$or$plane",   "$async$nor$array",  "$async$nor$plane",
        "$sync$and$array",   "$sync$and$plane",   "$sync$nand$array",
        "$sync$nand$plane",  "$sync$or$array",    "$sync$or$plane",
        "$sync$nor$array",   "$sync$nor$plane",
        // Table 9-6 (§9.9) — "Verilog AMS HDL does not extend the stochastic
        // analysis tasks defined in IEEE Std 1364 Verilog."
          "$q_initialize",
        "$q_remove",         "$q_exam",           "$q_add",
        "$q_full",
        // Table 9-7 (§9.10) — tick counts. $abstime is the analog spelling and
        // is the one row of that table with Yes in both columns; §9.10's NOTE
        // additionally deprecates $realtime in the analog context.
                  "$time",             "$stime",
        "$realtime",
        // Table 9-8 (§9.11) — the extension is $bitstoreal and $realtobits and
        // nothing else.
                "$itor",             "$rtoi",
        "$signed",           "$unsigned",
    };
    for (digital_only) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

/// §9.22 paragraph 3, second sentence: "Driver access functions can only be
/// called from connect modules." §9.23 repeats the fence for its four
/// supplementary functions ("supported in the digital context of
/// connectmodules"), and Table 9-19 gives every name below "Supported in analog
/// context of connectmodule: No".
///
/// This is a rule about the CALL SITE, not about the value: an ordinary module
/// is not a connect module, so the call is illegal on sight — no netlist, no
/// elaboration, no driver needed. Which is why it lives here, beside the §9.2
/// analog-context test above, and not in codegen: codegen used to answer these
/// with the constant 0, and 0 is not merely unhelpful but wrong-looking-right,
/// since §9.22.2/§9.22.3/§9.23.x index "between 0 and N-1" and N = 0 leaves no
/// element 0 to have a state, a strength or a type at all.
///
/// The list is a name test, exactly as `isDigitalOnlySysFunc` is, and it stays
/// one now that `connectmodule` PARSES (§7.6, A.1.2's third `module_keyword`):
/// every call site LOWERING reaches is inside the elaborated device, and a
/// connect module is never that. §7.6 makes it the bridge the insertion phase
/// places on a mixed net, so `elaborate.pickTop` refuses to pick one and nothing
/// lowers its body — a driver call written inside a connect module is therefore
/// accepted and never reached, which is the right answer to the wrong half of the
/// clause. The day insertion exists, the test narrows to "is the enclosing design
/// element a connect module" and this list is the set it narrows over.
///
/// `$receiver_count` is on the list on the strength of the §9.22.1 paragraph
/// that introduces it: it is explicitly "Non-normative", but it is printed
/// INSIDE §9.22, takes the same `signal_name` argument, and Table 9-19 carries
/// it with the rest — so if it exists at all it is a member of the family the
/// paragraph above fences (tests/fixtures/annex_g_change_history/08).
fn isConnectModuleOnlySysFunc(name: []const u8) bool {
    const cm_only = [_][]const u8{
        // §9.22.1–§9.22.3 and the §9.22.1 non-normative paragraph.
        "$driver_count",         "$receiver_count", "$driver_state",
        "$driver_strength",
        // §9.23.1–§9.23.4, the supplementary pending-event queries.
             "$driver_delay",   "$driver_next_state",
        "$driver_next_strength", "$driver_type",
    };
    for (cm_only) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Class 4/5 — expressions (LRM §4.2), math (§4.3), signal access (§4.4)
// ---------------------------------------------------------------------------

/// Expression lowering. LRM §4. Returns the Value AND its LRM type, because
/// every operator's opcode family depends on it (§4.2.1.1–§4.2.1.3).
pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (e == .none) return poison;
    const ex = &self.file.exprs;
    // PROVENANCE. Every MIR instruction emitted while this node is being
    // lowered is stamped with its token (Mir.addInst reads the cursor), which
    // is how proof.zig turns a `Mir.Inst` back into a source span. Saved and
    // restored because lowering recurses: an operand must not leave the cursor
    // pointing at itself once the parent resumes emitting.
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = ex.mainTok(e);
    switch (ex.tag(e)) {
        .int_literal => return .{ .v = try self.mir.addIntConst(self.arena, ex.intValue(e)), .ty = .integer }, // §2.6.1
        .logic_literal => {
            try self.err(ex.mainTok(e), .E0130, "digital literal requires a four-state execution backend", .{});
            return poison;
        },
        .real_literal => return .{ .v = try self.mir.addFloatConst(self.arena, ex.realValue(e)), .ty = .real }, // §2.6.2
        .str_literal => return .{
            .v = try self.mir.addStrConst(self.arena, self.file.str(ex.strOf(e))),
            .ty = .string,
        }, // §2.7
        // A.2.5 — only legal inside a value range, which proof.zig reads from
        // the AST directly; lowering one is harmless.
        .pos_inf => return .{ .v = .f_inf, .ty = .real },
        .neg_inf => return .{ .v = try self.mir.addFloatConst(self.arena, -std.math.inf(f64)), .ty = .real },

        .ident => return self.lookupName(e, self.file.str(ex.strOf(e))),
        .hier_ident => {
            // §5.5.3 Syntax 5-4 first: a nature attribute reference is a
            // CONSTANT this module can resolve, unlike a §6.8 hierarchical name,
            // which needs an instance tree (E0901).
            if (self.natureAttrRef(e)) |r| switch (r) {
                .value => |c| return switch (c) {
                    .real, .int => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
                    .str => .{ .v = try self.mir.addStrConst(self.arena, c.str), .ty = .string },
                },
                .banned => |attr| {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0359);
                    b.msg("`{s}`", .{attr});
                    b.note("§5.5.3: \"This syntax shall not be used for the access, ddt_nature, or idt_nature attributes of a nature, nor any other attribute whose value is not a constant expression\"", .{});
                    try b.emit();
                    return poison;
                },
            };
            // §6.7 "access of parameters can be done hierarchically", and
            // §6.7.1 extends it to variables. The path IS the flat name
            // elaboration gave the child's entity, so once the join resolves
            // there is nothing hierarchical left to do; E0901 is what is left
            // when it does not.
            const name = try self.flatName(e);
            // §6.7.1's fifth bullet, and the ONLY one of the list that is a
            // prohibition: "It shall be an error to access analog variables
            // hierarchically." It has to be tested before the resolution below,
            // because the resolution succeeds — a flattened child's variable is
            // an ordinary variable of the flat design under its path name, so
            // nothing else would stop the read.
            // …EXCEPT a §5.3.2 named-block local, which the LRM spells out the
            // other way: "All identifiers declared within a named sequential
            // block can be accessed outside the scope in which they are
            // declared." §6.7.1 is about reaching into another INSTANCE;
            // `publishBlockLocals` bound only labels of this analog block.
            if (self.vars.contains(name) and !self.block_locals.contains(name)) {
                var vb = self.errWith(self.file.exprs.mainTok(e), .E0910);
                vb.msg("`{s}`", .{name});
                vb.note("§6.7.1 permits a hierarchical parameter, branch probe or analog function; a variable is the one entry on that list it forbids", .{});
                try vb.emit();
                return poison;
            }
            if (self.param_index.contains(name) or self.consts.contains(name) or
                self.node_voltages.contains(name) or self.block_locals.contains(name))
                return self.lookupName(e, name);
            var b = self.errWith(self.file.exprs.mainTok(e), .E0901);
            b.msg("`{s}` names nothing in the elaborated design", .{name});
            try b.emit();
            return poison;
        },

        .unary => return self.lowerUnary(e),
        .binary => return self.lowerBinary(e),
        .ternary => return self.lowerTernary(e), // §4.2.3 / §4.2.12

        .call => return self.lowerUserCall(e), // §4.7
        .builtin_call => return self.lowerBuiltin(e), // §4.3
        .sys_call => return self.lowerSysCall(e), // ch9
        .filter_call => return self.lowerFilter(e), // §4.5
        .noise_call => return self.lowerNoise(e), // §4.6

        .branch_access => return self.lowerBranchAccess(e), // §4.4.1
        .port_access => return self.lowerPortAccess(e), // §4.4.2/§5.4.3

        .index => return self.lowerIndex(e),

        // §4.2.13 / §3.3 Table 3-3. A `.multi_concat` reaches lowering only
        // when its multiplier is not a literal, which Table 3-3 allows for a
        // string result; every other replication was unrolled in the parser,
        // where the operand widths still exist.
        .concat, .multi_concat => return self.lowerConcat(e),
        .assign_pattern => {
            try self.err(self.file.exprs.mainTok(e), .E0509, "", .{});
            return poison;
        },
        .range => {
            try self.err(self.file.exprs.mainTok(e), .E0329, "", .{});
            return poison;
        },
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        // A.6.5 `driver_update expression` — an event, so E0701 like the rest.
        // Nothing lowers a connect module, so this is reachable only if someone
        // writes the keyword where a value belongs.
        .event_driver_update,
        => {
            try self.err(self.file.exprs.mainTok(e), .E0701, "", .{});
            return poison;
        },
    }
}

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `$idx` call carrying every element, which
/// codegen renders as ONE `switch` — a jump table, so the read is O(1) in the
/// array's extent (the array is scalarized, so there is no memory to index).
fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    var subs: [max_stack_dims]Ast.ExprId = undefined;
    const chain = (try self.indexChain(e, &subs)) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    };
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse {
        try self.err(self.file.exprs.mainTok(e), .E0309, "`{s}`", .{name});
        return poison;
    };

    var idx: [max_stack_dims]i64 = undefined;
    const at = try self.subscriptBuf(&idx, chain.subs.len);
    var all_const = true;
    for (chain.subs, at) |s, *o| {
        // `foldExpr(.., false)`, NOT `constEval`: a §3.4 parameter is
        // overridable by the model card, so folding `a[n-1]` through `n`'s
        // DEFAULT bakes one element into the device and answers every other
        // card with it. The same rule `foldExpr`'s own header states for a
        // procedural `if (p > 0)`; a subscript is no different, and it fails
        // louder — `parameter integer pwl_len = 0` folded `a[pwl_len-1]` to
        // `a[-1]` and reported E0310 on legal source.
        if (self.foldExpr(s, false)) |c| {
            // §4.2.1.1 converts a real subscript by rounding to the nearest
            // integer; an infinity, a NaN, or a magnitude past i64 has none, so
            // the subscript names no element. That is the same verdict E0310
            // already reaches for a constant subscript outside the declared
            // range — which is exactly what this is, once the converter
            // declines to invent an index for it.
            o.* = c.asIntExact() orelse {
                try self.err(self.file.exprs.mainTok(s), .E0310, "subscript {e} of `{s}` has no integer value, so it lies outside every dimension", .{ c.asReal(), name });
                return poison;
            };
        } else all_const = false;
    }
    if (!try self.checkSubscriptCount(e, name, info, at.len)) return poison;
    if (all_const) {
        if (!try self.checkSubscripts(e, name, info, at)) return poison;
        return (try self.arrayElemValue(name, at)) orelse poison;
    }

    // `$idx` emits one switch over the scalarized elements. Both reads and
    // writes use the same declared-order flattening and per-dimension bounds.
    const iv = try self.runtimeArrayIndex(chain.subs, info.dims);
    const ty = info.ty;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, .zero);
    try vals.append(self.arena, iv);
    for (0..shapeCells(info.dims)) |k| {
        shapeSubscripts(info.dims, k, at);
        const el = (try self.arrayElemValue(name, at)) orelse return poison;
        try vals.append(self.arena, if (ty == .real) try self.toReal(el) else el.v);
    }
    // The callee name IS the result type — `analysis.callTy` and `sysFuncTy`
    // agree by construction, the `$sscanf$int` rule.
    const callee: []const u8 = switch (ty) {
        .real => "$idx",
        .integer => "$idx$int",
        .string => "$idx$str",
    };
    return .{ .v = try self.call(callee, vals.items), .ty = ty };
}

/// `{a, b, ...}` in a value position. The INTEGER form (§4.2.13) needs each
/// operand's bit width, which only the token text carries, so `parser.zig`
/// folds it and lowering never sees one; what is left here is §3.3 Table 3-3
/// `{Str1,...,Strn}`, "concatenation of Str1,…,Strn" — the LRM's own example is
/// `{ "hello", " ", "world" }` == `"hello world"`.
///
/// ponytail: constant operands only. A string Value is a `str_const` (there is
/// no runtime string in the emitted device), so a non-constant operand has
/// nothing to concatenate and is rejected rather than substituted.
///
/// A `.multi_concat` arrives here for one reason: §3.3 Table 3-3's Replication
/// row says the "multiplier must be of integral type and can be nonconstant.
/// If multiplier is nonconstant or Str is of type string, the result is a
/// string containing N concatenated copies", and the parser unrolls only a
/// literal count (see `replCount`). So every replication left standing is a
/// string one, and N is whatever the folder can make of the multiplier.
fn lowerConcat(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const repl = ex.tag(e) == .multi_concat;
    const elems = ex.args(if (repl) ex.rhs(e) else e);
    if (elems.len == 0) {
        try self.err(self.file.exprs.mainTok(e), .E0326, "", .{});
        return poison;
    }
    var copies: i64 = 1;
    if (repl) {
        const c = try self.lowerExpr(ex.lhs(e));
        copies = switch (self.mir.valueDef(c.v)) {
            .int_const => |n| n,
            // A multiplier that survives to the residual has no width and no
            // string to repeat: §3.3's `{i{"Hi"}}` is legal because `i` is
            // knowable, not because the device could build a string at runtime.
            else => {
                try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0328, "", .{});
                return poison;
            },
        };
        // §4.2.13: the replication constant is "non-negative, non-x and
        // non-z". Zero is legal and yields the empty string.
        if (copies < 0) {
            try self.err(self.file.exprs.mainTok(ex.lhs(e)), .E0327, "a replication constant shall be non-negative, got {d}", .{copies});
            return poison;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (elems) |el| {
        const tv = try self.lowerExpr(el);
        if (tv.ty != .string) {
            try self.err(self.file.exprs.mainTok(e), .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            else => {
                try self.err(self.file.exprs.mainTok(e), .E0328, "", .{});
                return poison;
            },
        }
    }
    if (repl) {
        const one = try self.arena.dupe(u8, out.items);
        out.clearRetainingCapacity();
        for (0..@intCast(copies)) |_| try out.appendSlice(self.arena, one);
    }
    // The interner borrows: the bytes live in the arena, which outlives the Mir.
    return .{ .v = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)), .ty = .string };
}

/// The Value of one scalarized element — a variable array (§3.2.2) or a
/// parameter array (§3.4.4).
fn arrayElemValue(self: *Lower, name: []const u8, idx: []const i64) Oom!?TypedValue {
    var key_buf: [elem_key_len]u8 = undefined;
    const key = try self.elemKey(&key_buf, name, idx);
    if (self.vars.get(key)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    if (self.param_index.get(key)) |pi|
        return .{ .v = self.param_values.items[pi], .ty = astTy(self.params.items[pi].ty) };
    return null;
}

/// §6.7 the flat spelling of a `.hier_ident` path: its parts joined by
/// `Elaborate.sep`.
///
/// That join is the whole out-of-module reference mechanism, and it is one line
/// because of what elaboration already did: flattening renames a child's entity
/// to `path.name` (Ruling E, `Elaborate.sep`), so the name §6.7 asks for and the
/// name the flat design carries are the SAME STRING. Nothing here walks an
/// instance tree, because there is no tree left to walk.
///
/// Arena-allocated per call. Cold: one path per source reference.
fn flatName(self: *Lower, e: Ast.ExprId) Oom![]const u8 {
    var parts = self.file.exprs.nameParts(e);
    // §6.2.1 the `$root` prefix: "used to unambiguously refer to a top-level
    // instance or to an instance path starting from the root of the instantiation
    // tree", against a plain path, where "the ambiguity is resolved by giving
    // priority to the local scope". Elaboration's flat namespace IS rooted — a
    // name with no path prefix is a name of the top — so `$root.` means "do not
    // apply the local scope", and dropping the prefix is how that is said. The
    // segment after it names a TOP-LEVEL INSTANCE (§6.7's own `$root.mymodule.u1`
    // is "absolute name"), and the one top-level instance a flattened design has
    // is the device itself, so the top module's own name drops with it.
    //
    // Not done in `Elaborate`'s clone: a `$root` path in the TOP module's body is
    // never cloned (the tree-of-one returns by pointer), so the rule would only
    // have applied to children. Here it applies to every unit.
    if (parts.len > 1 and self.file.strings.eql(parts[0], "$root")) {
        parts = parts[1..];
        if (parts.len > 1) {
            if (self.module) |m| if (parts[0] == m.name) {
                parts = parts[1..];
            };
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0) try out.append(self.arena, Elaborate.sep);
        try out.appendSlice(self.arena, self.file.str(p));
    }
    const path = try out.toOwnedSlice(self.arena);
    // The one place the join is NOT the answer: a child port bound to a parent
    // net is the same signal as that net, so `u.a` denotes `p` and there is no
    // `u.a` to find. `Design.names` holds those aliases and nothing else.
    return self.hier_names.get(path) orelse path;
}

/// §2.8 name resolution: variables (§3.2) shadow parameters (§3.4), which
/// shadow genvars (§3.5). Nets are NOT values — they are only reachable
/// through an access function (§4.4).
/// §6.7 hierarchical reads pass the dotted path joined by `flatName`.
fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    if (self.vars.get(name)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    // §4.7.2/§6.8: inside a function body, a function-local `parameter` of the
    // same name shadows the module's, so `param_index` is masked and the local
    // value is found in `consts` (where `inlineUserFuncPre` folded it).
    if (!self.funcParamShadows(name)) if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.mir.addIntConst(self.arena, c.asInt()), .ty = .integer },
        .real => .{ .v = try self.mir.addFloatConst(self.arena, c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errWith(self.file.exprs.mainTok(e), .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(name, self.vars) orelse
        diag.didYouMeanMap(name, self.param_index) orelse
        diag.didYouMeanMap(name, self.node_voltages) orelse
        diag.didYouMeanMap(name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// §4.7.2/§6.8: does the function currently being inlined declare `name` as a
/// local parameter? True makes the local (in `consts`) win over a module
/// parameter of the same name — the shadowing §6.8's scope list requires.
fn funcParamShadows(self: *const Lower, name: []const u8) bool {
    for (self.func_params) |*p| {
        if (self.file.strings.eql(p.name, name)) return true;
    }
    return false;
}

/// A.8.6 unary operators. §4.2.3 (+/-), §4.2.7 (!), §4.2.9 (~).
fn lowerUnary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const a = try self.lowerExpr(ex.lhs(e));
    switch (ex.unOp(e)) {
        .plus => return a,
        .minus => {
            // §4.2.3. Fold a LITERAL here instead of emitting `ineg(3)`. The
            // §4.2.8 divisor proof reads an operand's interval, and proof.zig's
            // `integerIv` gives every integer instruction the full i64 clamp —
            // it has no transfer function for `ineg` — so `11 % -3` could not
            // prove its divisor non-zero and died on E0601. A negative literal
            // is a constant however the grammar spells it, so the fix belongs
            // where the constant is built, not in a second range rule.
            switch (self.mir.valueDef(self.mir.resolveAlias(a.v))) {
                .int_const => |x| if (x != std.math.minInt(i64))
                    return .{ .v = try self.mir.addIntConst(self.arena, -x), .ty = a.ty },
                .float_const => |x| return .{ .v = try self.mir.addFloatConst(self.arena, -x), .ty = a.ty },
                else => {},
            }
            return .{
                .v = try self.emit(if (a.ty == .real) .fneg else .ineg, &.{a.v}),
                .ty = a.ty,
            };
        },
        .logical_not => return .{ .v = try self.emit(.lognot, &.{try self.toBool(a)}), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0318, "`~` on a {s}", .{@tagName(a.ty)});
                return poison;
            }
            return .{ .v = try self.emit(.bitnot, &.{a.v}), .ty = .integer };
        },
        // §4.2.10, the whole clause: "The reduction operators can not be used
        // inside the analog block and only have meaning when used in the
        // digital context." There is no carve-out and no analog form.
        //
        // Unconditional, for the reason `isDigitalOnlySysFunc` gives at length:
        // `parseAnalog` is the only producer of statements VerA lowers, so
        // every expression that reaches here IS in the analog block and a
        // context flag would read `true` at every call site.
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor => {
            // §4.2.1 first: a real operand has no bits to fold at all, and
            // E0319 names the operand rather than the context.
            if (a.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            try self.err(self.file.exprs.mainTok(e), .E0348, "", .{});
            return poison;
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode (annex C).
        .reduce_xor, .reduce_xnor => {
            try self.err(self.file.exprs.mainTok(e), .E0320, "", .{});
            return poison;
        },
    }
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
fn lowerBinary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const op = ex.binOp(e);
    if (self.mixedShiftComparison(e)) {
        try self.err(ex.mainTok(e), .E0364, "comparison mixes signed and unsigned operands around a logical shift", .{});
        return poison;
    }

    // §4.2.7 && and || SHORT-CIRCUIT: the rhs must not be evaluated when the
    // lhs already decides the result, so this needs real control flow.
    if (op == .logical_and or op == .logical_or) return self.lowerShortCircuit(e, op);

    var a = try self.lowerExpr(ex.lhs(e));
    var b = try self.lowerExpr(ex.rhs(e));
    // §2.7 makes a string operand an unsigned integer, so a MIXED pair is
    // arithmetic and not a string operation. Two strings stay strings: Table
    // 3-3's relational row is a string comparison and `{a, " ", b}` is a
    // concatenation, and both would be destroyed by converting either side.
    if ((a.ty == .string) != (b.ty == .string)) {
        a = try self.strNum(a);
        b = try self.strNum(b);
    }

    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            const ty = unify(a.ty, b.ty);
            if (ty == .string) {
                try self.err(self.file.exprs.mainTok(e), .E0321, "", .{});
                return poison;
            }
            const real = ty == .real;
            const opc: Mir.Opcode = switch (op) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                else => if (real) .fmod else .imod,
            };
            const lv = if (real) try self.toReal(a) else a.v;
            const rv = if (real) try self.toReal(b) else b.v;
            return .{ .v = try self.emit(opc, &.{ lv, rv }), .ty = ty };
        },
        // §4.3.1 Table 4-14: pow is a real-valued math function.
        .pow => return .{
            .v = try self.emit(.pow, &.{ try self.toReal(a), try self.toReal(b) }),
            .ty = .real,
        },
        .eq, .neq, .lt, .le, .gt, .ge => return .{ .v = try self.cmp(op, a, b), .ty = .integer },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (a.ty != .integer or b.ty != .integer) {
                try self.err(self.file.exprs.mainTok(e), .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
                return poison;
            }
            const opc: Mir.Opcode = switch (op) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                else => .shr,
            };
            return .{ .v = try self.emit(opc, &.{ a.v, b.v }), .ty = .integer };
        },
        // §4.2.5 case equality is a 4-state comparison (annex C).
        .case_eq, .case_neq => {
            var d = self.errWith(self.file.exprs.mainTok(e), .E0323);
            d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
            try d.emit();
            return poison;
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errWith(self.file.exprs.mainTok(e), .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0325, "`{s}`", .{@tagName(op)});
            return poison;
        },
    }
}

/// §4.2.4 relational / §4.2.5 equality — integer 0/1 result either way.
fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value {
    const real = unify(a.ty, b.ty) == .real;
    const opc: Mir.Opcode = switch (op) {
        .eq => if (real) .feq else .ieq,
        .neq => if (real) .fne else .ine,
        .lt => if (real) .flt else .ilt,
        .le => if (real) .fle else .ile,
        .gt => if (real) .fgt else .igt,
        else => if (real) .fge else .ige,
    };
    const lv = if (real) try self.toReal(a) else a.v;
    const rv = if (real) try self.toReal(b) else b.v;
    return self.emit(opc, &.{ lv, rv });
}

/// §4.2.3 names THREE short-circuiting operators, "&&, ||, and ?:", and says of
/// all three that "any side effects or runtime errors that would have occurred
/// due to evaluation of the short-circuited operand expression shall not occur";
/// §4.2.12 says the same from the value side, naming only the arm it selects.
/// So the arms are BRANCHES and not operands of a `select`: an inlined function
/// that writes an `inout` formal (§4.7.2.4) must not run in the arm that was not
/// chosen, and neither must a division the condition exists to guard.
///
/// The shape is `lowerShortCircuit`'s — one place, one phi at the join. The one
/// difference is the type: `&&` is integer by definition, while §4.2.1 makes a
/// ternary's type the unification of BOTH arms, and neither arm's type is known
/// until it has been lowered. So the then-arm is left UNTERMINATED while the
/// else-arm is lowered, and both are finished afterwards, once `ty` is settled
/// and the `.itof` each arm may need can still be emitted before its jump.
/// Nothing between the two reads the then-arm's terminator: the SSA builder
/// walks predecessors, and the else-arm has none of the then-arm's blocks.
fn lowerTernary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const cond = ex.lhs(e);
    const c = try self.toBool(try self.lowerExpr(cond));

    // §4.5.15 "Analog operators shall not be used inside conditional (if, case,
    // or ?:) statements unless the conditional expression controlling the
    // statement consists of terms which can not change their value during the
    // course of a simulation." `?:` is in that list, and short-circuiting is
    // precisely WHY: an operator in an arm loses its history on every step the
    // arm is off. The two counters `lowerCondBody` raises for an `if` body are
    // raised here for the same rule, and that is what lets E0514 in
    // `lowerFilter` see it.
    const static = self.isAnalysisOrConst(cond);
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }

    const then_b = try self.mir.addBlock(self.arena);
    const else_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    try self.branchTo(c, then_b, else_b, true);

    self.cur = then_b;
    const t = try self.lowerExpr(ex.rhs(e));
    const then_end = self.cur; // an arm may have branched on its own (`&&`, a nested `?:`)

    self.cur = else_b;
    const f = try self.lowerExpr(ex.ternaryElse(e));
    const else_end = self.cur;

    const ty = unify(t.ty, f.ty);
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, else_end, if (ty == .real) try self.toReal(f) else f.v);
    try self.gotoBlock(join);

    self.cur = then_end;
    try self.builder.writeVariable(place, then_end, if (ty == .real) try self.toReal(t) else t.v);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = ty };
}

/// §4.2.7 `&&` / `||` with LRM short-circuit evaluation. The rhs gets its own
/// block, so a guard like `(x != 0) && (1/x > k)` never divides by zero.
fn lowerShortCircuit(self: *Lower, e: Ast.ExprId, op: Ast.BinaryOp) Oom!TypedValue {
    const ex = &self.file.exprs;
    const a = try self.toBool(try self.lowerExpr(ex.lhs(e)));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, a);

    const rhs_b = try self.mir.addBlock(self.arena);
    const join = try self.mir.addBlock(self.arena);
    // `a && b` evaluates b only when a is true; `a || b` only when a is false.
    if (op == .logical_and) {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, rhs_b, join);
    } else {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, join, rhs_b);
    }
    try self.builder.addPredecessor(rhs_b, self.cur);
    try self.builder.addPredecessor(join, self.cur);
    try self.builder.sealBlock(rhs_b);

    self.cur = rhs_b;
    const b = try self.toBool(try self.lowerExpr(ex.rhs(e)));
    try self.builder.writeVariable(place, self.cur, b);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = .integer };
}

/// §4.4.1 access function: `V(a)`, `V(a,b)`, `I(br)`.
/// A potential is the difference of two node unknowns; a flow that is *read*
/// makes the branch current an unknown of its own (§5.4.2).
fn lowerBranchAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    // §3.12.1: a port branch names the §5.4.3 port flow, so `I(pb)` and
    // `I(<p>)` are one quantity and read the one unknown. Ahead of `branchOf`
    // because the name is not in `branches` and would otherwise fall through to
    // `nodeOf` and become an implicit net.
    if (try self.portBranchOf(e)) |p| return self.portFlowRead(e, p);
    const t = try self.branchOf(e) orelse return poison;
    try self.branch_reads.append(self.arena, .{
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .tok = self.file.exprs.mainTok(e),
    });
    // §1.3.1.2: the reversed spelling of a branch is the same quantity with the
    // opposite sign. For the potential that is just which way the subtraction
    // runs; for the flow it is the whole point — `t` has already been
    // canonicalised, so `I(n,p)` reads the ONE `flow(p,n)` unknown negated
    // instead of minting a second, independent one that nothing constrains.
    switch (t.access) {
        .potential => {
            const hi = try self.probe(t.hi);
            if (t.lo == ground)
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{hi}) else hi, .ty = .real };
            const lo = try self.probe(t.lo);
            const d = if (t.neg) [2]Mir.Value{ lo, hi } else [2]Mir.Value{ hi, lo };
            return .{ .v = try self.emit(.fsub, &d), .ty = .real };
        },
        .flow => {
            // §5.4.2.2 "Both the potential and the flow of a source branch are
            // accessible in expressions anywhere in the module." For a FLOW
            // source that access cannot be a solver unknown: a current source's
            // branch flow has no node-derived value and no row pins it, so a
            // read of the unknown answers its initial 0 whatever was
            // contributed. What the branch flow of a flow source IS, by
            // definition, is the value retained on the branch (§5.6.1.2) — so
            // the read is the ACCUMULATOR, read at `self.cur`. WHERE `self.cur`
            // is is the caller's statement of position semantics, and there are
            // exactly two: an ORDINARY expression (an assignment's, a
            // contribution's right side) reads mid-block and sees §5.6.1.2's
            // sequential retention — a read above the first `<+` sees nothing
            // retained — while a §9.4 display operand is lowered from
            // `lowerDeferredDisplays` with `self.cur` past the whole block, so
            // it sees the §9.4.1 CONVERGED end-of-cycle value, §5.6.1.3
            // retention-select phis included (§5.8's conditional arms come out
            // as `readVariable`'s phis with nothing written here).
            //
            // §5.6.6 FIRST: inside a `<+`'s own right-hand side, a read of the
            // SAME branch is the implicit form — "the value of the target may
            // be expressed in terms of itself" — and its value is the one "the
            // underlying implementation ... will find", i.e. the branch-flow
            // unknown, never the retained prefix. Ahead of `flowAccum` because
            // the statement's own entry already exists by the time its rhs
            // lowers (`contribIndex` runs first), and the accumulator it would
            // find is exactly the stale self-reference §5.6.6 rules out.
            // ponytail: the unknown this mints has no defining row — no
            // fixture `//! solve`s an implicit flow (the harness sweeps it);
            // the day one does, codegen owes `x[u] − Σ contributions = 0`, the
            // same shape `portFlowRead` documents for `I(<p>)`.
            if (self.contrib_target) |ct| {
                if (ct.access == .flow and t.access == .flow and
                    ct.hi == t.hi and ct.lo == t.lo and ct.br == t.br)
                {
                    const u = try self.flowUnknown(t.hi, t.lo);
                    const v = try self.probe(u);
                    return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
                }
            }
            // Only once a flow contribution has ALREADY been lowered onto this
            // pair, which is the distinction the clause draws: an uncontributed
            // branch is a §5.4.2.1 flow PROBE — a short whose current is a
            // genuine unknown of the solve — and a POTENTIAL source's branch
            // current is pinned by the branch row codegen emits for it. Both of
            // those keep the unknown and read it.
            if (self.flowAccum(t)) |acc| {
                // §5.6.1.2: the retained value of a source branch is the WHOLE
                // of what was contributed to it, and §5.4.2.2 makes that whole
                // readable. No clause lets a reactive term count for the node
                // equation and not for a probe.
                //
                // The reactive half is retained as a CHARGE — the clause strips
                // one `ddt` off the contributed term — so reading the FLOW back
                // has to differentiate it again. That is a second `ddt`
                // instance with its own operator state, which is what this
                // `call` mints, and it is the honest cost: the current of a
                // capacitor IS a derivative. A model computing its own
                // dissipation, a charge-conservation check, or §5.4.3's
                // transit-time term read zero until this existed.
                //
                // Only when there IS a reactive half. `.f_zero` is what the
                // entry-block seed leaves when nothing wrote the place, so an
                // ordinary resistive branch emits no operator and cannot newly
                // trip §5.8.1's conditional-operator rule.
                const r = try self.builder.readVariable(acc.resist, self.cur);
                const q = try self.builder.readVariable(acc.react, self.cur);
                const v = if (q == .f_zero) r else blk: {
                    const dq = try self.call("ddt", &.{q});
                    break :blk if (r == .f_zero) dq else try self.emit(.fadd, &.{ r, dq });
                };
                return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
            }
            const u = try self.flowUnknown(t.hi, t.lo);
            const v = try self.probe(u);
            return .{ .v = if (t.neg) try self.emit(.fneg, &.{v}) else v, .ty = .real };
        },
    }
}

/// The §5.6.1.2 retained-flow accumulator of the branch (hi, lo), if a `<+` has
/// already made it a flow source. Keyed exactly like `contribIndex` — on the
/// canonicalised pair, so `I(n,p)` finds the one entry `I(p,n)` created.
fn flowAccum(self: *const Lower, t: Target) ?Accum {
    for (self.contributions.items, self.accum.items) |c, acc| {
        if (c.kind == .direct and c.access == .flow and c.hi == t.hi and c.lo == t.lo and c.br == t.br)
            return acc;
    }
    return null;
}

/// LRM §5.4.3 port access — `I(<p>)`.
///
/// "The port access function accesses the flow into a port of a module. ...
/// However (<>) is used to delimit the port name, e.g., I(<a>) accesses the
/// current through module port a."
///
/// By KCL that current is precisely the sum of everything this module stamps at
/// `p`, i.e. the residual codegen is in the middle of assembling — so it cannot
/// be an expression over the other units without a cycle. It becomes its own
/// solver unknown, exactly like the §5.4.2 branch-flow unknown, and codegen
/// pins it with the row `x[u] − Σ stamps at p`.
fn lowerPortAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    return self.portFlowRead(e, try self.nodeOf(self.file.exprs.lhs(e)));
}

/// The read half of §5.4.3, shared by `I(<p>)` and by a §3.12.1 port branch
/// named over the same port: the two spellings are one quantity, so they must
/// be one unknown and one set of rules. `p` is the port's `node_order` slot —
/// resolved by the caller, because the two spellings name it differently (an
/// argument expression here, a branch declaration there).
fn portFlowRead(self: *Lower, e: Ast.ExprId, p: u16) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.err(self.file.exprs.mainTok(e), .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.num_ports) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, self.nodeName(p) });
        if (diag.didYouMeanMap(self.nodeName(p), self.node_voltages)) |s|
            b.help("did you mean `{s}`?", .{s});
        try b.emit();
        return poison;
    }
    // §4.4 the name still has to be the port discipline's flow access.
    try self.checkAccessMatch(e, name, access, p);
    return .{ .v = try self.probe(try self.portFlowUnknown(p)), .ty = .real };
}

// ---- §4.3 math functions (Tables 4-14 and 4-15) ----------------------------

/// LRM Table 4-14 §4.3.1 / Table 4-15 §4.3.2 — the real-valued one-argument
/// functions, by their LRM spelling. `log` is base 10 (`log10` in MIR).
pub fn unaryMathOp(name: []const u8) ?Mir.Opcode {
    return unary_math.get(name);
}

/// LRM Table 4-14 — the real-valued two-argument functions.
pub fn binaryMathOp(name: []const u8) ?Mir.Opcode {
    return binary_math.get(name);
}

// File-scope so `unknownCall` can offer `.keys()` as did-you-mean candidates:
// a misspelled built-in is the commonest way to reach E0512, and the LRM's own
// spelling is the answer.
const unary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "expm1", .expm1 },
    .{ "ln", .ln },       .{ "ln1p", .ln1p },   .{ "log", .log10 },
    .{ "floor", .floor }, .{ "ceil", .ceil },   .{ "sin", .sin },
    .{ "cos", .cos },     .{ "tan", .tan },     .{ "asin", .asin },
    .{ "acos", .acos },   .{ "atan", .atan },   .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "tanh", .tanh },   .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },
});

const binary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
});

/// §4.3 built-in math. `abs`/`min`/`max` keep integer operands integer
/// (§4.3.1: "if both operands are integer the result is integer").
fn lowerBuiltin(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);

    if (unaryMathOp(name)) |op| {
        if (args.len != 1) return self.arityError(e, name, 1);
        const a = try self.lowerExpr(args[0]);
        return .{ .v = try self.emit(op, &.{try self.toReal(a)}), .ty = .real };
    }
    if (binaryMathOp(name)) |op| {
        if (args.len != 2) return self.arityError(e, name, 2);
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        return .{ .v = try self.emit(op, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real };
    }
    if (std.mem.eql(u8, name, "abs")) {
        if (args.len != 1) return self.arityError(e, name, 1);
        const a = try self.lowerExpr(args[0]);
        const int = a.ty == .integer;
        return .{ .v = try self.emit(if (int) .iabs else .fabs, &.{a.v}), .ty = a.ty };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len != 2) return self.arityError(e, name, 2);
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        const ty = unify(a.ty, b.ty);
        const is_min = name[1] == 'i';
        const op: Mir.Opcode = if (ty == .real)
            (if (is_min) .fmin else .fmax)
        else
            (if (is_min) .imin else .imax);
        const lv = if (ty == .real) try self.toReal(a) else a.v;
        const rv = if (ty == .real) try self.toReal(b) else b.v;
        return .{ .v = try self.emit(op, &.{ lv, rv }), .ty = ty };
    }
    try self.unknownCall(e, name);
    return poison;
}

/// E0512 with a suggestion drawn from everything that COULD have been called
/// here: the module's §4.7 analog functions and the §4.3 built-ins of Tables
/// 4-14/4-15. `m.functions` is a slice, not a map, so the candidates are
/// collected before `didYouMean` sees them — and the built-in names ride in the
/// same list so one call picks the single nearest of the whole set.
fn unknownCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    var b = self.errWith(self.file.exprs.mainTok(e), .E0512);
    b.msg("`{s}`", .{name});

    var names: std.ArrayList([]const u8) = .empty;
    if (self.module) |m| {
        for (m.functions) |*fd| try names.append(self.arena, self.file.str(fd.name));
    }
    try names.appendSlice(self.arena, unary_math.keys());
    try names.appendSlice(self.arena, binary_math.keys());
    // §3.13.2 access functions land here too: the parser routes `Vv(p,n)` to a
    // function call precisely BECAUSE `Vv` is not an access name, so `V` is the
    // answer far more often than any analog function is.
    var it = self.access_kind.keyIterator();
    while (it.next()) |k| try names.append(self.arena, k.*);
    if (diag.didYouMean(name, names.items)) |s| b.suggestHere(s);

    return b.emit();
}

fn arityError(self: *Lower, e: Ast.ExprId, name: []const u8, want: usize) Oom!TypedValue {
    try self.err(self.file.exprs.mainTok(e), .E0506, "`{s}()` takes {d}", .{ name, want });
    return poison;
}

// ---- §4.5 analog operators / filters ---------------------------------------

/// §4.5 analog operators. Each occurrence owns simulator state, so every one
/// stays a distinct `call` instruction carrying its arguments — codegen
/// allocates one Instance state slot per call site (§4.5.2).
///
/// Vector coefficient arguments (§4.5.11 laplace_*, §4.5.12 zi_*) are
/// FLATTENED into the argument list as `<count>, e0, e1, …`, so the call is
/// self-describing without a second pool.
/// The two A.8.2 `analog_filter_function_call` names that keep NO history.
///
/// §5.8.1 bans "an analog operator" under a runtime condition, and both of these
/// are listed in §4.5, so the letter of the rule covers them. Its stated reason
/// does not: §4.5.6 makes `ddx` a derivative of the expression as it stands on
/// THIS evaluation, and §4.5.13 makes `limexp` a piecewise-linear substitution
/// for `exp` past a critical voltage. Neither reads a previous timestep, so
/// neither can carry a wrong history out of a branch that was off — and E0514's
/// whole claim is about corrupted history. Warning on them would be noise that
/// teaches a modeller to silence the code; `vdmos.va` uses conditional `limexp`
/// three times and is right to.
fn isHistoryless(name: []const u8) bool {
    return std.mem.eql(u8, name, "ddx") or std.mem.eql(u8, name, "limexp");
}

fn lowerFilter(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx});
        return poison;
    }
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);

    // §5.8.1 / §5.9: an analog operator is a state machine the kernel advances
    // once per accepted step, on the straight-line spine of the analog block.
    // Under a branch the solve can flip, the step its arm was off feeds it the
    // type's zero instead of the real input, and its history is wrong from then
    // on.
    if (self.cond_depth != self.static_cond_depth and !isHistoryless(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0514);
        b.msg("`{s}`", .{name});
        b.help("hoist `{s}(...)` onto the spine and make only its USE conditional", .{name});
        try b.emit();
    }

    // §4.5.6 ddx(f, V(node)) — the second argument is a probe, not a value:
    // it names the unknown to differentiate with respect to.
    if (std.mem.eql(u8, name, "ddx")) {
        if (args.len != 2) return self.arityError(e, name, 2);
        const f = try self.toReal(try self.lowerExpr(args[0]));
        if (ex.tag(args[1]) != .branch_access) {
            try self.err(self.file.exprs.mainTok(e), .E0504, "", .{});
            return poison;
        }
        const t = try self.branchOf(args[1]) orelse return poison;
        // §4.5.6: "The second argument shall be the potential of a scalar net
        // or port or the flow through a branch, because these are the unknown
        // variables in the system of equations for the analog solver."
        //
        // `V(p, n)` is neither. It is the DIFFERENCE of two unknowns, and the
        // operator is defined as the partial derivative "holding all other
        // unknowns fixed" — which V(p)-V(n) makes unanswerable, since d/dV(p)
        // and -d/dV(n) are both defensible readings and they differ. §4.5.6's
        // own vccs example puts the two-node probe in the EXPRESSION and a
        // single-node probe in the second slot. A FLOW is exempt: a branch
        // current is one unknown however many nets the branch spans.
        if (t.access == .potential and t.lo != ground) {
            try self.err(self.file.exprs.mainTok(args[1]), .E0504, "a potential across two nets is not one unknown", .{});
            return poison;
        }
        const u: u16 = switch (t.access) {
            .potential => t.hi,
            // PEEK — never mint. §4.5.6's closing sentence: "If the expression
            // does not depend explicitly on the unknown, then ddx() returns
            // zero (0)." A flow no probe has made a system unknown CANNOT be
            // depended on: the only way a branch current enters an expression
            // is through an `I()` read, and every read routes through
            // `flowUnknown` — including any inside THIS ddx's first argument,
            // which was lowered above, so the peek runs after every mint that
            // could matter. Minting here declared an unknown no equation ever
            // pins (the probe-branch row only exists for a READ branch): an
            // all-zero Jacobian row and a structurally singular system. And
            // recording a branch READ instead would make the pair a flow-probe
            // branch — a 0 V short §4.5.6 gives a derivative operator no
            // license to add to the topology. Absent unknown = the plain 0.
            .flow => self.flow_unknowns.get(.{ .hi = t.hi, .lo = t.lo }) orelse
                return .{ .v = .f_zero, .ty = .real },
        };
        const d = try self.call("ddx", &.{ f, try self.mir.addIntConst(self.arena, u) });
        // §1.3.1.2 again: `ddx(f, I(n,p))` differentiates with respect to the
        // negation of the one canonical unknown, so the derivative negates too.
        // A potential probe reaches here only in the single-net form, which the
        // check above enforces and which is never reversed.
        return .{ .v = if (t.neg) try self.emit(.fneg, &.{d}) else d, .ty = .real };
    }

    // A.8.2 fixes each operator's MANDATORY arguments — everything left of the
    // grammar's first `[`. The per-slot loop below judges only slots that were
    // WRITTEN (`ddt(,1.0)` → E0505), so a list that stops early has to be
    // measured against the grammar here: `ddt()` otherwise skipped the loop
    // entirely and became a silent zero, `absdelay(x)` a delay of nothing.
    // The laplace forms mandate three slots — both vector commas sit outside
    // the brackets, so a slot may be NULL (the loop's `nullZerosOk` carve-out
    // governs which) but it must be THERE — and the zi forms four (…, T).
    const min_args: usize = if (std.mem.eql(u8, name, "absdelay"))
        2
    else if (std.mem.startsWith(u8, name, "laplace_"))
        3
    else if (std.mem.startsWith(u8, name, "zi_"))
        4
    else
        1; // ddt, idt, idtmod, transition, slew, last_crossing, limexp
    if (args.len < min_args) {
        try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()` needs {d} argument(s), got {d}", .{ name, min_args, args.len });
        return poison;
    }

    try self.checkFilterArgBounds(name, args); // §4.5.5-§4.5.10

    const abstol_slot = abstolSlot(name);

    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args, 0..) |a, i| {
        // A.8.2 analog_filter_function_call has no `analog_expression_or_null`
        // form: every declared argument must be present (§4.5.14).
        //
        // §4.5.15 states the rule with its own escape hatch — "It is illegal to
        // specify a null argument in the argument list of an analog operator,
        // EXCEPT AS SPECIFIED ELSEWHERE in this document" — and §4.5.11/§4.5.12
        // are what the exception points at, in the identical sentence: "The
        // zeros argument may be represented as a null argument. The null
        // argument is characterized by two adjacent commas (,,) in the argument
        // list." §4.5.11.5's own band-limited-noise example writes it. An empty
        // zeros vector is an empty PRODUCT, hence the numerator 1 — which is
        // why the carve-out is only for the root forms (`*_zp`, `*_zd`), where
        // the slot is a list of roots. In `*_np`/`*_nd` the same slot is a
        // coefficient vector, and an empty one has no such reading.
        if (a == .none) {
            if (i == 1 and nullZerosOk(name)) {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, 0));
                continue;
            }
            try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()`", .{name});
            return poison;
        }
        // A.8.3 `abstol_expression ::= constant_expression | nature_identifier`.
        // The second arm is the ONLY place a nature name is a value, so it is
        // resolved here and not in `lookupName`: natures and disciplines share
        // one global scope (§3.13.1), and letting that scope answer general
        // identifier lookup would shadow every variable named after a nature.
        if (abstol_slot == i) {
            if (self.natureAbstol(a)) |t| {
                try vals.append(self.arena, try self.mir.addFloatConst(self.arena, t));
                continue;
            }
        }
        if (try self.appendVectorArg(&vals, a)) continue;
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    return .{ .v = try self.call(name, vals.items), .ty = .real };
}

/// Which argument of an analog operator is its TOLERANCE, or null for an
/// operator that has none. §5.5.3, last sentence: "The abstol attribute of a
/// nature may also be accessed simply by using the nature's identifier as the
/// appropriate argument to the ddt(), idt(), or idtmod() operators described in
/// 4.5." Those three, and the slot each of their signatures puts it in:
///
///     4.5.3  ddt(expr [, abstol|nature])
///     4.5.4  idt(expr [, ic [, assert [, abstol|nature]]])
///     4.5.5  idtmod(expr [, ic [, modulus [, offset [, abstol|nature]]]])
///
/// Every one is the LAST slot, but they are written out rather than computed
/// from `args.len` because a call that has dropped a trailing argument would
/// then read its `assert` or its `offset` as a tolerance.
fn abstolSlot(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "ddt")) return 1;
    if (std.mem.eql(u8, name, "idt")) return 3;
    if (std.mem.eql(u8, name, "idtmod")) return 4;
    return null;
}

/// The abstol a bare `nature_identifier` in a tolerance slot stands for, or
/// null when the expression is not one — in which case the caller lowers it as
/// the `constant_expression` arm of A.8.3 and every ordinary diagnostic applies.
///
/// The ordinary scopes are consulted FIRST, so a variable or parameter that
/// happens to share a nature's name still wins here exactly as it does
/// everywhere else (§2.8). Only a name nothing else answers reaches the nature
/// table.
/// The §4.5.3/§5.5.3 tolerance slot as a value, with its diagnostics. Returns
/// null when the slot holds an ordinary expression, which the caller lowers as
/// A.8.3's `constant_expression` arm.
fn lowerAbstolArg(self: *Lower, e: Ast.ExprId) Oom!?f64 {
    if (self.natureAbstol(e)) |t| return t;
    // A `.banned` reference has no value; `lowerExpr` is where E0359 lives, so
    // the argument is lowered for its diagnostic and the result discarded.
    if (self.file.exprs.tag(e) == .hier_ident) _ = try self.lowerExpr(e);
    return null;
}

fn natureAbstol(self: *Lower, e: Ast.ExprId) ?f64 {
    const ex = &self.file.exprs;
    // §5.5.3's other spelling of the same value, `n1.potential.abstol`. Its last
    // sentence makes the two interchangeable in this slot: "The abstol attribute
    // of a nature may ALSO be accessed simply by using the nature's identifier
    // as the appropriate argument to the ddt(), idt(), or idtmod() operators".
    if (ex.tag(e) == .hier_ident) {
        // A `.banned` attribute is diagnosed by `lowerExpr`, which every caller
        // falls through to; returning null here is what routes it there.
        const r = self.natureAttrRef(e) orelse return null;
        return switch (r) {
            .value => |c| switch (c) {
                .real, .int => c.asReal(),
                .str => null,
            },
            .banned => null,
        };
    }
    if (ex.tag(e) != .ident) return null;
    const id = ex.strOf(e);
    const name = self.file.str(id);
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    for (self.file.natures) |*n| {
        if (n.name != id) continue;
        // §3.6.1.2 makes `abstol` mandatory on a base nature and inherited by a
        // derived one, and `checkNatureTable` has already refused a nature with
        // neither, so the fallback is only ever reached on a compile that is
        // failing anyway. It is here so that this returns "yes, a nature" and
        // the name does not also collect an E0314.
        return self.natureOf(id).abstol orelse 0;
    }
    return null;
}

/// §5.5.3 Syntax 5-4 `nature_attribute_reference ::= net_identifier .
/// potential_or_flow . nature_attribute_identifier` — "the attributes for a net
/// or a branch can be accessed by using the hierarchical referencing operator
/// (.) to the potential or flow for the net or branch". §5.5.3's own twocap
/// example is `ddt(V(a,b), a.potential.abstol)`.
///
/// A constant, resolved at elaboration: the net's discipline decides which
/// nature each half binds, and a nature attribute "shall be constant"
/// (§3.6.1.3). Null when the expression is a §6.8 hierarchical name instead,
/// which is the other thing `.hier_ident` carries.
///
/// `abstol` comes from `DisciplineInfo` and not from the nature, deliberately:
/// §3.6.2.3 lets a DISCIPLINE override its bound nature's tolerance, and that
/// map is where the override has already been applied.
///
/// The sentence right after Syntax 5-4 is enforced by the same walk: "This
/// syntax shall not be used for the access, ddt_nature, or idt_nature attributes
/// of a nature, nor any other attribute whose value is not a constant
/// expression." Those three name an IDENTIFIER, so there is nothing to fold —
/// which is why the ban and the fold are one test (`.banned`) and not two.
const NatureRef = union(enum) {
    value: Const,
    /// The attribute named, for the message.
    banned: []const u8,
};
fn natureAttrRef(self: *Lower, e: Ast.ExprId) ?NatureRef {
    const parts = self.file.exprs.nameParts(e);
    if (parts.len != 3) return null;
    const half = self.file.str(parts[1]);
    const is_potential = std.mem.eql(u8, half, "potential");
    if (!is_potential and !std.mem.eql(u8, half, "flow")) return null;

    const net = self.file.str(parts[0]);
    const idx = self.node_voltages.get(net) orelse return null;
    if (idx == ground) return null;
    const dname = self.node_disciplines.items[idx];
    const attr = self.file.str(parts[2]);

    if (std.mem.eql(u8, attr, "abstol")) {
        const info = self.disciplines.get(dname) orelse return null;
        return .{ .value = .{ .real = if (is_potential) info.potential_abstol else info.flow_abstol } };
    }
    // ponytail: reuse compatibility's first-declaration lookup.
    const d = self.disciplineDecl(dname) orelse return null;
    const nat = if (is_potential) d.potential else d.flow;
    if (nat == .none) return null;
    const v = self.file.natureAttrExpr(nat, attr) orelse return .{ .banned = attr };
    return .{ .value = self.constEval(v) orelse return .{ .banned = attr } };
}

/// §4.5.5-§4.5.10 control-argument bounds. Each operator states its bound in
/// one sentence and each bound is what makes the operator's own contract
/// satisfiable — see E0516 for the five sentences.
///
/// FOLDED OPERANDS ONLY, and that restraint is the rule and not a shortcut:
/// A.8.2 types these slots `analog_expression`, not `constant_expression`, so
/// `transition(x, 0, tr, tf)` over parameters is a legal model whose signs are
/// unknowable here. `constEval` returning null is silence. Rejecting what
/// cannot be proven would break every parameterised rise time in the wild.
///
/// Here and not in codegen because this is a claim about the ARGUMENT: by the
/// time a filter is a `call` its arguments are positional values and the LRM's
/// own names for them — the words the diagnostic has to say — are gone.
fn checkFilterArgBounds(self: *Lower, name: []const u8, args: []const Ast.ExprId) Oom!void {
    const Bound = enum {
        positive,
        non_negative,
        negative,

        fn holds(b: @This(), v: f64) bool {
            return switch (b) {
                .positive => v > 0,
                .non_negative => v >= 0,
                .negative => v < 0,
            };
        }
        /// The LRM's own word for the bound; it goes in the message.
        fn word(b: @This()) []const u8 {
            return switch (b) {
                .positive => "positive",
                .non_negative => "non-negative",
                .negative => "negative",
            };
        }
    };
    const Rule = struct { i: usize, arg: []const u8, want: Bound };
    const rules: []const Rule = if (std.mem.eql(u8, name, "idtmod"))
        &.{.{ .i = 2, .arg = "modulus", .want = .positive }}
    else if (std.mem.eql(u8, name, "absdelay"))
        // "In all cases" covers the optional-maxdelay form too, so the index is
        // the same for both spellings.
        &.{.{ .i = 1, .arg = "td", .want = .positive }}
    else if (std.mem.eql(u8, name, "transition"))
        &.{
            .{ .i = 1, .arg = "td", .want = .non_negative },
            .{ .i = 2, .arg = "rise_time", .want = .non_negative },
            .{ .i = 3, .arg = "fall_time", .want = .non_negative },
            .{ .i = 4, .arg = "time_tol", .want = .non_negative },
        }
    else if (std.mem.eql(u8, name, "slew"))
        // Checked on the WRITTEN arguments, before §4.5.9's "if the
        // max_neg_slew_rate is not specified, it defaults to the opposite of
        // the max_pos_slew_rate" can manufacture a well-signed second rate out
        // of a badly-signed first one.
        &.{
            .{ .i = 1, .arg = "max_pos_slew_rate", .want = .positive },
            .{ .i = 2, .arg = "max_neg_slew_rate", .want = .negative },
        }
    else
        &.{};

    for (rules) |r| {
        if (r.i >= args.len or args[r.i] == .none) continue;
        const c = self.constEval(args[r.i]) orelse continue;
        if (c == .str) continue; // a type error, not a range one
        const v = c.asReal();
        if (r.want.holds(v)) continue;
        try self.err(self.file.exprs.mainTok(args[r.i]), .E0516, "`{s}()` argument `{s}` shall be {s}, got {d}", .{ name, r.arg, r.want.word(), v });
    }

    // §4.5.10: "The optional direction indicator shall evaluate to an integer
    // expression +1, -1, or 0." An enumeration of three, not a range — +2 does
    // not select anything and there is nothing to clamp it onto.
    if (std.mem.eql(u8, name, "last_crossing") and args.len > 1 and args[1] != .none) {
        if (self.constEval(args[1])) |c| {
            const v = c.asReal();
            if (c != .str and (v != @round(v) or @abs(v) > 1))
                try self.err(self.file.exprs.mainTok(args[1]), .E0516, "`last_crossing()` direction indicator shall be +1, -1 or 0, got {d}", .{v});
        }
    }
}

/// §4.5.11/§4.5.12 filter coefficient vectors and §9.21/§4.6.4 noise data
/// vectors: an assignment pattern `'{a,b}` or the name of an array parameter
/// (§3.4.4). Flattened into the call as `<count>, e0, e1, …`, so the argument
/// list stays self-describing. Returns false when `a` is an ordinary scalar.
/// §4.5.11/§4.5.12: does this filter take its ZEROS as a root vector, so that
/// the null form `f(x, , poles, …)` reads as the empty product 1?
fn nullZerosOk(name: []const u8) bool {
    const forms = [_][]const u8{ "laplace_zp", "laplace_zd", "zi_zp", "zi_zd" };
    for (forms) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

fn appendVectorArg(self: *Lower, out: *std.ArrayList(Mir.Value), a: Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(a)) {
        .assign_pattern, .concat => {
            const elems = ex.args(a);
            try out.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(elems.len)));
            for (elems) |el|
                try out.append(self.arena, try self.toReal(try self.lowerExpr(el)));
            return true;
        },
        .ident => {
            const name = self.file.str(ex.strOf(a));
            const info = self.arrays.get(name) orelse return false;
            // §4.5.11's coefficient slot is a FLAT vector: a multidimensional
            // array has no reading as a list of poles and is left to the
            // ordinary path, which reports it (E0356).
            if (info.dims.len != 1) return false;
            const d = info.dims[0];
            try out.append(self.arena, try self.mir.addIntConst(self.arena, d.count()));
            var index: [1]i64 = undefined;
            for (0..@intCast(d.count())) |k| {
                shapeSubscripts(info.dims, k, &index);
                const el = (try self.arrayElemValue(name, &index)) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        else => return false,
    }
}

/// §4.6.4 noise sources. They contribute only in a small-signal noise
/// analysis; codegen decides that from the call name (the value is 0 in DC).
fn lowerNoise(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // §4.6.4 the PSD arguments, positionally: arg 0 is the power, arg 1 of
    // `flicker_noise` is the exponent. Recorded HERE — this is the only place
    // the call's arguments are lowered, and `noiseSrcsOf` walks the AST after
    // the fact, where the MIR values are no longer reachable from the id.
    // §4.6.3 has its OWN defaults for the same two slots — "The default
    // magnitude is one (1) and the default phase is zero (0)" — and seeding
    // them here is what makes a bare `ac_stim()` export the unit source the
    // clause describes instead of a magnitude of zero.
    var psd: [2]Mir.Value = if (std.mem.eql(u8, name, "ac_stim"))
        .{ .f_one, .f_zero }
    else
        .{ .f_zero, .f_one };
    var reals: usize = 0;
    // §4.6.4.3/.4 the table itself. `appendVectorArg` writes the element COUNT
    // and then the elements, so the pairs are the slice after that count — the
    // same vector spelling §4.5.11's filter coefficients arrive in, which is
    // why this needs no reader of its own.
    var tab: ?struct { usize, usize } = null;
    for (ex.args(e)) |a| {
        if (a == .none) continue;
        const at = vals.items.len;
        if (try self.appendVectorArg(&vals, a)) {
            // Indices, not a slice: `vals` keeps growing and may reallocate.
            if (tab == null) tab = .{ at + 1, vals.items.len };
            continue;
        }
        const tv = try self.lowerExpr(a);
        if (tv.ty == .string) {
            try vals.append(self.arena, tv.v);
            continue;
        }
        const rv = try self.toReal(tv);
        if (reals < 2) psd[reals] = rv;
        reals += 1;
        try vals.append(self.arena, rv);
    }
    // §4.6.4.1 `white_noise(pwr[, name])` has one real argument and §4.6.4.2's
    // `flicker_noise(pwr[, exp[, name]])` defaults `exp` to 1, so the `.f_one`
    // seed is the answer whenever the loop above did not overwrite it.
    try self.noise_psd.put(self.arena, @intFromEnum(e), psd);
    if (tab) |r| try self.noise_tab.put(
        self.arena,
        @intFromEnum(e),
        try self.arena.dupe(Mir.Value, vals.items[r[0]..r[1]]),
    );
    const result = try self.call(name, vals.items);
    try self.noise_val.put(self.arena, @intFromEnum(e), result);
    return .{ .v = result, .ty = .real };
}

/// §4.6.4.6 `∂contribution/∂generator`, over the MIR that is already built.
///
/// A noise function is an AMPLITUDE and a contribution combines amplitudes
/// linearly — that is what makes "perfectly correlated noise is generated by
/// using the output of one noise function for more than one noise source"
/// meaningful — so the derivative is a CONSTANT with respect to the generator
/// and is exactly the factor the branch applies to it.
///
/// Over the DAG and not over the AST: re-lowering the expression to read its
/// shape would duplicate every side effect in it, and the values this needs
/// (the other operand of each multiply) already exist as SSA names. Nothing
/// here evaluates anything; it emits a handful of arithmetic nodes that
/// reference values the contribution already computed.
///
/// Three answers, and the difference between the last two is the whole reason
/// this is not an optional:
///   absent     the generator does not occur here, so its coefficient is 0 and
///              this statement adds nothing to the branch's total;
///   nonlinear  it occurs in a shape no single factor describes (squared, in a
///              denominator, inside a call), so there IS no coefficient;
///   value      the factor.
const Coeff = union(enum) { absent, nonlinear, value: Mir.Value };

/// `-v`, folded when `v` is a literal. A coefficient is very often a bare
/// parameter or number, and a folded one renders inline in `noisePsd` instead
/// of taking a core live-out slot for `0.0 - 3.0`.
fn coeffNeg(self: *Lower, v: Mir.Value) Oom!Mir.Value {
    if (self.mir.valueDef(self.mir.resolveAlias(v)) == .float_const)
        return self.mir.addFloatConst(self.arena, -self.mir.valueDef(self.mir.resolveAlias(v)).float_const);
    return self.emit(.fneg, &.{v});
}

/// `a · b`, with the identity folded away. The derivative of `c * n` is
/// `c * 1`, and emitting that multiply would hide the constant from
/// `psdConst`.
fn coeffMul(self: *Lower, a: Mir.Value, b: Mir.Value) Oom!Mir.Value {
    if (a == .f_one) return b;
    if (b == .f_one) return a;
    return self.emit(.fmul, &.{ a, b });
}

fn noiseCoeff(self: *Lower, v: Mir.Value, n: Mir.Value, depth: u16) Oom!Coeff {
    if (depth == 64) return .nonlinear;
    const value = self.mir.resolveAlias(v);
    const gen = self.mir.resolveAlias(n);
    if (value == gen) return .{ .value = .f_one };
    const inst = switch (self.mir.valueDef(value)) {
        .inst_result => |i| i,
        // A constant, a parameter or a probe cannot contain the generator.
        else => return .absent,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            const d = try self.noiseCoeff(u.operand, gen, depth + 1);
            if (d == .absent) return .absent;
            if (u.op != .fneg or d == .nonlinear) return .nonlinear;
            return .{ .value = try self.coeffNeg(d.value) };
        },
        .binary => |b| {
            const da = try self.noiseCoeff(b.lhs, gen, depth + 1);
            const db = try self.noiseCoeff(b.rhs, gen, depth + 1);
            if (da == .absent and db == .absent) return .absent;
            if (da == .nonlinear or db == .nonlinear) return .nonlinear;
            switch (b.op) {
                .fadd, .fsub => {
                    // A side that does not mention the generator contributes
                    // the zero this skips rather than emits.
                    if (da == .absent) return .{
                        .value = if (b.op == .fadd) db.value else try self.coeffNeg(db.value),
                    };
                    if (db == .absent) return .{ .value = da.value };
                    return .{ .value = try self.emit(if (b.op == .fadd) .fadd else .fsub, &.{ da.value, db.value }) };
                },
                // The generator on both sides of a multiply is the generator
                // SQUARED, which is not a linear source and has no coefficient.
                .fmul => {
                    if (da != .absent and db != .absent) return .nonlinear;
                    if (da == .absent) return .{ .value = try self.coeffMul(b.lhs, db.value) };
                    return .{ .value = try self.coeffMul(da.value, b.rhs) };
                },
                // Dividing BY the generator is nonlinear for the same reason.
                .fdiv => {
                    if (db != .absent) return .nonlinear;
                    return .{ .value = try self.emit(.fdiv, &.{ da.value, b.rhs }) };
                },
                else => return .nonlinear,
            }
        },
        // §4.2.12 `?:` — either arm may carry the generator, and which arm runs
        // is a solve-time question, so the coefficient is the same conditional.
        .ternary => |t| {
            const dy = try self.noiseCoeff(t.then_val, gen, depth + 1);
            const dn = try self.noiseCoeff(t.else_val, gen, depth + 1);
            if (dy == .absent and dn == .absent) return .absent;
            if (dy == .nonlinear or dn == .nonlinear) return .nonlinear;
            return .{ .value = try self.emit(.select, &.{
                t.cond,
                if (dy == .absent) .f_zero else dy.value,
                if (dn == .absent) .f_zero else dn.value,
            }) };
        },
        // A call's arguments are reachable, so "does the generator occur in
        // here at all" is answerable even though the derivative is not.
        .call => |c| {
            for (c.args) |arg| if (try self.noiseCoeff(arg, gen, depth + 1) != .absent) return .nonlinear;
            return .absent;
        },
        else => return .nonlinear,
    }
}

// ---- ch9 system functions ---------------------------------------------------

/// ch9 system function in expression position. Everything not on the
/// deliberately-unsupported list becomes a `call`; codegen.emitCall dispatches
/// on the name and owns the simulator semantics.
fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (isDigitalOnlySysFunc(name)) { // §9.2
        try self.err(self.file.exprs.mainTok(e), .E0806, "`{s}`", .{name});
        return poison;
    }
    // §9.22/§9.23 — the driver access family, refused because this is not a
    // connect module (see `isConnectModuleOnlySysFunc` for why the test is a
    // name test today and what it narrows into later).
    if (isConnectModuleOnlySysFunc(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0818);
        b.msg("`{s}` can only be called from a connect module", .{name});
        b.note("§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`", .{});
        try b.emit();
        return poison;
    }
    // §3.4.7/§9.18: this module wrote `aliasparam m = $mfactor;`, so the two
    // names denote one location and the location is the parameter the alias
    // declared (`aliasSystemParam`). Both spellings read it — §3.4.7 rule 2 has
    // the equations use the ORIGINAL name, which is this one.
    if (self.mfactor_param) |pi| if (std.mem.eql(u8, name, "$mfactor"))
        return .{ .v = self.param_values.items[pi], .ty = .real };
    // §9.13 Table 9-10. Before everything below, because the seed is an inout
    // argument and the write-back is not something a `call` result can express.
    if (try self.lowerRandom(ex.mainTok(e), name, ex.args(e))) |tv| return tv;
    // Annex G Table G.1: the OVI Verilog-A v1.0 spelling `$limexp` was replaced
    // in v2.0 by the bare `limexp` (§4.5.13). Not an alias — a `$` name is a
    // system function and `$limexp` is in neither Table 9-11 nor A.8.2, so the
    // name does not exist. One entry, not a table: it is the only retired v1.0
    // `$` spelling in G.1 that VerA ever accepted.
    if (std.mem.eql(u8, name, "$limexp")) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0808);
        b.msg("`$limexp`", .{});
        b.suggestHere("limexp");
        try b.emit();
        return poison;
    }
    // §9.17.3 fixes the arity of the two algorithms it names outright: fetlim
    // takes a third argument (the threshold voltage) and pnjlim a third and a
    // fourth (vte and vcrit). Checked HERE and not in cg_limit.zig, where the
    // count was already known: cg_limit's job is to decide whether the backend
    // can honour a well-formed call, and §4.5.15 lets it decline any of them
    // silently — a call that is not legal in the first place is a source error
    // and has to be reported whether or not codegen would have taken it.
    //
    // Only these two names, and only when the string is written literally: the
    // same clause says a simulator may treat an unknown or unsupported string
    // "just as if no string had been supplied", so nothing else here is an
    // error, and `$limit(V(a))` with no string at all is Syntax 9-12 line 1.
    if (std.mem.eql(u8, name, "$limit")) {
        const args = ex.args(e);
        if (args.len >= 2) {
            if (self.constEval(args[1])) |c| switch (c) {
                .str => |s| {
                    const need: usize = if (std.mem.eql(u8, s, "pnjlim"))
                        4
                    else if (std.mem.eql(u8, s, "fetlim")) 3 else 0;
                    if (need != 0 and args.len < need) {
                        var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
                        b.msg("`\"{s}\"` needs {d} arguments to `$limit`, got {d}", .{ s, need, args.len });
                        try b.emit();
                        return poison;
                    }
                },
                else => {},
            };
        }
    }
    // §9.15: "If param_name is not known, and the optional expression is not
    // supplied, then an error is generated." Answering a name this engine does
    // not have with a silent 0.0 is indistinguishable from a simulator that
    // really does carry that parameter and really does read zero, which is the
    // corruption the clause exists to prevent.
    //
    // Only when the name is a literal: §9.15 also allows "a string parameter or
    // a string variable", and a name that is not known until the solve cannot be
    // judged here — the fallback rule is the user's cover for that case.
    if (std.mem.eql(u8, name, "$simprobe")) return self.lowerSimprobe(e);
    // §9.15 Table 9-28's two HIERARCHY rows are elaboration facts, so they are
    // answered here and never reach codegen: "module" is "the name of the module
    // from which $simparam$str is called" and "instance" is "the hierarchical
    // name of the instance from which $simparam$str is called". Codegen sees
    // one flattened module and answered them with the TOP's name and "" — right
    // only for a call that happens to sit in the top module. `cur_unit` is the
    // instance that wrote this block, which is exactly what the clause asks for.
    if (std.mem.eql(u8, name, "$simparam$str") and self.cur_unit < self.unit_paths.len) {
        const a = ex.args(e);
        if (a.len >= 1) if (self.constStrArg(a[0])) |nm| {
            const u = self.unit_paths[self.cur_unit];
            if (std.mem.eql(u8, nm, "module"))
                return .{ .v = try self.mir.addStrConst(self.arena, u.module), .ty = .string };
            // §9.15's worked example produces "testbench.dut1": a top-level
            // module's instance name is its module name, and the path is joined
            // to it by §6.7's period. `path` already carries the separator.
            if (std.mem.eql(u8, nm, "instance")) {
                const top = if (self.unit_paths.len != 0) self.unit_paths[0].module else u.module;
                const full = if (u.path.len == 0)
                    top
                else
                    try std.fmt.allocPrint(self.arena, "{s}{c}{s}", .{ top, Elaborate.sep, u.path[0 .. u.path.len - 1] });
                return .{ .v = try self.mir.addStrConst(self.arena, full), .ty = .string };
            }
        };
    }
    if (std.mem.eql(u8, name, "$simparam")) {
        const args = ex.args(e);
        if (args.len == 1) {
            if (self.constEval(args[0])) |c| switch (c) {
                .str => |s| if (self.simparamValue(s) == null and !simparamIsRuntime(s)) {
                    var b = self.errWith(self.file.exprs.mainTok(e), .E0811);
                    b.msg("`\"{s}\"`", .{s});
                    b.note("$simparam(\"{s}\", <expression>) supplies the value to use instead, and §9.15 makes that form legal for any name", .{s});
                    try b.emit();
                    return poison;
                },
                else => {},
            };
        }
        // The Newton-iterate counter costs an `Instance` field plus an
        // `updateState`/`stateCtl` pair, so it is emitted only for a model that
        // reads one of the two names that need it (`simparamIsRuntime`).
        if (args.len >= 1) if (self.constStrArg(args[0])) |s| {
            if (simparamIsRuntime(s)) self.uses_newton_iter = true;
            if (simparamHostField(s) != null) self.uses_host_simparam = true;
        };
    }
    const sys_args = if (ex.extraOf(e) < ex.pool.items.len) ex.args(e) else &[_]Ast.ExprId{};
    // §9.20 the two alias functions: six validity rules, all of them about the
    // CALL rather than the value, so all of them here (E0812) — and then the
    // alias, which is a `node_voltages` write and a constant return. The call
    // never reaches codegen: "one (1) if the hierarchical_reference_string
    // points to a valid continuous node and zero (0) otherwise" is decided by a
    // name lookup against the elaborated design, which is this pass's table.
    if (std.mem.eql(u8, name, "$analog_node_alias") or std.mem.eql(u8, name, "$analog_port_alias")) {
        return switch (try self.checkAliasCall(e, name, sys_args)) {
            .refused => poison,
            .bound => .{ .v = try self.mir.addIntConst(self.arena, 1), .ty = .integer },
            .unresolved => .{ .v = try self.mir.addIntConst(self.arena, 0), .ty = .integer },
        };
    }
    // §9.17.3 Syntax 9-12's THIRD form, `$limit(access, analog_function_identifier,
    // arg_list)`. The second argument names a §4.7 function, so it is not a value
    // and must not be looked up as one (E0314 was the whole gap).
    if (std.mem.eql(u8, name, "$limit") and sys_args.len >= 2) {
        if (self.limitUserFunc(sys_args[1])) |fd| {
            // "The arguments of the user-defined function shall all be declared
            // input." The simulator supplies all of them — the probe's value for
            // this iteration, the value $limit returned on the previous one, then
            // the call's tail — so an `output` formal would write back into the
            // solver's own iteration history mid-Newton-step, and §9.17.3 defines
            // no meaning for that.
            for (fd.args) |formal| {
                if (formal.direction == .input) continue;
                var b = self.errWith(self.file.exprs.mainTok(e), .E0814);
                b.msg("formal `{s}` of the `$limit` limiter `{s}` is declared `{s}`", .{
                    self.file.str(formal.name), self.file.str(fd.name), @tagName(formal.direction),
                });
                b.note("§9.17.3: \"The arguments of the user-defined function shall all be declared input\"", .{});
                try b.emit();
                return poison;
            }
            return self.lowerLimitUser(e, fd, sys_args);
        }
    }
    // §9.21 — Syntax 9-16 is not an ordinary argument list: it carries a data
    // SOURCE (arrays, or a file) and a control string, neither of which is a
    // value. `lowerTableModel` rewrites the call into one that is.
    if (std.mem.eql(u8, name, "$table_model")) return self.lowerTableModel(e);
    // §9.5.4.2 `$sscanf` writes through its arguments, which a `call` cannot do
    // — `lowerScan` turns the one source call into the assignments it means.
    if (std.mem.eql(u8, name, "$sscanf"))
        return .{ .v = try self.lowerScan(ex.mainTok(e), sys_args), .ty = .integer };
    // §9.5.4/§9.5.7 the same, for the three §9.5 calls with a destination
    // argument. Both halves are integer-valued (§9.5.4.1's character count,
    // §9.5.4.2's item count, §9.5.7's errno).
    if (try self.lowerFileRead(ex.mainTok(e), name, sys_args)) |v|
        return .{ .v = v, .ty = .integer };
    // §9.5.3 the two writers are TASKS: their whole content is the assignment to
    // the string variable, and in expression position there is nothing to assign.
    if (std.mem.eql(u8, name, "$swrite") or std.mem.eql(u8, name, "$sformat")) {
        try self.err(self.file.exprs.mainTok(e), .E0813, "`{s}` is a task and has no value; call it as a statement", .{name});
        return poison;
    }
    // Engine extension (no LRM basis): `$prev(e)` — e at the last ACCEPTED
    // solve, via the same `path_prev` latch §5.6.1.2's reactive lowering
    // already plants on ddt operands (pb__k staged by updateState, advanced
    // only by stateCtl(.commit); before the first commit the latch reads its
    // 0.0 default). Exists so a model can spell SPICE's Meyer capacitance
    // averaging `(C + C_prev)/2` — plain Verilog-A has no accepted-step
    // memory. $prev of a value with no unknown dependence is the value
    // itself: a past constant IS the constant, so param-only uses emit
    // byte-identical code (same rule as `coeffIsConst`).
    if (std.mem.eql(u8, name, "$prev")) {
        const args = ex.args(e);
        if (args.len != 1 or args[0] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
            b.msg("`$prev` takes exactly 1 argument, got {d}", .{args.len});
            try b.emit();
            return poison;
        }
        const v = try self.toReal(try self.lowerExpr(args[0]));
        return .{
            .v = if (self.coeffIsConst(v)) v else try self.emit(.path_prev, &.{v}),
            .ty = .real,
        };
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (sys_args) |a| {
        if (a == .none) continue;
        try vals.append(self.arena, (try self.lowerSysArg(a, takesNetRef(name))).v);
    }
    const v = try self.call(name, vals.items);
    // §9.5 the remaining descriptor functions ($fopen, $ftell, $fseek, $rewind,
    // $feof): ordinary values, but each one moves or creates state the NEXT call
    // observes, so it is sequenced into the I/O phase like the tasks.
    if (isFileFunc(name)) try self.sequenceFileCall(ex.mainTok(e), name, v);
    return .{ .v = v, .ty = sysFuncTy(name) };
}

// ---- §9.21 $table_model -----------------------------------------------------

/// §9.21 Syntax 9-16, rewritten into ONE self-describing call:
///
///     $table_model(ND, NP, NCOL, dep, "<interp/extrap>", snapshot_site, previous_call, in₀…in_{ND-1}, row₀…row_{NP-1})
///
/// — the dimensionality, the sample count, the column count, the dependent
/// COLUMN the selector picked, one interpolation and two extrapolation control characters per
/// dimension, then the lookup point and the flat row-major sample block. The
/// block has been projected onto the columns the lookup reads, so the column
/// count is always `nd + 1` and the dependent is always the last of them.
///
/// Everything §9.21.2 and §9.21.1 decide is decided HERE, and the reason is the
/// same one that puts §9.20's rules in lowering: none of it is a value. The
/// control string is a constant, so a string that is not one §9.21.2 describes
/// is reported rather than approximated (E0815) and §9.21.2's `I` columns are
/// projected out of the block before it is emitted; the data source is a set of
/// ARRAY IDENTIFIERS or a file name, neither of which survives into MIR. What
/// reaches codegen is a call whose every operand is a number, a string or a
/// probe. The schemes themselves (Table 9-30) and the runtime conditions
/// (Table 9-31's `E`, §9.21's conflicting duplicates) belong to the kernel,
/// because both need the lookup point.
///
/// A FILE data source is currently read at compile time. Runtime file capture
/// remains a conformance gap when the file changes before the first call.
/// Array-source calls carry a unique snapshot site; codegen captures their
/// rows at the first executed call, including conditionally reached calls.
fn lowerTableModel(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e);

    // Syntax 9-16 puts `table_inputs` first, then `table_data_source`. The
    // boundary is decidable without counting: an input is "any legal expression
    // that can be assigned to an analog signal", while every data-source
    // argument is an array (a name, or a §3.4.8 pattern) or a string.
    var i: usize = 0;
    while (i < args.len and args[i] != .none and !self.isTableSource(args[i])) i += 1;
    const nd = i;
    if (nd == 0 or i == args.len) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "`$table_model(table_inputs, table_data_source [, table_control_string])` — one lookup expression per dimension, then the data source", .{});
        return poison;
    }

    // The columns, in file order: N independents outermost-first, then the
    // dependents. §9.21.1: "When the data source is a sequence of 1-D arrays the
    // isolines are laid out in conceptually the same way with each array being
    // just as a column in the file format described above."
    var cols: std.ArrayList([]const Mir.Value) = .empty;
    defer cols.deinit(self.arena);
    while (i < args.len and self.isTableArray(args[i])) : (i += 1) {
        var one: std.ArrayList(Mir.Value) = .empty;
        defer one.deinit(self.arena);
        _ = try self.appendVectorArg(&one, args[i]);
        try cols.append(self.arena, try self.arena.dupe(Mir.Value, one.items[1..]));
    }

    // What is left must be the file name (when there were no arrays) and/or the
    // control string. §9.21's `file_name ::= string_literal | string_parameter`,
    // so a constant fold is the whole admissible set.
    var strs: [2][]const u8 = .{ "", "" };
    var ns: usize = 0;
    while (i < args.len) : (i += 1) {
        if (args[i] == .none) continue;
        const c = self.constEval(args[i]) orelse break;
        if (c != .str or ns == 2) break;
        strs[ns] = c.str;
        ns += 1;
    }
    if (i != args.len) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "trailing argument to `$table_model` is neither an array data source nor a constant string", .{});
        return poison;
    }

    var rows: []const Mir.Value = &.{};
    var ncol: usize = 0;
    var np: usize = 0;
    var ctl: []const u8 = "";
    if (cols.items.len != 0) {
        // `table_model_array ::= 1st_dim_array_identifier [, …], output_array_identifier`
        // — one column per dimension plus at least one dependent.
        if (ns > 1) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "an array data source takes at most one control string", .{});
            return poison;
        }
        ctl = strs[0];
        ncol = cols.items.len;
        np = cols.items[0].len;
        if (ncol <= nd) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "{d} lookup input(s) need {d} independent arrays plus an output array, got {d}", .{ nd, nd, ncol });
            return poison;
        }
        for (cols.items) |c| {
            if (c.len != np) {
                try self.err(self.file.exprs.mainTok(e), .E0815, "the arrays of a `$table_model` data source are columns of one table and must be the same length; got {d} and {d}", .{ np, c.len });
                return poison;
            }
        }
        const flat = try self.arena.alloc(Mir.Value, np * ncol);
        for (0..np) |r| for (cols.items, 0..) |c, k| {
            flat[r * ncol + k] = c[r];
        };
        rows = flat;
    } else {
        if (ns == 0) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`$table_model` needs a data source: a file name, or one array per dimension plus an output array", .{});
            return poison;
        }
        ctl = strs[1];
        const nums = (try self.readTableFile(e, strs[0], nd)) orelse return poison;
        ncol = nums.cols;
        np = nums.vals.len / ncol;
        const flat = try self.arena.alloc(Mir.Value, nums.vals.len);
        for (nums.vals, flat) |v, *out| out.* = try self.mir.addFloatConst(self.arena, v);
        rows = flat;
    }

    // §9.21: "The minimum data requirement is to have the product of at least
    // two points per dimension (2ᴺ for N dimensions)."
    if (np < std.math.pow(usize, 2, @min(nd, 30))) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "a {d}-dimensional table needs at least {d} samples, got {d}", .{ nd, std.math.pow(usize, 2, @min(nd, 30)), np });
        return poison;
    }

    const ext = try self.arena.alloc(u8, 3 * nd);
    // `keep[0..nd]` is the source column of each dimension, outermost first;
    // `keep[nd]` is the dependent the selector picked.
    const keep = try self.arena.alloc(usize, nd + 1);
    keep[nd] = (try self.parseTableCtl(e, ctl, nd, ncol, ext, keep[0..nd])) orelse return poison;

    // Project the sample block onto the columns the lookup actually reads.
    // §9.21.2's `I` ("Ignore this input column") and every dependent the
    // selector did NOT pick are dead weight in a device that snapshots its rows,
    // and dropping them here is what keeps the kernel's `dim`-is-`column`
    // indexing — and its sort — true for the general case. After this the block
    // is `nd` independents outermost-first followed by the one dependent.
    const proj = try self.arena.alloc(Mir.Value, np * (nd + 1));
    for (0..np) |r| for (keep, 0..) |c, j| {
        proj[r * (nd + 1) + j] = rows[r * ncol + c];
    };
    rows = proj;
    ncol = nd + 1;
    const dep = nd;

    const site = if (cols.items.len == 0) 0 else blk: {
        if (std.mem.indexOfScalar(Ast.ExprId, self.table_sources.items, e)) |existing| break :blk existing + 1;
        try self.table_sources.append(self.arena, e);
        try self.table_samples.append(self.arena, @intCast(rows.len));
        break :blk self.table_samples.items.len;
    };
    if (site != 0 and self.table_effect_place == null) {
        const place = self.builder.newPlace();
        try self.builder.writeVariable(place, .entry, .f_zero);
        self.table_effect_place = place;
    }
    const previous = if (site == 0) .f_zero else try self.builder.readVariable(self.table_effect_place.?, self.cur);
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.appendSlice(self.arena, &.{
        try self.mir.addIntConst(self.arena, @intCast(nd)),
        try self.mir.addIntConst(self.arena, @intCast(np)),
        try self.mir.addIntConst(self.arena, @intCast(ncol)),
        try self.mir.addIntConst(self.arena, @intCast(dep)),
        try self.mir.addStrConst(self.arena, ext),
        try self.mir.addIntConst(self.arena, @intCast(site)),
        previous,
    });
    for (args[0..nd]) |a| try vals.append(self.arena, try self.toReal(try self.lowerExpr(a)));
    // ponytail: rows are already lowered; append their contiguous values in order.
    try vals.appendSlice(self.arena, rows);
    self.uses_table_model = true;
    const result = try self.call("$table_model", vals.items);
    if (site != 0) try self.builder.writeVariable(self.table_effect_place.?, self.cur, result);
    return .{ .v = result, .ty = .real };
}

/// Is this argument part of `table_data_source` rather than a lookup input?
fn isTableSource(self: *Lower, a: Ast.ExprId) bool {
    if (self.isTableArray(a)) return true;
    const c = self.constEval(a) orelse return false;
    return c == .str;
}

/// One column of an array data source: an array name (§9.21.1 "via array
/// variable names") or a pattern (". Arrays may be specified directly via the
/// concatenation operator"). The same two shapes §4.5.11's coefficient slot
/// takes, so `appendVectorArg` is the reader for both.
fn isTableArray(self: *Lower, a: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    return switch (ex.tag(a)) {
        .assign_pattern, .concat => true,
        .ident => if (self.arrays.get(self.file.str(ex.strOf(a)))) |info| info.dims.len == 1 else false,
        else => false,
    };
}

const TableFile = struct { vals: []const f64, cols: usize };

/// A sample table is text; 16 MiB is ~700k rows of three columns, well past what
/// a device that re-sorts its block per evaluation can afford anyway.
const max_table_bytes: usize = 16 << 20;

/// §9.21.1's text format: "Each sample point is separated by a newline and each
/// column is separated by one or more spaces or tabs. Comments begin with # and
/// continue to the end of that line. They may appear anywhere in the file. Blank
/// lines are ignored. The numbers shall be real or integer."
///
/// Resolved against the `include_dirs` the caller passed, which is where the
/// source file's own directory is: §9.21 says nothing about the search path, and
/// a data file sits beside the model that names it exactly as an `include does.
fn readTableFile(self: *Lower, e: Ast.ExprId, name: []const u8, nd: usize) Oom!?TableFile {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir: std.Io.Dir = .cwd();
    const text = blk: {
        for (self.include_dirs) |base| {
            const full = try std.fs.path.join(self.arena, &.{ base, name });
            const r = dir.readFileAlloc(io, full, self.arena, .limited(max_table_bytes)) catch |e2| {
                if (e2 == error.OutOfMemory) return error.OutOfMemory;
                continue; // try the next dir, exactly as `readInclude` does
            };
            break :blk r;
        }
        const r = dir.readFileAlloc(io, name, self.arena, .limited(max_table_bytes)) catch |e2| {
            if (e2 == error.OutOfMemory) return error.OutOfMemory;
            try self.err(self.file.exprs.mainTok(e), .E0815, "cannot read the `$table_model` data source \"{s}\"", .{name});
            return null;
        };
        break :blk r;
    };

    var vals: std.ArrayList(f64) = .empty;
    var cols: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |tok| {
            const x = std.fmt.parseFloat(f64, tok) catch {
                try self.err(self.file.exprs.mainTok(e), .E0815, "\"{s}\": `{s}` is not a real or integer number", .{ name, tok });
                return null;
            };
            try vals.append(self.arena, x);
            n += 1;
        }
        if (n == 0) continue; // blank line, or a line that was only a comment
        if (cols == 0) cols = n;
        if (n != cols) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "\"{s}\": every sample point is one row of {d} columns; found a row of {d}", .{ name, cols, n });
            return null;
        }
    }
    if (cols <= nd) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "\"{s}\": {d} lookup input(s) need {d} independent columns plus a dependent one, found {d}", .{ name, nd, nd, cols });
        return null;
    }
    return .{ .vals = vals.items, .cols = cols };
}

/// §9.21.2 the control string. Writes `3*nd` control bytes into `ext`
/// (interpolation, low extrapolation, high extrapolation) and the source COLUMN
/// each dimension reads into `cmap`, and returns the dependent COLUMN index — or
/// null when the string is not one §9.21.2 describes.
///
/// Table 9-30's `D`, `1`, `2` and `3` all become the dimension's interpolation
/// byte and are decided in the kernel. `I` never reaches the kernel: it is
/// "Ignore this input column", a statement about the DATA SOURCE and not about a
/// dimension, so it spends a column in `cmap` without spending a dimension and
/// the caller projects that column out of the sample block entirely.
///
/// THE DEPENDENT COLUMN is therefore counted in columns, not in dimensions.
/// Table 9-32 states the arithmetic twice by example — `"I,1CC,1CC;3"` has "at
/// least 6 column[s]" (3 leading + selector 3) and `"3,D,I,1;3"` interpolates
/// "dependent variable 3 (column 7)" (4 leading + 3) — and its first row states
/// the no-sub-string case, "Dimensionality of the data is assumed to be N.
/// Column N+1 is taken as the dependent", with N the number of `table_inputs`.
/// Both are the one rule `leading = nd + (ignored columns)`: a dimension without
/// a sub-string still owns a column.
fn parseTableCtl(self: *Lower, e: Ast.ExprId, ctl: []const u8, nd: usize, ncol: usize, ext: []u8, cmap: []usize) Oom!?usize {
    // "the function defaults to performing linear interpolation and linear
    // extrapolation in both dimensions" (§9.21.5), which Table 9-32's first row
    // states for every dimension: `""` is "default linear interpolation and
    // extrapolation".
    @memset(ext, 'L');
    for (0..nd) |dim| ext[3 * dim] = '1';
    const semi = std.mem.indexOfScalar(u8, ctl, ';');
    const head = if (semi) |s| ctl[0..s] else ctl;

    // `dependent_selector ::= integer`, "a column number ... This number runs 1
    // through M with M being the total number of dependent variables". Table
    // 9-32: with none given, "Column N+1 is taken as the dependent".
    var sel: usize = 1;
    if (semi) |s| {
        const tail = std.mem.trim(u8, ctl[s + 1 ..], " \t");
        if (tail.len != 0) sel = std.fmt.parseInt(usize, tail, 10) catch 0;
    }

    var d: usize = 0;
    var col: usize = 0; // the source column the next sub-string is spent on
    var it = std.mem.splitScalar(u8, head, ',');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t");
        // Table 9-30 `I`, "Ignore this input column". It marks a COLUMN, so it
        // takes no dimension and admits no extrapolation characters — there is
        // no end of an ignored column to extrapolate off.
        if (s.len != 0 and s[0] == 'I') {
            if (s.len != 1) {
                try self.err(self.file.exprs.mainTok(e), .E0815, "`{s}`: Table 9-30's `I` ignores a column and takes no extrapolation characters", .{s});
                return null;
            }
            col += 1;
            continue;
        }
        if (d >= nd) {
            // One sub-string per independent variable, "with the first
            // sub-string applying to the outermost dimension and so on".
            if (s.len == 0) continue;
            try self.err(self.file.exprs.mainTok(e), .E0815, "the control string has more interpolation sub-strings than the {d} lookup input(s)", .{nd});
            return null;
        }
        cmap[d] = col;
        col += 1;
        defer d += 1;
        var j: usize = 0;
        if (s.len != 0 and std.mem.indexOfScalar(u8, "D123", s[0]) != null) {
            ext[3 * d] = s[0];
            j = 1;
        }
        const xs = s[j..];
        if (xs.len > 2) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`{s}`: a control sub-string carries at most 2 extrapolation characters", .{s});
            return null;
        }
        for (xs) |c| if (std.mem.indexOfScalar(u8, "CLE", c) == null) {
            try self.err(self.file.exprs.mainTok(e), .E0815, "`{c}` is not a Table 9-30 interpolation character or a Table 9-31 extrapolation character", .{c});
            return null;
        };
        // "When one extrapolation method character is given, the specified
        // extrapolation method will be used for both ends. When two ... the
        // first character specifies the extrapolation method used for the end
        // with the lower coordinate value."
        if (xs.len == 1) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[0];
        } else if (xs.len == 2) {
            ext[3 * d + 1] = xs[0];
            ext[3 * d + 2] = xs[1];
        }
    }
    // Fewer sub-strings than dimensions: the rest keep the `1LL` default and
    // take the columns that follow, so `leading` is still one column per
    // dimension plus one per ignored column.
    while (d < nd) : (d += 1) {
        cmap[d] = col;
        col += 1;
    }

    if (sel == 0 or col + sel - 1 >= ncol) {
        try self.err(self.file.exprs.mainTok(e), .E0815, "dependent selector {d} names no dependent column: the data source has {d} column(s) and {d} leading column(s)", .{ sel, ncol, col });
        return null;
    }
    return col + sel - 1;
}

/// The §4.7 function a `$limit` second argument names, or null when the argument
/// is not one — Syntax 9-12's other two forms put a string there, or nothing.
///
/// The ordinary scopes are consulted FIRST, so a variable or parameter that
/// happens to share a function's name still wins (§2.8), exactly as
/// `natureAbstol` arranges for a nature identifier in a tolerance slot.
// ponytail: lookup only; add an error set if resolution ever does fallible work.
fn limitUserFunc(self: *Lower, a: Ast.ExprId) ?*const Ast.FuncDecl {
    const ex = &self.file.exprs;
    if (ex.tag(a) != .ident) return null;
    const name = self.file.str(ex.strOf(a));
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    const m = self.module orelse return null;
    for (m.functions) |*fd| {
        if (std.mem.eql(u8, self.file.str(fd.name), name)) return fd;
    }
    return null;
}

/// §9.17.3 the third form: `$limit(access, user_function, args…)` returns
/// `user_function(vnew, vold, args…)` — the access function's value at this
/// iterate, the value the slot returned at the previous one, then the call's
/// own tail. The function is an ordinary §4.7 body, so it is INLINED like every
/// other analog function; the only thing §9.17.3 adds is where `vold` comes
/// from (`LimitSlot`) and where the return goes (the same slot).
///
/// THE RETURNED VALUE CARRIES THE ACCESS FUNCTION'S DERIVATIVE, not the
/// limiter's. That is the point of limiting and not a shortcut: SPICE evaluates
/// the device at the limited bias and stamps `I(vlim) + g(vlim)·(v − vlim)`, so
/// the residual is LINEAR in the true unknown beyond the limit point and the
/// Jacobian entry never vanishes. Differentiating the limiter itself instead
/// gives dv_lim/dv = 0 inside the clamped region — a device that contributes no
/// conductance, which is a singular row for a floating internal node. `$limit$uf`
/// renders that as `vlim.val()` shifted onto the probe (codegen `zLimitUf`), the
/// same relation the STRING form gets for free from the host writing its clamp
/// back into `x` before `eval` runs (cg_limit.zig's header).
fn lowerLimitUser(self: *Lower, e: Ast.ExprId, fd: *const Ast.FuncDecl, args: []const Ast.ExprId) Oom!TypedValue {
    // §9.17.3 the first argument is an ACCESS FUNCTION, never a net.
    const vnew = try self.toReal(try self.lowerSysArg(args[0], false));
    const slot = try self.limitSlotOf(args[0]) orelse {
        // No access function to key state on (`$limit(x, f)` with an ordinary
        // expression). §4.5.15 lets a simulator decline any limiting request;
        // declining is the one answer that cannot invent state.
        return .{ .v = try self.call("$limit", &.{vnew}), .ty = .real };
    };
    // The SEED, not the slot's running value: §9.17.3 says the second argument
    // is "the value that was returned by the $limit() function on the PREVIOUS
    // iteration", so every site on one access function reads the same number
    // however many of them ran this time. Reading the running value instead
    // chains them — a reader followed by a writer would limit twice per
    // evaluation and halve the damping.
    const old = self.limit_slots.items[slot].seed;
    const res = try self.toReal(try self.inlineUserFuncPre(fd, &.{ vnew, old }, args[2..], e));
    // The site's return is the slot's NEXT state. Written at the site, so the
    // last site to run this evaluation is the one the next iterate reads —
    // which is what makes the read-then-write accessor idiom work.
    try self.builder.writeVariable(self.limit_slots.items[slot].place, self.cur, res);
    return .{ .v = try self.call("$limit$uf", &.{ vnew, res }), .ty = .real };
}

/// The `limit_slots` index for this access function, minting nothing: every
/// slot was created by `scanCallSites` before the body was lowered. Null
/// when the argument is not an access function at all.
fn limitSlotOf(self: *Lower, a: Ast.ExprId) Oom!?usize {
    const t = try self.limitSlotKey(a) orelse return null;
    for (self.limit_slots.items, 0..) |s, i| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return i;
    }
    return null;
}

/// The branch an access function names. `null` for anything that is not one.
///
/// Asked twice of the same expression — once by `scanCallSites`, once by
/// the site — and that costs nothing: `branchOf`'s diagnostics are deduped by
/// `(code, span)` in the bag, so a malformed access function is still reported
/// exactly once.
fn limitSlotKey(self: *Lower, a: Ast.ExprId) Oom!?Target {
    if (a == .none or self.file.exprs.tag(a) != .branch_access) return null;
    return self.branchOf(a);
}

fn addLimitSlot(self: *Lower, a: Ast.ExprId) Oom!void {
    const t = try self.limitSlotKey(a) orelse return;
    for (self.limit_slots.items) |s| {
        if (s.access == t.access and s.hi == t.hi and s.lo == t.lo and s.neg == t.neg and s.br == t.br)
            return;
    }
    const k: i64 = @intCast(self.limit_slots.items.len);
    // A `call`, so it is opaque to `analysis.foldConst` — the previous iterate
    // is not a constant, however constant the rest of the expression is.
    const seed = try self.call("$limit$old", &.{try self.mir.addIntConst(self.arena, k)});
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, seed);
    try self.limit_slots.append(self.arena, .{
        .label = try std.fmt.allocPrint(self.arena, "{s}({s},{s})", .{
            if (t.access == .potential) "V" else "I", self.nodeName(t.hi), self.nodeName(t.lo),
        }),
        .access = t.access,
        .hi = t.hi,
        .lo = t.lo,
        .neg = t.neg,
        .br = t.br,
        .place = place,
        .seed = seed,
    });
}

/// §9.20's outcome for one `$analog_node_alias()` / `$analog_port_alias()`
/// call: the six validity rules are errors, and what survives them is the
/// clause's own return value.
const AliasResult = enum {
    /// One of §9.20's six "shall be an error" sentences (E0812). The call has
    /// no value; lowering poisons it.
    refused,
    /// "the hierarchical_reference_string points to a valid continuous node":
    /// the analog_net_reference now names that node's unknown, and the call
    /// returns 1.
    bound,
    /// The string resolves to nothing this design contains. §9.20: the call
    /// returns 0 and "the node referenced by the analog_net_reference shall be
    /// treated as a normal continuous node declared in the module".
    unresolved,
};

/// §9.20 one resolved `hierarchical_reference_string`: the unknown it names,
/// and whether the name was a node of the flat design itself (`direct`) rather
/// than a child port flattening bound to one.
const AliasHit = struct { idx: u16, direct: bool };

/// §9.20's validity list for `$analog_node_alias()` / `$analog_port_alias()`,
/// then the alias itself.
///
/// All six rules are checked HERE, in lowering, because every one of them is a
/// property of the call and none of them is a property of a value: the block the
/// call sits in, the guard above it, the SHAPE of the first argument (a node
/// declaration, not a probe and not a bit select), the constancy of the second,
/// and the relation between two calls. codegen sees a `call` with two operands
/// and cannot recover any of that.
///
/// One code for the list. The six sentences are one rule with one reason — an
/// alias makes its node "refer to the same circuit matrix position" as the
/// hierarchical reference, so it is a topology edit and topology is fixed before
/// a solve — and each message quotes the sentence it enforces.
///
/// The edit is HERE too, and for the same reason: a node's identity in this
/// compiler is `node_voltages`, the name → unknown map every probe goes
/// through, so "refer to the same circuit matrix position" is one `put`. Doing
/// it at the call site is also what gives §9.20's last-writer rule — "if a
/// particular node is involved in multiple calls ..., then the last evaluated
/// call shall take precedence" — for free: the calls are lowered in source
/// order and each overwrites the last.
fn checkAliasCall(self: *Lower, e: Ast.ExprId, name: []const u8, args: []const Ast.ExprId) Oom!AliasResult {
    const ex = &self.file.exprs;
    // 1. "It shall be an error for the $analog_node_alias() and
    // $analog_port_alias() system functions to be used outside the analog
    // initial block." The next sentence gives the reason: both "shall be
    // re-evaluated each sweep point of a dc sweep", i.e. between solves.
    if (!self.in_analog_initial) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used outside an analog initial block", .{name});
        return .refused;
    }
    // 2. "shall not be used inside conditional ( if , case , or ?: ) statements
    // unless the conditional expression controlling the statement consists of
    // terms which can not change during the course of a simulation."
    //
    // That carve-out is EXACTLY `static_cond_depth`: A.8.3's
    // `analysis_or_constant_expression` is the same "cannot change during the
    // simulation" set, so a parameter or `analysis()` guard is admitted and
    // `$abstime` is not. A constant-folded `if` never raises either counter and
    // so never reaches here at all.
    //
    // The `analog initial` block is itself ONE guarded body — `lowerModule`
    // wraps it in the `initial_step` flag rather than splitting the CFG — so the
    // depth inside an EMPTY initial block is already 1/0. That guard is not a
    // §9.20 conditional, it is the context the clause requires, so it is
    // discounted (saturating, since rule 1 above is what guarantees it is there).
    if ((self.cond_depth -| 1) != self.static_cond_depth) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` is used inside conditional statement whose condition can change during the simulation", .{name});
        return .refused;
    }
    // 3/4/5. The analog_net_reference. "The analog_net_reference shall be either
    // a scalar or vector continuous node declared in the module containing the
    // system function call."
    const ref = if (args.len > 0) args[0] else Ast.ExprId.none;
    if (ref == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0812, "`{s}` needs an analog_net_reference and a hierarchical_reference_string", .{name});
        return .refused;
    }
    // The analog_net_reference's own unknown, for the alias below.
    var local: u16 = ground;
    switch (ex.tag(ref)) {
        .ident => {
            const rname = self.file.str(ex.strOf(ref));
            // The net's own unknown: §9.20's last-writer rule means `rname` may
            // already BE an alias, and every rule below is about the
            // declaration, not about where the previous call pointed it.
            const idx = self.alias_home.get(rname) orelse self.node_voltages.get(rname);
            if (idx == null or idx.? == ground or self.vars.contains(rname)) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
                return .refused;
            }
            // 4. "It shall be an error for the analog_net_reference to be a port
            // or to be involved in port connections." A port is already bound to
            // whatever the instantiating netlist connected it to, and the alias
            // would bind the same matrix position a second time.
            if (idx.? < self.num_ports) {
                try self.err(self.file.exprs.mainTok(e), .E0812, "§9.20 does not allow the analog_net_reference to be a port: `{s}`", .{rname});
                return .refused;
            }
            local = idx.?;
        },
        // 5. "If the analog_net_reference is a vector node, it shall reference
        // the full vector node, it shall be an error for it to be a bit select
        // or part select of a vector node." The asymmetry is deliberate: the
        // scalar ELEMENT is what the hierarchical_reference_string may name.
        .index, .range => {
            try self.err(self.file.exprs.mainTok(e), .E0812, "a vector analog_net_reference must be the whole vector, not a bit select or part select", .{});
            return .refused;
        },
        else => {
            try self.err(self.file.exprs.mainTok(e), .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
            return .refused;
        },
    }
    // 6. "The hierarchical_reference_string shall be a CONSTANT string value
    // (string literal or string parameter) containing a hierarchical reference
    // to a continuous node." Two spellings and nothing else — a string VARIABLE
    // is read during a solve, which is what the analog-initial rule already
    // rules out for the call itself. `constEval` admits exactly those two.
    const target = blk: {
        if (args.len > 1) if (self.constEval(args[1])) |c| switch (c) {
            .str => |s| break :blk s,
            else => {},
        };
        try self.err(self.file.exprs.mainTok(e), .E0812, "the hierarchical_reference_string of `{s}` is not a constant string (a string literal or a string parameter)", .{name});
        return .refused;
    };
    // "It shall be an error for the hierarchical_reference_string to reference a
    // node that is used as an analog_net_reference in ANOTHER
    // $analog_node_alias or $analog_port_alias() system function call." The same
    // LEFT argument twice is legal — the clause spends a last-writer rule on it
    // — so only target-against-other-reference is compared.
    //
    // Only a dotted-free string can name one: §6.7 says "the first name in a
    // path name can also be the top of a hierarchy which starts at the level
    // where the path is being used", so a bare name resolves locally, while
    // `$root.top.a` names something this module does not declare.
    const ref_name = self.file.str(ex.strOf(args[0]));
    if (std.mem.indexOfScalar(u8, target, '.') == null and !std.mem.eql(u8, target, ref_name)) {
        if (self.alias_home.contains(target)) {
            try self.err(self.file.exprs.mainTok(e), .E0812, "`\"{s}\"` is already the analog_net_reference of another $analog_node_alias/$analog_port_alias call", .{target});
            return .refused;
        }
    }
    // First call for this net records its DECLARED unknown; a later one must
    // not overwrite it with the alias the earlier call installed.
    if (!self.alias_home.contains(ref_name)) try self.alias_home.put(self.arena, ref_name, local);
    return self.bindAlias(name, ref_name, local, target);
}

/// §9.20's topology edit, and the validity list that decides whether it happens.
///
/// "The return value for both system functions shall be one (1) if the
/// hierarchical_reference_string points to a valid continuous node and zero (0)
/// otherwise. If the hierarchical_reference_string references a valid continuous
/// node, then the analog_net_reference will be aliased to that hierarchical node
/// and shall refer to the same circuit matrix position."
///
/// The clause's own three validity rules, in its order, plus resolution:
///
///   "shall refer to a scalar continuous node or a scalar element of a
///    continuous vector node" — a vector BASE name is not a node here at all
///    (lowering scalarises `[3:0] b` into `b[3]`…`b[0]`), so it resolves to
///    nothing and takes the zero answer without an arm of its own;
///   "the discipline of the analog_net_reference and the resolved hierarchical
///    node reference shall be compatible (see 3.11)" — `disciplineConflict`,
///    the same §3.11.1 rule list `checkNetCompat` applies to a branch;
///   "for the $analog_port_alias() system function, the resolved hierarchical
///    node reference shall be a port".
///
/// Everything that survives is one `node_voltages` write. The aliased net keeps
/// its own `node_order` slot, which no probe can reach any more: an unknown with
/// no equation, which is what a net the clause has just merged away IS. That is
/// the same shape a declared-and-unused net already has here, and pruning it
/// would renumber `U` — an ABI the host reads.
///
/// ponytail: the resolution is COMPILE TIME, so §9.20's "shall be re-evaluated
/// each sweep point of a dc sweep" is satisfied vacuously — the answer cannot
/// change between sweep points, because the only inputs are the string and the
/// elaborated design. The one input that CAN move is a string PARAMETER the host
/// overrides on the model card: that is frozen at its declared default here,
/// exactly as §3.6.3.2's nodeset is. Making it move needs a device whose
/// topology is a function of its model card, which is not what `U` is; the
/// upgrade path is to refuse a parameter-valued string whose default and
/// override could resolve differently, once a host exists that can tell us.
fn bindAlias(self: *Lower, fname: []const u8, ref_name: []const u8, local: u16, target: []const u8) Oom!AliasResult {
    const hit = self.resolveAliasNode(target) orelse return .unresolved;
    // §1.3.1.1 ground is not an unknown, but it IS a valid continuous node and
    // the clause's own example aliases to it ("node n1 will be aliased to
    // top.gnd"). Probing an aliased-to-ground net then yields the literal 0,
    // which is what the reference node is.
    if (hit.idx != ground) {
        if (self.disciplineConflict(
            self.node_disciplines.items[local],
            self.node_disciplines.items[hit.idx],
        ) != null) return .unresolved;
        if (self.disciplines.get(self.node_disciplines.items[hit.idx])) |info| {
            if (info.is_discrete) return .unresolved;
        }
    }
    if (std.mem.eql(u8, fname, "$analog_port_alias")) {
        // "the resolved hierarchical node reference shall be a port". A port of
        // the ELABORATED device, which is the only port whose flow §5.4.3 can
        // read: `I(<p>)` is a row pinning the module's KCL sum at `p`.
        //
        // ponytail: so a child instance's port — the clause's own
        // `$analog_port_alias(n2, "top.r1.p")`, whose promise is that `I(<n2>)`
        // "shall measure the flow through the port of the INSTANCE referred to"
        // — takes the zero answer instead. Flattening binds that port to the
        // parent net it was connected to (`hier_names`), and the flow through
        // one instance's terminal is no longer a quantity the flat design has:
        // every instance on that net shares it. Answering 1 and measuring the
        // NET's flow would be a different number wearing the right name, and
        // §9.20 gives the honest 0 a meaning ("the user is encouraged to check
        // the return value"). The upgrade path is a per-instance terminal flow
        // unknown, which is elaboration's to mint, not this function's.
        if (!hit.direct or hit.idx == ground or hit.idx >= self.num_ports) return .unresolved;
    }
    // The alias itself: from here the analog_net_reference names the resolved
    // node's unknown, so every later probe of it lands on that matrix position.
    try self.node_voltages.put(self.arena, ref_name, hit.idx);
    return .bound;
}

/// §6.7 resolve a `hierarchical_reference_string` against the ELABORATED design.
/// `direct` says the name was a node of the flat design itself rather than a
/// child port that flattening bound to one — see `bindAlias`'s port rule.
///
/// Flattening renames a child's net to `path.name` with `Elaborate.sep`, which
/// IS a period, so the string §9.20 hands us and the name the flat design
/// carries are the same bytes and this is a map lookup — the same identity
/// `flatName` rides for a `.hier_ident` written in source. What differs is only
/// that the path arrives as a string, so the two prefix rules are applied to
/// bytes instead of to interned parts:
///
///   §6.2.1 `$root.` — "used to unambiguously refer to a top-level instance or
///   to an instance path starting from the root of the instantiation tree";
///   §6.7 the first name of a path "can also be the top of a hierarchy", with
///   "the ambiguity ... resolved by giving priority to the local scope" — hence
///   the unstripped lookup FIRST, and the device's own module name stripped
///   only after it fails.
fn resolveAliasNode(self: *Lower, path: []const u8) ?AliasHit {
    if (self.lookupFlatNode(path)) |h| return h;
    var p = path;
    if (std.mem.startsWith(u8, p, "$root.")) p = p["$root.".len..];
    if (self.module) |m| {
        const mn = self.file.str(m.name);
        if (p.len > mn.len + 1 and p[mn.len] == Elaborate.sep and std.mem.startsWith(u8, p, mn))
            p = p[mn.len + 1 ..];
    }
    if (p.len == path.len) return null; // nothing stripped; already looked up
    return self.lookupFlatNode(p);
}

fn lookupFlatNode(self: *Lower, p: []const u8) ?AliasHit {
    if (self.node_voltages.get(p)) |i| return .{ .idx = i, .direct = true };
    // A child port bound to a parent net is the same signal as that net, and
    // `Design.names` holds exactly those aliases (`flatName`'s one exception).
    if (self.hier_names.get(p)) |flat| {
        if (self.node_voltages.get(flat)) |i| return .{ .idx = i, .direct = false };
    }
    return null;
}

/// §9.16 the dynamic simulation probe function, Syntax 9-11:
///
///     $simprobe ( inst_name , param_name [, expression] )
///
/// "$simprobe allows a module to probe the value of a parameter of another
/// module instance", and the clause's one sentence with a value in it is the
/// resolution rule: "If either the inst_name or param_name cannot be resolved,
/// and the optional expression is not supplied, then an error shall be
/// generated. If the optional expression is supplied, its value will be returned
/// in lieu of raising an error."
///
/// So the answer is decided by whether `inst_name.param_name` resolves, and in a
/// flattened design that is a NAME LOOKUP: the flat name of a child's parameter
/// IS its hierarchical path (`Elaborate.sep`), the same identity §6.7 rides on.
/// Nothing is dynamic about it, which is the point — the device has no runtime
/// hierarchy to walk.
///
/// ponytail: the ceiling is a COMPUTED name. §9.16's arguments are strings, and a
/// string that is not a literal here cannot be resolved at compile time; it takes
/// the fallback, which is precisely what §9.16 says an unresolvable probe does,
/// and with no fallback it is the error the clause asks for. A host with a real
/// instance table would resolve more names than this does — that is the piece
/// Ruling E deliberately gave up, and it is recorded here rather than hidden.
/// §9.16 "the parent of the current instance": the caller's own instance path
/// with its last segment dropped, separator included, "" at the top. Joined to
/// an `inst_name` it gives the flat name of a SIBLING.
fn callerParentPath(self: *const Lower) []const u8 {
    if (self.cur_unit >= self.unit_paths.len) return "";
    const p = self.unit_paths[self.cur_unit].path;
    if (p.len == 0) return p;
    // `path` ends with the separator, so the caller's own segment is the text
    // between the previous separator and the last one.
    const cut = std.mem.lastIndexOfScalar(u8, p[0 .. p.len - 1], Elaborate.sep) orelse return "";
    return p[0 .. cut + 1];
}

fn lowerSimprobe(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0809);
        b.msg("`$simprobe` takes an instance name and a parameter name", .{});
        try b.emit();
        return poison;
    }
    const inst = self.constStrArg(args[0]);
    const param = self.constStrArg(args[1]);
    if (inst != null and param != null) {
        // §9.16: "the simulator will look for an instance called inst_name IN
        // THE PARENT OF THE CURRENT INSTANCE i.e. a sibling of the instance
        // containing the $simprobe() expression." The name is therefore
        // RELATIVE, and the flat key is the caller's parent path joined to it —
        // not the bare `inst_name`, which only worked for a caller that
        // happened to sit at the root, and which also resolved a path FROM the
        // root, the one reading the sibling rule excludes.
        const path = try std.mem.concat(self.arena, u8, &.{
            self.callerParentPath(), inst.?, &[_]u8{Elaborate.sep}, param.?,
        });
        if (self.param_index.get(path)) |pi|
            return .{ .v = self.param_values.items[pi], .ty = astTy(self.params.items[pi].ty) };
        // §9.16's own first sentence: "$simprobe() queries the simulator for AN
        // OUTPUT VARIABLE named param_name in a sibling instance", and the
        // clause's example probes `id` of a mosfet — an operating-point
        // quantity, not a parameter. "The intended use of this function is to
        // allow dynamic monitoring of instance quantities", which a probe that
        // can only read the netlist's own numbers does not do. A flattened
        // child's variable is an ordinary variable under its path name, so the
        // read is the ordinary one.
        //
        // The sibling's block was lowered before this one (elaboration appends
        // instances in tree order), so the value read here is the one that
        // instance computed for this evaluation.
        if (self.vars.get(path)) |slot|
            return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    }
    // Unresolved. §9.16's own two outcomes, in the clause's order.
    if (args.len >= 3 and args[2] != .none) return self.lowerExpr(args[2]);
    var b = self.errWith(self.file.exprs.mainTok(e), .E0817);
    b.msg("`$simprobe(\"{s}\", \"{s}\")` names no parameter of the elaborated design", .{
        inst orelse "<expression>", param orelse "<expression>",
    });
    b.note("§9.16: with no third argument, an unresolvable probe \"shall generate an error\"", .{});
    b.help("supply the fallback expression §9.16 defines for this case: `$simprobe(inst, param, <value>)`", .{});
    try b.emit();
    return poison;
}

/// A string literal argument, for the ch9 functions whose behaviour depends on
/// one. Null when the argument is any other expression.
fn constStrArg(self: *Lower, e: Ast.ExprId) ?[]const u8 {
    if (e == .none) return null;
    const c = self.constEval(e) orelse return null;
    return switch (c) {
        .str => |s| s,
        else => null,
    };
}

/// The ch9 names whose argument IS a net or port reference — §9.19
/// `$port_connected`, §9.20 `$analog_node_alias`/`$analog_port_alias`. The
/// §9.22/§9.23 driver access family takes net references too, but
/// `isConnectModuleOnlySysFunc` refuses those calls before an argument is ever
/// lowered, so listing them here would gate a path they cannot reach.
fn takesNetRef(name: []const u8) bool {
    const fns = [_][]const u8{ "$port_connected", "$analog_node_alias", "$analog_port_alias" };
    for (fns) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

/// Direct output literals retain their lexical bytes (§9.4.2), unlike a
/// literal converted to string storage (§3.3). Reuse the lexer decoder only
/// when the AST node still points to a genuine quoted source token; synthesized
/// constants and identifier operands keep their existing conversion semantics.
fn outputLiteral(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    if (e == .none or self.file.exprs.tag(e) != .str_literal) return null;
    const span = self.tokenSpan(self.file.exprs.mainTok(e));
    const raw = self.src[span.start..span.end];
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"' or
        std.mem.indexOfScalar(u8, raw, '\\') == null) return null;
    return try Lexer.stringContents(self.arena, raw);
}

fn lowerFormatArg(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (try self.outputLiteral(e)) |bytes|
        return .{ .v = try self.mir.addStrConst(self.arena, bytes), .ty = .string };
    return self.lowerExpr(e);
}

fn lowerTaskArg(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    if (isDisplayTask(name) or isFileOutTask(name)) return self.lowerFormatArg(e);
    return self.lowerSysArg(e, takesNetRef(name));
}

/// A system call argument. For the `takesNetRef` names a bare net name lowers
/// to its node_order index, which is what codegen needs. For every OTHER task
/// the index is meaningless — `$strobe("%g", p)` printed p's INDEX — so the
/// path is gated by the caller (`net_ok`) and a net name elsewhere falls
/// through to `lowerExpr`, where §4.4's "a net is not a value" E0315 says to
/// probe it.
fn lowerSysArg(self: *Lower, e: Ast.ExprId, net_ok: bool) Oom!TypedValue {
    const ex = &self.file.exprs;
    if (net_ok and ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        const is_value = self.vars.contains(name) or self.param_index.contains(name) or
            self.consts.contains(name);
        if (!is_value) {
            if (self.node_voltages.get(name)) |idx|
                return .{ .v = try self.mir.addIntConst(self.arena, idx), .ty = .integer };
        }
    }
    return self.lowerExpr(e);
}

/// §9.15 Table 9-27 — the simulation parameters THIS engine knows, and their
/// values. Null is the clause's "param_name is not known", which decides both
/// halves of the rule: with a fallback the fallback is returned, without one it
/// is an error (E0811, raised in `lowerSysCall`).
///
/// The table is here rather than in codegen — where the values are rendered —
/// because §9.15 states the error as a property of the CALL, and the two answers
/// have to come from one list or a name could be diagnosed as unknown and then
/// answered anyway. codegen calls this.
///
/// The list is short on purpose. Table 9-27 is prefaced "simulators shall accept
/// the strings in Table 9-27 ... IF THEY SUPPORT THE PARAMETER", so a row VerA
/// cannot answer honestly is better left unknown than answered with an invented
/// number: "gdev" is a property of a solver run this compiler does not host,
/// and "simulatorVersion" is required to increase monotonically across
/// releases, which a constant cannot do. The rows that ARE a property of the
/// run and that the device can answer from its own state are in
/// `simparamIsRuntime` instead — a constant is the wrong answer for those, not
/// a missing one.
pub fn simparamValue(self: *const Lower, name: []const u8) ?f64 {
    const eq = std.mem.eql;
    // The two rows that come out of the SOURCE. Unknown when no `timescale was
    // given, which is exactly what "as specified in `timescale" means.
    if (eq(u8, name, "timeUnit")) return if (self.timescale) |t| t.unit else null;
    if (eq(u8, name, "timePrecision")) return if (self.timescale) |t| t.precision else null;
    if (eq(u8, name, "gmin")) return 1e-12;
    // Table 9-27 gives `tnom` in DEGREES CELSIUS ("Default value of temperature
    // at which model parameters were extracted"), so the conforming default is
    // 27, not the 300.15 it once answered — the right temperature in the wrong
    // unit, which a model forming `$vt($simparam("tnom") + 273.15)` then read as
    // 300 K too hot.
    //
    // 27 is the DECLARED default only. `tnom` is also in `simparamHostField`,
    // so codegen renders the READ from the host's Model field and uses this
    // number for exactly one thing: the field initializer, i.e. what `Model{}`
    // means to a host that never writes the field (`paramDefault`).
    if (eq(u8, name, "tnom")) return 27.0;
    // Three unit-valued homotopy/geometry factors: a device compiled here is
    // never being stepped or shrunk, so 1.0 is the true answer, not a stand-in.
    if (eq(u8, name, "scale") or eq(u8, name, "shrink") or eq(u8, name, "sourceScaleFactor")) return 1.0;
    return null;
}

/// §9.15 runtime simulation parameters. The host advances this counter once
/// per evaluated Newton iteration via `advanceIteration`; accepted-step
/// updates do not change it. Unknown vendor names use the standard fallback.
pub fn simparamIsRuntime(name: []const u8) bool {
    return std.mem.eql(u8, name, "iteration");
}

/// §9.15 the simulation parameters whose value is the HOST's, published into a
/// reserved `Model` field the host writes before `derive()`. Returns the field
/// name, or null for a name that is a compile-time constant here.
///
///   tnom — Table 9-27, degrees Celsius. SPICE's `.options tnom` (ngspice
///          `CKTnomTemp`, default 27), which is the temperature a model card
///          that gives no `TNOM`/`TREF` of its own was extracted at. A
///          Verilog-A module cannot read it any other way: `$temperature` is
///          the OPERATING temperature and a `parameter` default is the
///          module's own text. Folding it to 27 made every `.options tnom`
///          in a deck a silent no-op, because a compact model derives its
///          whole parameter set from the nominal temperature.
///
/// The `__` suffix is VerA's namespace and cannot collide: `naming.sanitize`
/// escapes a trailing `_` and a `__` run (`Z5f`), so no Verilog-A identifier
/// reaches a field name of this shape. Same rule as `<p>__given`.
pub fn simparamHostField(name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, name, "tnom")) "nom_temp__" else null;
}

/// ch9 return types. Everything not listed is real (§9.14/§9.15 dominate).
///
/// `pub` for one consumer: analysis.zig's "sysFuncTy and callTy agree" test.
/// The two type the same call from opposite sides of the MIR and their comments
/// have said MUST AGREE since both were written; the test is what turns that
/// into something a build can fail on.
pub fn sysFuncTy(name: []const u8) Ty {
    // Data: fixed system-call names -> MIR type, one lookup per lowered call.
    // The keys and enum values are static; no instance storage or allocation.
    // Calls are independent, but this cold lookup needs no lane kernel.
    const types = std.StaticStringMap(Ty).initComptime(.{
        .{ "$param_given", .integer },
        .{ "$port_connected", .integer },
        .{ "$test$plusargs", .integer },
        .{ "$value$plusargs", .integer },
        .{ "$rtoi", .integer },
        .{ "$clog2", .integer },
        .{ "$realtobits", .integer },
        .{ "$analog_node_alias", .integer },
        .{ "$analog_port_alias", .integer },
        .{ "$sscanf", .integer },
        .{ "$sscanf$int", .integer },
        .{ "$display$width", .integer },
        .{ "$idx$int", .integer },
        .{ "$fopen", .integer },
        .{ "$fgets", .integer },
        .{ "$fscanf", .integer },
        .{ "$fscanf$int", .integer },
        .{ "$ftell", .integer },
        .{ "$fseek", .integer },
        .{ "$rewind", .integer },
        .{ "$ferror", .integer },
        .{ "$feof", .integer },
        .{ "$simparam$str", .string },
        .{ "$sformat", .string },
        .{ "$sscanf$str", .string },
        .{ "$idx$str", .string },
        .{ "$fgets$str", .string },
        .{ "$fscanf$str", .string },
        .{ "$ferror$str", .string },
    });
    return types.get(name) orelse .real;
}

// ---------------------------------------------------------------------------
// Class 9 — user-defined analog functions (LRM §4.7)
// ---------------------------------------------------------------------------

/// §4.7.3: "An analog user-defined function ... shall not call itself directly
/// or indirectly, i.e., recursive functions are not permitted."
///
/// The sentence constrains the FUNCTION, so the check cannot be left to
/// `inlineUserFuncPre`'s inline stack: that one only fires when the analog block
/// actually reaches the call, which makes an illegal declaration legal as long
/// as nobody calls it — and it is precisely the declarations that cannot be
/// compiled, since §4.7.2 inlining has no call ABI to fall back on.
///
/// The call graph is tiny (functions are per-module and hand-written), so this
/// is a reachability walk per function rather than an SCC pass; both report the
/// same set, and this one names every function that sits on a cycle.
fn checkFuncRecursion(self: *Lower, fns: []const Ast.FuncDecl) Oom!void {
    if (fns.len == 0) return;
    const edges = try self.arena.alloc(std.ArrayList(u32), fns.len);
    for (fns, edges) |*fd, *out| {
        out.* = .empty;
        try self.scanCallSites(fd.body, false, fns, out);
    }

    const seen = try self.arena.alloc(bool, fns.len);
    var stack: std.ArrayList(u32) = .empty;
    for (fns, 0..) |*fd, i| {
        @memset(seen, false);
        stack.clearRetainingCapacity();
        try stack.append(self.arena, @intCast(i));
        while (stack.pop()) |j| {
            for (edges[j].items) |k| {
                if (k == i) { // back at the start ⇒ `fd` calls itself, however far around
                    try self.err(fd.main_tok, .E0510, "`{s}`", .{self.file.str(fd.name)});
                    stack.clearRetainingCapacity();
                    break;
                }
                if (seen[k]) continue;
                seen[k] = true;
                try stack.append(self.arena, k);
            }
        }
    }
}

/// With `limits`, §9.17.3 mints one state slot per ACCESS FUNCTION reached by a
/// user-function `$limit`, in source order, seeded in the entry block.
/// `LimitSlot`'s header says why the key is the access function, not the call site.
/// Otherwise collect the §4.7 functions the statement calls, as indices into `fns`.
/// A name that is not a declared function is not an edge — `lowerUserCall`
/// reports it (E0512) when the call is reached.
fn scanCallSites(
    self: *Lower,
    id: Ast.StmtId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (id == .none) return;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try self.scanCallSites(s, limits, fns, out),
        .assign => |a| {
            if (!limits) try self.scanCallSitesExpr(a.target, limits, fns, out);
            try self.scanCallSitesExpr(a.value, limits, fns, out);
        },
        .contribute => |c| {
            if (!limits) try self.scanCallSitesExpr(c.lhs, limits, fns, out);
            try self.scanCallSitesExpr(c.rhs, limits, fns, out);
        },
        .indirect => |c| {
            if (!limits) try self.scanCallSitesExpr(c.lhs, limits, fns, out);
            if (!limits) try self.scanCallSitesExpr(c.probe, limits, fns, out);
            try self.scanCallSitesExpr(c.eqn, limits, fns, out);
        },
        .if_stmt => |s| {
            try self.scanCallSitesExpr(s.cond, limits, fns, out);
            try self.scanCallSites(s.then_s, limits, fns, out);
            try self.scanCallSites(s.else_s, limits, fns, out);
        },
        .case_stmt => |s| {
            try self.scanCallSitesExpr(s.scrutinee, limits, fns, out);
            for (s.arms) |arm| {
                if (!limits) for (arm.labels) |l| try self.scanCallSitesExpr(l, limits, fns, out);
                try self.scanCallSites(arm.body, limits, fns, out);
            }
        },
        .for_stmt => |s| {
            if (!limits) try self.scanCallSites(s.init, limits, fns, out);
            try self.scanCallSitesExpr(s.cond, limits, fns, out);
            if (!limits) try self.scanCallSites(s.step, limits, fns, out);
            try self.scanCallSites(s.body, limits, fns, out);
        },
        .while_stmt => |s| {
            try self.scanCallSitesExpr(s.cond, limits, fns, out);
            try self.scanCallSites(s.body, limits, fns, out);
        },
        .repeat_stmt => |s| {
            if (!limits) try self.scanCallSitesExpr(s.count, limits, fns, out);
            try self.scanCallSites(s.body, limits, fns, out);
        },
        .event_control => |s| try self.scanCallSites(s.body, limits, fns, out),
        .sys_task => |s| for (s.args) |a| try self.scanCallSitesExpr(a, limits, fns, out),
        .jump => |j| try self.scanCallSitesExpr(j.value, limits, fns, out),
        else => {},
    }
}

fn scanCallSitesExpr(
    self: *Lower,
    e: Ast.ExprId,
    comptime limits: bool,
    fns: if (limits) void else []const Ast.FuncDecl,
    out: if (limits) void else *std.ArrayList(u32),
) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (limits) {
        if (tag == .sys_call and std.mem.eql(u8, self.file.str(ex.strOf(e)), "$limit")) {
            const args = if (ex.extraOf(e) < ex.pool.items.len) ex.args(e) else &[_]Ast.ExprId{};
            if (args.len >= 2) {
                if (self.limitUserFunc(args[1]) != null) try self.addLimitSlot(args[0]);
            }
        }
    } else if (tag == .call) {
        // StrIds are interned, so identity IS name equality (`natureOf` relies
        // on the same thing).
        for (fns, 0..) |*fd, k| if (fd.name == ex.strOf(e)) {
            try out.append(self.arena, @intCast(k));
            break;
        };
    }
    switch (tag) {
        // Every tag whose `extra` is an ExprId list; the rest park a literal, an
        // opcode or a StrId list there, which `args` must not be handed.
        .call, .builtin_call, .sys_call, .filter_call, .noise_call, .concat, .assign_pattern, .event_function => {
            for (ex.args(e)) |a| try self.scanCallSitesExpr(a, limits, fns, out);
        },
        .ternary => try self.scanCallSitesExpr(ex.ternaryElse(e), limits, fns, out),
        else => {},
    }
    // `lhs`/`rhs` are `.none` on every tag that does not use them.
    try self.scanCallSitesExpr(ex.lhs(e), limits, fns, out);
    try self.scanCallSitesExpr(ex.rhs(e), limits, fns, out);
}

fn lowerUserCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const m = self.module orelse return poison;
    for (m.functions) |*fd| {
        if (!std.mem.eql(u8, self.file.str(fd.name), name)) continue;
        return self.inlineUserFuncPre(fd, &.{}, ex.args(e), e);
    }
    // vpi_* and every other unresolved name lands here.
    try self.unknownCall(e, name);
    return poison;
}

/// LRM §4.7.3/§4.7.2 — analog functions are INLINED (§4.7.1 forbids
/// recursion, and there is no call ABI in the generated device).
///
/// §4.7.1 isolation: the body sees only its own arguments and locals, never
/// module variables — implemented by swapping in a fresh scope.
/// §4.7.2.3/§4.7.2.4: `output`/`inout` arguments are written back to the
/// caller's lvalue after the body runs.
///
/// Leading formals can bind to values the CALLER already has rather than to
/// source expressions. §9.17.3's `$limit` supplies these leading values: the
/// simulator supplies `vnew` and `vold` itself and the source only writes the
/// tail. `pre` fills `fd.args[0..pre.len]`, `arg_exprs` the rest.
pub fn inlineUserFuncPre(
    self: *Lower,
    fd: *const Ast.FuncDecl,
    pre: []const Mir.Value,
    arg_exprs: []const Ast.ExprId,
    site: Ast.ExprId,
) Oom!TypedValue {
    const name = self.file.str(fd.name);
    for (self.inlining.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            try self.err(self.file.exprs.mainTok(site), .E0510, "`{s}`", .{name});
            return poison;
        }
    }
    if (pre.len + arg_exprs.len != fd.args.len) {
        try self.err(self.file.exprs.mainTok(site), .E0511, "`{s}()` takes {d}, got {d}", .{
            name, fd.args.len, pre.len + arg_exprs.len,
        });
        return poison;
    }

    // Actuals are evaluated in the CALLER's scope, before it is swapped out.
    // An ARRAY formal (§4.7.2.3) takes one Value per element — the formal is
    // scalarized inside the function exactly as a §3.2 array is anywhere else,
    // so the pass is element-wise in both directions.
    var actuals: std.ArrayList([]const Mir.Value) = .empty;
    defer actuals.deinit(self.arena);
    for (fd.args, 0..) |formal, fi| {
        const ty = astTy(formal.ty);
        // §9.17.3's simulator-supplied leading formals: already a value, and
        // already checked `input` by the caller, so neither the array nor the
        // output arm below can apply to one.
        if (fi < pre.len) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
                .real => try self.toReal(.{ .v = pre[fi], .ty = .real }),
                .integer => try self.toInt(.{ .v = pre[fi], .ty = .real }),
                .string => pre[fi],
            }}));
            continue;
        }
        const actual = arg_exprs[fi - pre.len];
        if (formal.dims.len != 0) {
            // §4.7.2.3 formal bounds fold in the caller's scope: they may name
            // a module parameter.
            const dims = try self.dimsBounds(formal.dims, formal.main_tok, self.file.str(formal.name)) orelse return poison;
            const n = shapeCells(dims);
            const vals = try self.arena.alloc(Mir.Value, n);
            // §4.7.2.3: "All output arguments ... are initialized, zero (0) if
            // numeric, which in turn means that the argument passed to it is
            // reset to zero." An `inout` is NOT (§4.7.2.4 copies in).
            if (formal.direction == .output) {
                @memset(vals, zeroOf(ty));
            } else if (!try self.funcArrayIn(actual, ty, vals)) {
                try self.err(self.file.exprs.mainTok(actual), .E0511, "`{s}()` argument `{s}` needs {d} elements", .{
                    name, self.file.str(formal.name), n,
                });
                return poison;
            }
            try actuals.append(self.arena, vals);
            continue;
        }
        if (formal.direction == .output) {
            try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{zeroOf(ty)}));
            continue;
        }
        const tv = try self.lowerExpr(actual);
        try actuals.append(self.arena, try self.arena.dupe(Mir.Value, &.{switch (ty) {
            .real => try self.toReal(tv),
            .integer => try self.toInt(tv),
            .string => tv.v,
        }}));
    }

    // ---- enter the function scope (§4.7.1) ----
    const saved_vars = self.vars;
    const saved_arrays = self.arrays;
    const saved_ret = self.ret;
    const saved_restrict = self.restrict;
    // MASKED, not merely marked: the body is inlined into the caller's CFG, so
    // without a fresh stack a `break` in a function whose own loops are all
    // closed bound the loop the CALL SITE sits in and silently exited it — a
    // caller-scope capture the same §4.7.1 isolation that swaps `vars` forbids.
    // With the stack empty, `lowerJump` reports the §5.11 "only be used in a
    // loop" E0404 exactly as it does for a bare module-level `break`, and a
    // loop INSIDE the body still pushes and binds normally.
    const saved_loops = self.loops;
    const saved_func_params = self.func_params;
    const log_mark = self.scope_log.items.len;
    self.vars = .empty;
    self.arrays = .empty;
    self.loops = .empty;
    self.restrict = "an analog function";
    try self.inlining.append(self.arena, name);

    // §4.7.2 local parameters fold to constants; they never reach the Model.
    // The DECL LIST is installed as `func_params` so `lookupName` masks a
    // module parameter of the same name for the body's duration (§6.8) —
    // swapped per call like `vars`, so a callee never sees its caller's
    // locals (§4.7.1 isolation).
    self.func_params = fd.params;
    for (fd.params) |*p| {
        if (self.constEval(p.default)) |c|
            try self.consts.put(self.arena, self.file.str(p.name), c);
    }

    const ret_ty = astTy(fd.ret_ty);
    const ret_slot = try self.declareVar(name, ret_ty); // §4.7.1 return variable
    try self.builder.writeVariable(ret_slot.place, self.cur, zeroOf(ret_ty));

    var arg_slots: std.ArrayList([]const VarSlot) = .empty;
    defer arg_slots.deinit(self.arena);
    for (fd.args, actuals.items) |formal, vals| {
        const fname = self.file.str(formal.name);
        const ty = astTy(formal.ty);
        if (formal.dims.len != 0) {
            // The formal's own §3.2 declaration, inside the function scope: the
            // shape comes from the FORMAL and the values from the actual, which
            // is what makes `arrayadd(x, '{y,z})` (§4.7.3) legal — the two
            // actuals have different shapes and the same size.
            const dims = try self.dimsBounds(formal.dims, formal.main_tok, fname) orelse continue;
            try self.declareArray(fname, .{ .dims = dims, .ty = ty });
            const slots = try self.arena.alloc(VarSlot, vals.len);
            var sub: [max_stack_dims]i64 = undefined;
            const idx = try self.subscriptBuf(&sub, dims.len);
            for (vals, slots, 0..) |v, *slot, k| {
                shapeSubscripts(dims, k, idx);
                slot.* = try self.declareVar(try self.elemName(fname, idx), ty);
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
            try arg_slots.append(self.arena, slots);
            continue;
        }
        const slot = try self.declareVar(fname, ty);
        try self.builder.writeVariable(slot.place, self.cur, vals[0]);
        try arg_slots.append(self.arena, try self.arena.dupe(VarSlot, &.{slot}));
    }
    // §6.8 an analog function is one of the six scopes; its locals are a list
    // like a module's or a block's.
    try self.checkOneItemPerScope(fd.vars);
    for (fd.vars) |*v| try self.declareVarDecl(v, .local);

    const exit = try self.mir.addBlock(self.arena);
    self.ret = .{ .slot = ret_slot, .exit = exit };
    try self.lowerStmt(fd.body);
    try self.gotoBlock(exit);
    try self.builder.sealBlock(exit);
    self.cur = exit;

    const result: TypedValue = .{
        .v = try self.builder.readVariable(ret_slot.place, self.cur),
        .ty = ret_ty,
    };
    // §4.7.2.3/§4.7.2.4 read the writeback values while the scope is still up.
    var writeback: std.ArrayList([]const Mir.Value) = .empty;
    defer writeback.deinit(self.arena);
    for (fd.args, arg_slots.items) |formal, slots| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        const vals = try self.arena.alloc(Mir.Value, slots.len);
        for (slots, vals) |slot, *v| v.* = try self.builder.readVariable(slot.place, self.cur);
        try writeback.append(self.arena, vals);
    }

    // ---- leave the function scope ----
    _ = self.inlining.pop();
    self.scope_log.shrinkRetainingCapacity(log_mark);
    self.vars.deinit(self.arena);
    self.arrays.deinit(self.arena);
    self.vars = saved_vars;
    self.arrays = saved_arrays;
    self.ret = saved_ret;
    self.restrict = saved_restrict;
    self.func_params = saved_func_params;
    self.loops.deinit(self.arena);
    self.loops = saved_loops;

    var w: usize = 0;
    for (fd.args, 0..) |formal, fi| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        defer w += 1;
        // A `pre` formal has no source expression to write back into. §9.17.3
        // makes every formal of a `$limit` limiter `input` (E0814), so this is
        // unreachable there; the guard is what keeps it unreachable.
        if (fi < pre.len) continue;
        const actual = arg_exprs[fi - pre.len];
        const vals = writeback.items[w];
        if (formal.dims.len != 0) {
            // §4.7.2.3: "the last value assigned to the output argument is then
            // assigned to the corresponding analog variable reference that was
            // passed into the function" — element by element, in declaration
            // order, into the caller's own storage.
            try self.funcArrayOut(actual, vals);
            continue;
        }
        const slot = try self.resolveLvalue(actual) orelse continue;
        try self.builder.writeVariable(slot.place, self.cur, vals[0]);
    }
    return result;
}

/// §4.7.2.3: "the argument passed into the function must be an analog variable
/// or an array assignment pattern of analog variables of equivalent size."
/// Copy IN — one Value per element of the formal. False when the actual has the
/// wrong size or is not one of those two shapes.
///
/// The pattern arm lowers each element as an EXPRESSION and not as an lvalue:
/// copy-in has no reason to require storage, and `funcArrayOut` is where the
/// clause's write-back needs one. `'{y, z}` satisfies both.
fn funcArrayIn(self: *Lower, actual: Ast.ExprId, ty: Ty, out: []Mir.Value) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return false;
            if (shapeCells(info.dims) != out.len) return false;
            var sub: [max_stack_dims]i64 = undefined;
            const idx = try self.subscriptBuf(&sub, info.dims.len);
            for (out, 0..) |*v, k| {
                shapeSubscripts(info.dims, k, idx);
                const el = (try self.arrayElemValue(aname, idx)) orelse return false;
                v.* = if (ty == .real) try self.toReal(el) else el.v;
            }
            return true;
        },
        .assign_pattern, .concat => {
            const elems = ex.args(actual);
            if (elems.len != out.len) return false;
            for (elems, out) |e, *v| {
                const tv = try self.lowerExpr(e);
                v.* = if (ty == .real) try self.toReal(tv) else tv.v;
            }
            return true;
        },
        else => return false,
    }
}

/// The write-back half of the same sentence. Each element of the actual is an
/// ordinary lvalue, so a pattern element that is not writable collects the usual
/// E0313/E0316 from `resolveLvalue` — which is the right verdict: §4.7.2.3 says
/// "analog variables", and a literal there has nowhere to receive the result.
fn funcArrayOut(self: *Lower, actual: Ast.ExprId, vals: []const Mir.Value) Oom!void {
    const ex = &self.file.exprs;
    switch (ex.tag(actual)) {
        .ident => {
            const aname = self.file.str(ex.strOf(actual));
            const info = self.arrays.get(aname) orelse return;
            var key_buf: [elem_key_len]u8 = undefined;
            var sub: [max_stack_dims]i64 = undefined;
            const idx = try self.subscriptBuf(&sub, info.dims.len);
            for (vals, 0..) |v, k| {
                shapeSubscripts(info.dims, k, idx);
                const slot = self.vars.get(try self.elemKey(&key_buf, aname, idx)) orelse continue;
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
        },
        .assign_pattern, .concat => {
            for (ex.args(actual), vals) |e, v| {
                const slot = try self.resolveLvalue(e) orelse continue;
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Class 9 — constant evaluation (LRM §4.2 constant_expression, §6.6.1)
// ---------------------------------------------------------------------------

/// Fold an elaboration-time constant: literals, genvars (§3.5) and parameters
/// (§3.4 — a parameter IS a constant expression for array bounds and
/// generate bounds, §6.6.1). Returns null when the expression is not constant.
pub fn constEval(self: *const Lower, e: Ast.ExprId) ?Const {
    return self.foldExpr(e, true);
}

/// With `params = false`, a procedural `if (p > 0)` must stay
/// a runtime branch — `p` is overridable by the model card, so folding it to
/// its default would silently compile the wrong arm (§3.4 vs §6.6.2).
fn foldExpr(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal => return .{ .int = ex.intValue(e) },
        .real_literal => return .{ .real = ex.realValue(e) },
        .str_literal => return .{ .str = self.file.str(ex.strOf(e)) },
        .pos_inf => return .{ .real = std.math.inf(f64) },
        .neg_inf => return .{ .real = -std.math.inf(f64) },
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) return null; // a runtime variable
            // A function-local parameter is NOT overridable by a model card
            // (§4.7.2 — it never reaches the Model), so `foldExpr(..., false)`'s refusal
            // to look through a parameter does not apply to a shadowing local.
            if (!params and self.param_index.contains(name) and !self.funcParamShadows(name)) return null;
            return self.consts.get(name);
        },
        .unary => {
            const a = self.foldExpr(ex.lhs(e), params) orelse return null;
            return switch (ex.unOp(e)) {
                .plus => a,
                .minus => switch (a) {
                    .int => |i| .{ .int = -i },
                    .real => |r| .{ .real = -r },
                    .str => null,
                },
                .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
                .bit_not => Const{ .int = ~a.asInt() },
                else => null,
            };
        },
        .binary => return self.foldBinary(e, params),
        .ternary => {
            const c = self.foldExpr(ex.lhs(e), params) orelse return null;
            return self.foldExpr(if (c.isTrue()) ex.rhs(e) else ex.ternaryElse(e), params);
        },
        // §4.3 math in a constant expression — the common subset only.
        .builtin_call => {
            const name = self.file.str(ex.strOf(e));
            const args = ex.args(e);
            if (args.len == 1) {
                const a = self.foldExpr(args[0], params) orelse return null;
                if (std.mem.eql(u8, name, "abs")) return switch (a) {
                    .int => |i| .{ .int = @intCast(@abs(i)) },
                    .real => |r| .{ .real = @abs(r) },
                    .str => null,
                };
                const x = a.asReal();
                const r: f64 = if (std.mem.eql(u8, name, "sqrt"))
                    @sqrt(x)
                else if (std.mem.eql(u8, name, "exp"))
                    @exp(x)
                else if (std.mem.eql(u8, name, "ln"))
                    @log(x)
                else if (std.mem.eql(u8, name, "log"))
                    @log10(x)
                else if (std.mem.eql(u8, name, "floor"))
                    @floor(x)
                else if (std.mem.eql(u8, name, "ceil"))
                    @ceil(x)
                else
                    return null;
                return .{ .real = r };
            }
            if (args.len == 2) {
                const a = self.foldExpr(args[0], params) orelse return null;
                const b = self.foldExpr(args[1], params) orelse return null;
                const int = a == .int and b == .int;
                if (std.mem.eql(u8, name, "min"))
                    return if (int) Const{ .int = @min(a.asInt(), b.asInt()) } else Const{ .real = @min(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "max"))
                    return if (int) Const{ .int = @max(a.asInt(), b.asInt()) } else Const{ .real = @max(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "pow"))
                    return .{ .real = std.math.pow(f64, a.asReal(), b.asReal()) };
                return null;
            }
            return null;
        },
        else => return null,
    }
}

fn foldBinary(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    const ex = &self.file.exprs;
    if (self.mixedShiftComparison(e)) return null;
    const a = self.foldExpr(ex.lhs(e), params) orelse return null;
    const b = self.foldExpr(ex.rhs(e), params) orelse return null;
    const op = ex.binOp(e);
    // §4.2.1 integer arithmetic only when BOTH operands are integer.
    const int = a == .int and b == .int;
    const x = a.asReal();
    const y = b.asReal();
    // §3.2's 32-bit 2's complement result — see `wrap32`. `%` needs none: a
    // remainder is never wider than its operands.
    return switch (op) {
        .add => if (int) Const{ .int = wrap32(a.asInt() +% b.asInt()) } else Const{ .real = x + y },
        .sub => if (int) Const{ .int = wrap32(a.asInt() -% b.asInt()) } else Const{ .real = x - y },
        .mul => if (int) Const{ .int = wrap32(a.asInt() *% b.asInt()) } else Const{ .real = x * y },
        // A literal can occupy the full i64 carrier before assignment. Its
        // minInt/-1 quotient needs 65 bits before the current MIR's wrap32.
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @as(i32, @truncate(@divTrunc(@as(i65, a.asInt()), @as(i65, b.asInt())))) })
        else
            Const{ .real = x / y },
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @intCast(@rem(@as(i65, a.asInt()), @as(i65, b.asInt()))) })
        else
            Const{ .real = @rem(x, y) },
        .pow => .{ .real = std.math.pow(f64, x, y) },
        .eq => .{ .int = @intFromBool(if (int) a.int == b.int else x == y) },
        .neq => .{ .int = @intFromBool(if (int) a.int != b.int else x != y) },
        .lt => .{ .int = @intFromBool(if (int) a.int < b.int else x < y) },
        .le => .{ .int = @intFromBool(if (int) a.int <= b.int else x <= y) },
        .gt => .{ .int = @intFromBool(if (int) a.int > b.int else x > y) },
        .ge => .{ .int = @intFromBool(if (int) a.int >= b.int else x >= y) },
        .logical_and => .{ .int = @intFromBool(a.isTrue() and b.isTrue()) },
        .logical_or => .{ .int = @intFromBool(a.isTrue() or b.isTrue()) },
        .bit_and => .{ .int = a.asInt() & b.asInt() },
        .bit_or => .{ .int = a.asInt() | b.asInt() },
        .bit_xor => .{ .int = a.asInt() ^ b.asInt() },
        .bit_xnor => .{ .int = ~(a.asInt() ^ b.asInt()) },
        .shl, .shr => blk: {
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            // §4.2.11 `<<` zero-fills from the right; §3.2's width is what makes
            // `1 << 31` negative and `1 << 32` zero rather than 2^31 and 2^32.
            if (op == .shl) break :blk Const{ .int = wrap32(a.asInt() << @as(u6, @intCast(sh))) };
            // §4.2.11 `>>` fills the vacated positions with zeroes, over
            // §3.2.1's 32-bit `integer` — same rule codegen's `shrLogical`
            // emits, and the fold has to agree with it or a constant and a
            // computed operand give different answers.
            if (sh == 0) break :blk a;
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        else => null,
    };
}

/// Only provenance present in the AST/declarations is evidence of signedness.
/// This is a refusal guard, not general expression context/type propagation.
fn integerSourceSigned(self: *const Lower, e: Ast.ExprId, depth: u32) ?bool {
    if (e == .none or depth > 32) return null;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => ex.intLiteral(e).signed,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |v| break :blk if (v.ty == .integer) true else null;
            if (self.arrays.get(name)) |a| break :blk if (a.ty == .integer) true else null;
            for (self.func_params) |p| {
                if (!self.file.strings.eql(p.name, name)) continue;
                break :blk if (p.ty == .integer) true else if (p.ty == .unspecified) self.integerSourceSigned(p.default, depth + 1) else null;
            }
            const pi = self.param_index.get(name) orelse break :blk null;
            const p = self.params.items[pi];
            if (p.ty != .integer) break :blk null;
            if (p.integer32) break :blk true;
            if (!p.is_local) break :blk null; // host overrides carry no signedness
            const module = self.module orelse break :blk null;
            for (module.params) |decl| {
                if (std.mem.eql(u8, self.file.str(decl.name), p.name))
                    break :blk self.integerSourceSigned(decl.default, depth + 1);
            }
            break :blk null;
        },
        .unary => switch (ex.unOp(e)) {
            .plus, .minus, .bit_not => self.integerSourceSigned(ex.lhs(e), depth + 1),
            else => null,
        },
        .binary => switch (ex.binOp(e)) {
            .shl, .shr => self.integerSourceSigned(ex.lhs(e), depth + 1),
            else => null,
        },
        .index => self.integerSourceSigned(ex.lhs(e), depth + 1),
        else => null,
    };
}

fn isShiftOperand(self: *const Lower, e: Ast.ExprId, depth: u32) bool {
    if (e == .none or depth > 32) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .binary => ex.binOp(e) == .shl or ex.binOp(e) == .shr,
        .unary => self.isShiftOperand(ex.lhs(e), depth + 1),
        else => false,
    };
}

fn mixedShiftComparison(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    switch (ex.binOp(e)) {
        .eq, .neq, .lt, .le, .gt, .ge => {},
        else => return false,
    }
    const a = ex.lhs(e);
    const b = ex.rhs(e);
    if (!self.isShiftOperand(a, 0) and !self.isShiftOperand(b, 0)) return false;
    const sa = self.integerSourceSigned(a, 0) orelse return false;
    const sb = self.integerSourceSigned(b, 0) orelse return false;
    return sa != sb;
}

// ponytail: §4.7.2 function-local `parameter` declarations fold into `consts` and
//     are not restored on exit. DURING the body the shadowing is right —
//     `func_params` masks `param_index`, so the local wins there and the
//     module parameter wins again after the call (`lookupName` asks
//     `param_index` before `consts`). What remains is the CONSTANT-fold view
//     AFTER the call: `consts` still carries the local's value under that
//     name, so a later array bound or generate bound folding the shadowed name
//     reads the function's constant, not the module default. Give `consts` the
//     same save/restore treatment as `vars` if a fixture ever does that.

// ---------------------------------------------------------------------------
// Self-checks run on std.testing.allocator
// through an arena, so a leaked byte fails the test.
// ---------------------------------------------------------------------------

const Parser = @import("frontend").Parser;

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    bag: diag.Bag,
    low: Lower,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .bag = undefined,
            .low = undefined,
        };
        const arena = out.arena_state.allocator();
        out.bag = diag.Bag.init(arena);
        const text = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        out.file.builtin_modules = Preprocessor.spice_module_count;
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
    }

    /// The code of the i'th diagnostic. Assertions key on the CODE, never on
    /// prose: the message no longer carries the LRM citation (`Info.lrm` does)
    /// and the title is not part of the message at all.
    fn code(self: *const Harness, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: *const Harness, i: usize) []const u8 {
        return self.bag.at(i).message;
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

test "lower: §2.7 a string literal is a base-256 numeral, §3.3 justified right" {
    // §2.7's own sentence, at the natural width: most significant character
    // first, and a plain space is a character like any other.
    try std.testing.expectEqual(@as(i64, 10), strToInt("\n", 64));
    try std.testing.expectEqual(@as(i64, 32), strToInt(" ", 64));
    try std.testing.expectEqual(@as(i64, 16706), strToInt("AB", 64));
    // §3.3 into a 32-bit `integer` (§3.2): "hello" is 40 bits and loses its
    // leading 'h' on the LEFT, "A" is zero filled on the left, and Table 3-3's
    // `""` -> 8'b0 is the caller's (`strLitBytes`), so `{"H", ""}` is "H\x00".
    try std.testing.expectEqual(@as(i64, 1701604463), strToInt("hello", 32));
    try std.testing.expectEqual(@as(i64, 65), strToInt("A", 32));
    try std.testing.expectEqual(@as(i64, 18432), strToInt("H\x00", 32));
    try std.testing.expectEqual(@as(i64, 0), strToInt("", 32));
}

test "lower: §3.2 a multidimensional array is scalarized row-major" {
    // The ORDER is the load-bearing part: §3.3's own initializer
    // `string paths[0:2][0:1] = '{ '{"dir1","fileA"}, … }` is rows of columns,
    // so cell k of the flat walk must be `[k / cols][k % cols]`. Transposing it
    // reads one cell where another was written, and every value in that example
    // is plausible in both places — which is why the fixture checks all six.
    const dims = [_]Bounds{ .{ .lo = 0, .hi = 2 }, .{ .lo = 0, .hi = 1 } };
    try std.testing.expectEqual(@as(usize, 6), shapeCells(&dims));
    var idx: [2]i64 = undefined;
    const want = [_][2]i64{
        .{ 0, 0 }, .{ 0, 1 },
        .{ 1, 0 }, .{ 1, 1 },
        .{ 2, 0 }, .{ 2, 1 },
    };
    for (want, 0..) |w, k| {
        shapeSubscripts(&dims, k, &idx);
        try std.testing.expectEqualSlices(i64, &w, &idx);
    }
    // A non-zero `lo` offsets the subscript and not the walk (§3.2.2 counts
    // elements): `[1:3]` puts the first cell at 1.
    const off = [_]Bounds{.{ .lo = 1, .hi = 3 }};
    var one: [1]i64 = undefined;
    shapeSubscripts(&off, 0, &one);
    try std.testing.expectEqual(@as(i64, 1), one[0]);
    shapeSubscripts(&off, 2, &one);
    try std.testing.expectEqual(@as(i64, 3), one[0]);
}

test "lower: §2.9/§2.9.2 attribute values — constant, and in domain" {
    // Every row is one attr_spec in a slot Syntax 2-7 really has, so the only
    // thing under test is the VALUE. The accepting rows matter as much as the
    // refusing ones: §2.9 leaves an unlisted name's meaning to the tool, so a
    // domain check that fired on `tool_hint` would refuse conforming source.
    const cases = [_]struct { attr: []const u8, code: ?diag.Code }{
        // §2.9 `attr_spec ::= attr_name [ = constant_expression ]`.
        .{ .attr = "q = 1", .code = null },
        .{ .attr = "q", .code = null }, // "the default value is 1"
        .{ .attr = "q = gain", .code = null }, // A.8.4 a parameter IS constant
        .{ .attr = "q = z", .code = .E0357 }, // a variable is not
        .{ .attr = "q = 1 + z", .code = .E0357 },
        // §2.9.2's four names and nothing else.
        .{ .attr = "desc = \"a resistance\"", .code = null },
        .{ .attr = "desc = 7", .code = .E0358 },
        .{ .attr = "units = \"S\"", .code = null },
        .{ .attr = "units = 1.0", .code = .E0358 },
        .{ .attr = "op = \"yes\"", .code = null },
        .{ .attr = "op = \"no\"", .code = null },
        .{ .attr = "op = \"maybe\"", .code = .E0358 },
        .{ .attr = "op = 1", .code = .E0358 },
        .{ .attr = "multiplicity = \"multiply\"", .code = null },
        .{ .attr = "multiplicity = \"divide\"", .code = null },
        .{ .attr = "multiplicity = \"none\"", .code = null },
        .{ .attr = "multiplicity = \"sideways\"", .code = .E0358 },
        // Not a §2.9.2 name: no stated domain, so no check.
        .{ .attr = "tool_hint = \"anything\"", .code = null },
        .{ .attr = "full_case = 1", .code = null },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  real z;
            \\  (* {s} *) parameter real gain = 1.0;
            \\  analog begin
            \\    z = 2.0;
            \\    I(p, n) <+ gain * V(p, n);
            \\  end
            \\endmodule
        , .{c.attr});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        };
        var seen: ?diag.Code = null;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0357 or h.code(i) == .E0358) seen = h.code(i);
        }
        std.testing.expectEqual(c.code, seen) catch |e| {
            std.debug.print("attribute: (* {s} *)\n", .{c.attr});
            return e;
        };
    }
}

test "lower: contribution splits into resistive and reactive parts" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module rc(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf);
        \\  parameter real c = 1p;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 / r;
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ g * V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    // §6.5 ports first, in header order — this is the host's terminal order.
    try std.testing.expectEqual(@as(usize, 2), h.low.num_ports);
    try std.testing.expectEqualStrings("p", h.low.node_order.items[0]);
    try std.testing.expectEqualStrings("n", h.low.node_order.items[1]);

    // §3.4.2 the value range MUST survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 2), h.low.params.items.len);
    try std.testing.expectEqualStrings("r", h.low.params.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), h.low.params.items[0].ranges.len);
    try std.testing.expectEqual(Ast.ValueRange.Kind.from, h.low.params.items[0].ranges[0].kind);

    // §5.6.1.3 both `<+` statements accumulate into ONE target…
    try std.testing.expectEqual(@as(usize, 1), h.low.contributions.items.len);
    const c = h.low.contributions.items[0];
    try std.testing.expectEqual(Access.flow, c.access);
    try std.testing.expectEqual(@as(u16, 0), c.hi);
    try std.testing.expectEqual(@as(u16, 1), c.lo);
    // …and §5.6.1.2 splits them: the guarded g*V is resistive, ddt(c*V) is not.
    const resist = h.mir.resolveAlias(c.resist_val);
    const react = h.mir.resolveAlias(c.react_val);
    try std.testing.expect(resist != .f_zero); // a phi over the §5.8 guard
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(resist).inst_result));
    // The reactive part is `c * V(p,n)` — the charge, NOT its derivative.
    const react_inst = h.mir.valueDef(react).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fadd, h.mir.instOp(react_inst));
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(
        h.mir.valueDef(h.mir.instData(react_inst).binary.rhs).inst_result,
    ));
}

test "lower: §5.6.7 indirect contribution is a nullor entry, one per statement" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog begin
        \\    V(out) : V(pin, nin) == 2.0 * V(out);
        \\    V(out) : V(pin) == 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    // §5.6.7.1 several indirect contributions are legal, and each is its own
    // equation — NEVER accumulated the way §5.6.1.3 accumulates `<+`.
    try std.testing.expectEqual(@as(usize, 2), h.low.contributions.items.len);
    for (h.low.contributions.items) |c| {
        try std.testing.expectEqual(Kind.indirect, c.kind);
        try std.testing.expectEqual(Access.potential, c.access);
        try std.testing.expectEqual(@as(u16, 0), c.hi); // out
        try std.testing.expectEqual(ground, c.lo);
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }
    // Row ORIENTATION: probe − equation, so the top-level op is `fsub` whose
    // LHS is the probe slice. Reversed, the residual is negated and an
    // asymmetric equation converges to the wrong point.
    const row = h.mir.resolveAlias(h.low.contributions.items[0].resist_val);
    const inst = h.mir.valueDef(row).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(inst));
    const lhs = h.mir.resolveAlias(h.mir.instData(inst).binary.lhs);
    // lhs is V(pin,nin) = x[pin] − x[nin]; rhs is the 2.0*V(out) product.
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(h.mir.valueDef(lhs).inst_result));
    const rhs = h.mir.resolveAlias(h.mir.instData(inst).binary.rhs);
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(h.mir.valueDef(rhs).inst_result));
}

test "lower: §5.6.7.2 an indirectly assigned branch refuses <+, in either order" {
    // The two orders are mirror images, and each has its own code.
    const cases = [_]struct { want: diag.Code, src: []const u8 }{
        .{ .want = .E0409, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    V(p, n) : V(p) == 0.0;
        \\    I(p, n) <+ 1e-6;
        \\  end
        \\endmodule
        },
        // …and the reverse order, on the reversed net pair (a "parallel
        // branch" in §5.6.7.2's words).
        .{ .want = .E0415, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(n, p) <+ 1e-6;
        \\    V(p, n) : V(p) == 0.0;
        \\  end
        \\endmodule
        },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
    }
}

test "lower: §5.6.7 indirect is banned under a runtime condition, allowed under a constant one" {
    var bad: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (V(i) > 0.0) V(o) : V(i) == 0.0;
        \\endmodule
    , &bad);
    defer bad.deinit();
    try std.testing.expectError(error.DiagnosticsReported, bad.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0412, bad.code(0));

    // "…unless the conditional expression is a constant expression": a folded
    // condition lowers its arm straight into the current block, so it never
    // raises `cond_depth`. (A §3.4 `parameter` is deliberately NOT foldable
    // here — one artifact serves every model card — and `foldExpr(..., false)` treats a
    // §3.4.5 `localparam` the same way, so this uses a literal.)
    var ok: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (1) V(o) : V(i) == 0.0;
        \\endmodule
    , &ok);
    defer ok.deinit();
    try ok.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 1), ok.low.contributions.items.len);
    try std.testing.expectEqual(Kind.indirect, ok.low.contributions.items[0].kind);
}

test "lower: a ddt that is not a linear factor is a diagnostic, not wrong physics" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ sin(ddt(V(p,n)));
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0503, h.code(0));
}

test "lower: genvar loops unroll, procedural loops do not" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module chain(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar i;
        \\  analog begin
        \\    for (i = 0; i < 3; i = i + 1)
        \\      I(a,b) <+ i * V(a,b);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    // §6.6.1: three unrolled bodies accumulate into one target, and the loop
    // left no CFG behind (entry only).
    try std.testing.expectEqual(@as(usize, 1), h.low.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.mir.blockCount());
}

test "lower: §5.4.3 port access — what is rejected, and what the unknown is" {
    const cases = [_]struct { src: []const u8, want: diag.Code, msg: []const u8 = "" }{
        // "The expression V(<a>) is invalid for ports and nets, where V is a
        // potential access function."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(p) <+ V(<p>);
        \\endmodule
        , .want = .E0507, .msg = "potential access function" },
        // "The port access function shall not be used on the left side of a
        // contribution operator <+."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(<p>) <+ 1.0;
        \\endmodule
        , .want = .E0407 },
        // §4.4.2 "the expression list is a single port of the module": an
        // internal net has no outside, so I(<n>) would be an identical zero.
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  electrical n;
        \\  analog I(p, n) <+ I(<n>);
        \\endmodule
        , .want = .E0508, .msg = "I(<n>)" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
        if (c.msg.len != 0)
            try std.testing.expect(std.mem.indexOf(u8, h.msg(0), c.msg) != null);
    }
}

test "lower: §5.4.3 repeated I(<p>) is one unknown, appended after the ports" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, c);
        \\  inout a, c; electrical a, c;
        \\  analog I(a, c) <+ I(<a>) + I(<c>) + I(<a>);
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    try std.testing.expectEqual(@as(usize, 2), h.low.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u16, 0), h.low.port_probes.items[0].port);
    try std.testing.expectEqual(@as(u16, 1), h.low.port_probes.items[1].port);
    for (h.low.port_probes.items) |pp| {
        try std.testing.expect(pp.u >= h.low.num_ports);
        // The KIND tag, which is what codegen's `isFlowUnknown` now reads. This
        // used to assert the `"flow(<"` prefix, i.e. the spelling — and §2.8.1
        // makes that predicate false for a net someone declared `\flow(<p>)`.
        // The spelling still reaches the host as `flowZ28Z3cpZ3eZ29` and is
        // pinned there, in codegen.zig's "the `U` block is the SPELLING
        // contract" test; the two claims no longer ride on one string.
        try std.testing.expectEqual(pp.port, h.low.node_kind.items[pp.u].port_flow);
    }
    try std.testing.expectEqualStrings("flow(<a>)", h.low.nodeName(h.low.port_probes.items[0].u));
}

test "lower: §5.6.1.3 a kind mismatch REPLACES the retained value, and §5.4.2.2 reads it" {
    var h: Harness = undefined;
    // §5.6.1.3's own worked example, whose stated answer is 7.0 and whose whole
    // point is that 8.0 (every potential contribution accumulated, both
    // conversions ignored) is wrong.
    try Harness.run(std.testing.allocator,
        \\module vr(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    V(p,n) <+ 1.0;
        \\    I(p,n) <+ 2.0;
        \\    V(p,n) <+ 3.0;
        \\    V(p,n) <+ 4.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    // Two entries — the pair received both kinds — but only ONE survives with a
    // value. `emitResidual` skips a contribution whose value folds to `.f_zero`,
    // so the discarded flow source of 2.0 emits no row at all, which is what
    // "the flow being discarded" has to mean in the device.
    try std.testing.expectEqual(@as(usize, 2), h.low.contributions.items.len);
    for (h.low.contributions.items) |c| {
        switch (c.access) {
            .flow => try std.testing.expectEqual(Mir.Value.f_zero, c.resist_val),
            .potential => try std.testing.expect(c.resist_val != .f_zero),
        }
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }

    // §5.4.2.2 the read side: a flow read AFTER a flow contribution is the
    // retained value, so it mints no `flow(p,n)` unknown; before one — or on a
    // POTENTIAL source, whose branch current codegen does pin — it still does.
    //
    // What this asserts is WHETHER an unknown exists, and it now reads that off
    // the KIND TAG — the node pair keyed in `flow_unknowns` — rather than off
    // the string. Its counterpart on the spelling, that the member still prints
    // `flowZ28pZ2cnZ29`, is codegen.zig's "the `U` block is the SPELLING
    // contract" test. Two claims, two tests, no shared string.
    const cases = [_]struct { src: []const u8, unknown: bool }{
        .{ .src = "I(p,n) <+ 1.0; x = I(p,n);", .unknown = false },
        .{ .src = "x = I(p,n); I(p,n) <+ 1.0;", .unknown = true },
        .{ .src = "V(p,n) <+ 1.0; x = I(p,n);", .unknown = true },
    };
    for (cases) |c| {
        var g: Harness = undefined;
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module fr(p, n);
            \\  inout p, n; electrical p, n;
            \\  real x;
            \\  analog begin {s} end
            \\endmodule
        , .{c.src});
        defer std.testing.allocator.free(src);
        try Harness.run(std.testing.allocator, src, &g);
        defer g.deinit();
        try g.low.lowerFile();
        // `p` and `n` are node_order 0 and 1, so the branch is that pair.
        try std.testing.expectEqual(c.unknown, g.low.flow_unknowns.contains(.{ .hi = 0, .lo = 1 }));
    }
}

test "lower: §9.17.2 $bound_step accumulates through the CFG, not unconditionally" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $bound_step(1n);
        \\    if (V(p,n) > 0.0) $bound_step(1p);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // Exactly ONE synthetic call, and its argument is a phi: the guarded
    // `$bound_step(1p)` must NOT bound the step on the arm that never ran.
    var found: ?Mir.Value = null;
    var blocks = h.mir.blockIter();
    while (blocks.next()) |b| {
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) != .call) continue;
            if (!std.mem.eql(u8, h.mir.instData(inst).call.name, "$bound_step")) continue;
            try std.testing.expect(found == null);
            found = h.mir.instData(inst).call.args[0];
        }
    }
    const arg = h.mir.resolveAlias(found orelse return error.NoBoundStepCall);
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(arg).inst_result));
    // …and nothing was emitted for §9.17.1, which this module never calls.
    try std.testing.expect(h.low.disc_place == null);
}

test "lower: §9.17.1 $discontinuity separates iteration rejection from degree" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    try std.testing.expectEqual(Mir.Value.one, h.low.reject_iteration);
    // Iteration rejection must not become a timestep discontinuity.
    try std.testing.expect(h.low.disc_place == null);
    try std.testing.expect(h.low.bound_step_place == null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d2(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(2);
        \\    $discontinuity;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());
    try std.testing.expect(h2.low.disc_place != null);
}

test "lower: A.6.4 the analog_statement / analog_event_statement split" {
    // §5.10 "Contribution statements cannot be used inside an event control
    // block"; A.6.4 `analog_event_statement` has no contribution alternative.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(p, c);
        \\  inout p, c; electrical p, c;
        \\  analog @(cross(V(c), +1)) I(p) <+ V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0406, h.code(0));

    // `disable` is the mirror image: absent from `analog_statement`, present in
    // `analog_event_statement`. There is no §5.11 entry for it (5.11 is
    // jump_statement), so the diagnostic must not claim one.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p);
        \\  inout p; electrical p;
        \\  analog begin : work
        \\    if (V(p) > 1.0) disable work;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h2.bag.count());
    try std.testing.expectEqual(diag.Code.E0401, h2.code(0));
    // A.6.4, never §5.11 (which is jump_statement) — the citation is the code's.
    try std.testing.expectEqualStrings("A.6.4", diag.info(.E0401).lrm);
}

test "lower: §5.10.4 a named event resolves; anything else at `@`/`->` is E0705" {
    // The accepting side is three fixtures (annex_a/17, ch05/named_event_*,
    // annex_c/19), which pin the NUMBER end to end. What no fixture reaches is
    // the resolution failure, and it has to be a failure in both positions:
    // §2.8 gives an event a name and no value, so a real variable is not an
    // event even though `@(v)` would type-check as an integer guard.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ev(p);
        \\  inout p; electrical p; real v; event tick;
        \\  analog begin
        \\    @(initial_step) -> tick;
        \\    @(tick) v = 1.0;
        \\    @(v) v = 2.0;
        \\    I(p) <+ v;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0705, h.code(0));
    try std.testing.expectEqualStrings("`v`", h.msg(0));

    // The trigger goes through the same table, so a misspelling there lands on
    // the same code rather than silently triggering nothing.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module ev2(p);
        \\  inout p; electrical p; event tick;
        \\  analog begin
        \\    @(initial_step) -> tock;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0705, h2.code(0));
    try std.testing.expectEqualStrings("`tock`", h2.msg(0));
}

test "lower: an unknown name carries a `did you mean` help" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  real vds;
        \\  analog I(p) <+ vdss * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0314, h.code(0));
    try std.testing.expectEqualStrings("`vdss`", h.msg(0));
    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = h.bag.notes(h.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("did you mean `vds`?", notes[0].text);
}

test "lower: §3.3 Table 3-3 string concatenation folds; the integer form never reaches here" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  string a = "hello", b = "world", c;
        \\  analog begin
        \\    c = {a, " ", b};
        \\    I(p) <+ 0.0 * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // The LRM's own example: `{ "hello", " ", "world" }` == `"hello world"`.
    var found = false;
    for (h.mir.strings.strings.items) |s| {
        if (std.mem.eql(u8, s, "hello world")) found = true;
    }
    try std.testing.expect(found);

    // A non-string operand has no width here (the parser folds the sized-
    // constant form), so it is rejected rather than silently coerced.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m; integer a, b; analog a = {b, b}; endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0327, h2.code(0));
    try std.testing.expect(std.mem.indexOf(u8, h2.msg(0), "only sized constants") != null);
}

test "lower: §5.8.1 an analog operator under a runtime condition (E0514)" {
    // What makes this rule worth a diagnostic: an analog operator is a state
    // machine the kernel steps once per accepted timestep. Under a branch the
    // solve can flip, the step its arm was off feeds it the type's zero, and its
    // history is wrong from then on — with a residual that still looks ordinary.
    //
    // Each case is the SAME operator under a different condition; only the
    // condition decides the verdict, which is exactly what §5.8.1 says.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        // Not an analysis_or_constant_expression: a probe moves every iteration.
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "V(c) > 0.5 && gain > 0.0", .warns = true },
        // A.8.2 analysis_function_call — §5.8.1 names it explicitly.
        .{ .cond = "analysis(\"dc\")", .warns = false },
        .{ .cond = "!analysis(\"tran\")", .warns = false },
        // constant_primary: a §3.4 parameter cannot move mid-analysis.
        .{ .cond = "gain > 0.0", .warns = false },
        .{ .cond = "analysis(\"dc\") || gain > 0.0", .warns = false },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  parameter real gain = 1.0;
            \\  real q;
            \\  analog begin
            \\    q = 0.0;
            \\    if ({s}) q = ddt(V(p, n));
            \\    I(p, n) <+ q;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        };

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0514) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: §5.9 a loop body has no carve-out, and §4.5.6/§4.5.13 have no history" {
    // §5.9's ban on analog filter functions in repeat/while/non-genvar `for` is
    // unconditional — there is no analysis_or_constant escape hatch — so a
    // constant loop bound does NOT license the operator.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0514, h.code(0));

    // ...but a genvar `for` (§5.9.3 analog_for) is unrolled onto the spine, so
    // every operator instance is stepped every time: no warning.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  genvar i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());

    // `ddx` (§4.5.6) and `limexp` (§4.5.13) read no previous timestep, so a
    // branch that was off cannot corrupt them. `vdmos.va` calls conditional
    // `limexp` three times; warning there would be noise, and noise is what
    // teaches a modeller to silence the code.
    var h3: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  real q;
        \\  analog begin
        \\    q = 0.0;
        \\    if (V(c) > 0.5) q = limexp(V(p, n)) + ddx(V(p, n), V(p));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h3);
    defer h3.deinit();
    try h3.low.lowerFile();
    try std.testing.expect(h3.bag.isEmpty());
}

test "lower: §5.8/§5.10.3.1 an event control statement is stricter than E0514" {
    // §5.8: event control "cannot be used inside conditional statements unless
    // the conditional expression is a constant expression" — CONSTANT, not
    // analysis_or_constant. So the very condition that licenses `ddt` above
    // still rejects `@(cross(...))`, and the two rules must not share a counter.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "analysis(\"dc\")", .warns = true },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, c);
            \\  inout p, c;
            \\  electrical p, c;
            \\  real held;
            \\  analog begin
            \\    held = 0.0;
            \\    if ({s}) @(cross(V(c) - 1.0, 1)) held = V(p);
            \\    I(p) <+ held;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        };

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0707) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: A.6.2 an initial block of constant assignments lowers; anything else is E0433" {
    // The accepting side is six fixtures (ch07/digital_initial_accepted,
    // discrete_bus_narrow, discrete_bus_31, discrete_real_from_analog,
    // annex_c/13, ch08/analog_digital_initial_order), which pin the VALUE end to
    // end. What no fixture reaches is E0433's own arms: the two that would state
    // them (ch08/blocking_timing_unsupported, procedural_*) die in the parser
    // first, because `#`, `force` and `assign` have no statement production and a
    // parse error stops the pipeline before lowering. So they are stated here,
    // one per reading a discrete kernel would be needed to pick between.
    const cases = [_]struct { stmt: []const u8, code: diag.Code }{
        // A non-constant right-hand side: `v` is a runtime variable, so there is
        // nothing to install and nothing computed it before the analysis.
        .{ .stmt = "q = v;", .code = .E0433 },
        // §5.10 event control — parses (it is an ordinary analog statement) and
        // has nothing to suspend on.
        .{ .stmt = "@(initial_step) q = 1;", .code = .E0433 },
        // §5.9.2 a loop, and §5.8 a conditional over a runtime value: both are
        // only worth writing over something that changes during the run.
        .{ .stmt = "for (q = 0; q < 3; q = q + 1) q = 1;", .code = .E0433 },
        // §3.2.2 an array element: which element is a question about a value.
        .{ .stmt = "arr[0] = 1;", .code = .E0433 },
        // §6.8 a name this module never declares. Nothing else lowers the block,
        // so if this scan does not report it, nobody does.
        .{ .stmt = "nope = 1;", .code = .E0313 },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p);
            \\  inout p; electrical p;
            \\  integer q; real v; integer arr[0:3];
            \\  initial begin {s} end
            \\  analog begin v = V(p); I(p) <+ v + q; end
            \\endmodule
        , .{c.stmt});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == c.code) seen = true;
        }
        std.testing.expect(seen) catch |e| {
            std.debug.print("initial statement: {s}\n", .{c.stmt});
            return e;
        };
    }

    // The accepting shape, at the seam that matters: the constant reaches the
    // variable's INITIAL VALUE, which is where an A.2.2.1 declaration assignment
    // lands, and a parameter counts as a constant (§3.4).
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  parameter real k = 2.5;
        \\  integer q; real r;
        \\  initial begin q = 3; r = k; q = 4; end
        \\  analog I(p) <+ V(p) + q + r;
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 0), h.bag.count());
    // Last assignment wins: the body is sequential.
    try std.testing.expectEqual(@as(usize, 2), h.low.initial_state.count());
}
