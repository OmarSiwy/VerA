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
const constfold = @import("frontend").constfold;
const Mir = @import("mir.zig");
const Ssa = @import("ssa.zig");
const Elaborate = @import("elaborate.zig");
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
pub const assert = std.debug.assert;

pub const Lower = @This(); // so `Lower.Lower` also resolves

/// Only OOM unwinds during lowering; everything else goes in the shared
/// `diag.Bag` and lowering continues with a poison value, so one run reports
/// many errors.
pub const Oom = std.mem.Allocator.Error;
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
/// Sub-file-private state: each is read and written by that one file only.
node_state: lower_node.State = .{},
event_state: lower_event.State = .{},
param_state: lower_param.State = .{},
stmt_state: lower_stmt.State = .{},
table_model_state: lower_table_model.State = .{},
hier_name_state: lower_hier_name.State = .{},
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
/// The positional directive events the preprocessor published
/// (`Preprocessor.Directives`), set by the caller after `init` (root.zig). A
/// text stage cannot apply them itself — §10.2 hands `default_discipline to
/// §7.4 discipline resolution, which needs the module's declarations; §10.3's
/// `default_transition reaches a `transition()` only §4.5.8 codegen sees
/// (`codegen.defaultTransition`); §9.15 reads `timescale back (`timescale()`,
/// null when the stream specified none, which Table 9-27's "AS SPECIFIED IN
/// `timescale" makes not known rather than a default) — so all it can say is
/// WHERE each took effect. `nettypes` is read wherever a §3.6.5 implicit net
/// would be made (`nodeOf`, `rejectImplicitNet`), `cells` once by
/// `lowerModule` for `Mir.is_cell`, `drives` by `applyUnconnectedDrive`. Empty
/// when the text never came through stage 1.
directives: Preprocessor.Directives = .{},
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
/// §9.4.6 the same carrier for the CONDITIONAL prints, which cannot be
/// `fadd`-chained directly: a call inside an `if` arm does not dominate the
/// chain root at the end of the block. An SSA place does — seeded `.f_zero` in
/// `.entry`, `fadd`-ed at each guarded call site, read once at the end — so the
/// arm's phi carries the call into the live slice on the path that ran and
/// carries a zero on the path that did not. Null = no conditional print.
/// The print itself stays where lowering put it: codegen emits the block's
/// instructions inside the emitted `if`, so it runs exactly when the arm does.
display_cond_place: ?Ssa.Place = null,
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
/// §7.3.6.5/§8.5 a mixed module's digital-owned values the analog block may
/// read, name → declaring token, in first-write order. Each is also a hidden
/// §3.4 parameter (a host-written `Model` field). See
/// `lower_context.declareDiscreteInputs`.
discrete_inputs: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// The module's discrete half needs the event queue (`lower_context.isMixed`).
mixed_signal: bool = false,
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
contrib_target: ?lower_contrib.Target = null,

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
    /// The call token, for W0850.
    tok: u32,
    /// The call sits under an `if` or a loop, so it reaches the display root
    /// through `display_cond_place` rather than by direct `fadd` (the value
    /// does not dominate the root). `finishDisplays` is the one reader: it
    /// leaves these out of the unconditional chain.
    conditional: bool,
};

pub const VarSlot = struct { place: Ssa.Place, ty: Ty };
const ScopeEntry = struct { name: []const u8, prev: ?VarSlot, prev_array: ?ArrayInfo };
/// A declared array's shape (§3.2), one `Bounds` per dimension, outermost
/// first. `dims.len` is the number of subscripts a reference must supply.
pub const ArrayInfo = struct {
    dims: []const lower_param.Bounds,
    ty: Ty,
};
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };
/// `wrote` is §5.6.1.3's retention FLAG beside the value: 0.0 in the entry
/// block, 1.0 after every `<+` on this (access, branch), back to 0.0 when the
/// opposite access discards it. It has exactly the accumulator's phi structure,
/// so "was a value retained THIS cycle?" survives a conditional as an ordinary
/// SSA boolean — which is what codegen's runtime-selected branch row reads.
/// On a straight line it folds to the constant 1.0/0.0 and costs nothing.
pub const Accum = struct { resist: Ssa.Place, react: Ssa.Place, wrote: Ssa.Place };

/// A folded `[msb:lsb]` (§3.6.3 Syntax 3-6 `range`). Both bounds are signed and
/// either order is legal — §3.6.3's own examples run `[5:0]` and the LRM's
/// vector-branch example runs `[3:5]` — so nothing here assumes msb ≥ lsb.
pub const VecRange = struct {
    msb: i64,
    lsb: i64,

    pub fn size(v: VecRange) u32 {
        return @intCast(@abs(v.msb - v.lsb) + 1);
    }
    pub fn has(v: VecRange, i: i64) bool {
        return i >= @min(v.msb, v.lsb) and i <= @max(v.msb, v.lsb);
    }
    /// The k-th element in DECLARATION order, msb first. That order is the
    /// host's terminal order for a vector port, and it is what §3.12 pairs
    /// "in a parallel one-to-one fashion" for a vector branch.
    pub fn at(v: VecRange, k: u32) i64 {
        const d: i64 = @intCast(k);
        return if (v.msb <= v.lsb) v.msb + d else v.msb - d;
    }
};

/// A folded constant (§4.2 constant_expression) — the shared kernel's.
pub const Const = constfold.Const;

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

/// Unmaps the SSA matrix, the one allocation an arena cannot reclaim.
/// Every other table lives in `arena`: all six constructors (the driver,
/// lower/codegen/proof test harnesses, naming.zig, cg_display.zig) pass one.
pub fn deinit(self: *Lower) void {
    self.builder.deinit();
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
pub fn tokStart(self: *const Lower, tok: u32) u32 {
    return if (tok < self.tok_starts.len) self.tok_starts[tok] else 0;
}

/// Record an error and keep going. Callers substitute a poison value; nothing
/// downstream runs because `lowerFile` fails at the end.
pub fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    self.had_error = true;
    return self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
}

/// Same, for a diagnostic that wants a label, a note or a suggestion. The
/// caller must `emit()`.
pub fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    self.had_error = true;
    return self.bag.build(.lower, code, self.tokenSpan(tok));
}

/// A poison real. Lowering continues so the run reports every error at once.
pub const poison: TypedValue = .{ .v = .undef, .ty = .real };

// ---------------------------------------------------------------------------
// Small MIR helpers
// ---------------------------------------------------------------------------

pub fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    return self.mir.emit(self.arena, self.cur, op, ops);
}

pub fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    const callee = try self.mir.internString(self.arena, name);
    return self.mir.emitCall(self.arena, self.cur, callee, args);
}

/// Close `self.cur` with a jump and register the CFG edge (ssa.zig requires the
/// edge before the target is sealed).
pub fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Register both CFG edges before sealing their targets. A loop leaves its
/// exit unsealed until its body has registered any `break` predecessors.
pub inline fn branchTo(self: *Lower, cond: Mir.Value, then_b: Mir.Block, else_b: Mir.Block, comptime seal_else: bool) Oom!void {
    _ = try self.mir.emitBranch(self.arena, self.cur, cond, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    if (seal_else) try self.builder.sealBlock(else_b);
}

/// Start a fresh predecessor-less block. Everything appended to it is dead
/// (post-`break`/`return` code, §5.9/§4.7.1); sealing it immediately keeps the
/// SSA builder from ever waiting on an edge that will not arrive.
pub fn startUnreachable(self: *Lower) Oom!void {
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

/// §3.2's 32-bit integer wrap and IEEE 1364-2005 Table 5-6's integer power:
/// defined once, in the shared constant kernel, because codegen spells them
/// as device text and a fold must agree with the device.
pub const wrap32 = constfold.wrap32;
pub const ipow32 = constfold.ipow32;

/// §2.7 at an OPERAND: a string about to be used as a number becomes one.
/// Everything else is returned untouched, including a string with no compile-
/// time bytes — there is no runtime string in the emitted device, so that is
/// already broken and the caller's own diagnostic is the better one.
///
/// ponytail: 64 bits, the width of the slot the value lands in. §3.3's
/// assignment case knows the DECLARED width and passes its own; an operand has
/// only its storage, so a literal longer than eight characters keeps its low
/// eight.
pub fn strNum(self: *Lower, tv: TypedValue) Oom!TypedValue {
    if (tv.ty != .string) return tv;
    return switch (self.mir.valueDef(tv.v)) {
        .str_const => |s| .{ .v = try self.mir.addIntConst(self.arena, strToInt(s, 64)), .ty = .integer },
        else => tv,
    };
}

pub fn toReal(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    const tv = try self.strNum(tv0); // §2.7
    return switch (tv.ty) {
        .real => tv.v,
        .integer => self.emit(.if_cast, &.{tv.v}),
        .string => tv.v, // already diagnosed at the use site
    };
}

pub fn toInt(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
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
pub fn coerceTo(self: *Lower, e: Ast.ExprId, ty: Ty, tv: TypedValue) Oom!Mir.Value {
    if (tv.ty == .string and ty != .string) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.arena);
        if (!try self.strLitBytes(e, &bytes)) {
            try self.err(self.file.exprs.mainTok(e), .E0354, "assigning a string to {s}", .{@tagName(ty)});
            return lower_param.zeroOf(ty);
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
pub fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .integer => self.emit(.ine, &.{ tv.v, .zero }),
        .real => self.emit(.fne, &.{ tv.v, .f_zero }),
        .string => .zero,
    };
}

/// §4.2.1 — an operation with one real operand is performed in real.
pub fn unify(a: Ty, b: Ty) Ty {
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

pub fn astTy(t: Ast.Type) Ty {
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
    for (design.implicit_nets) |n| try lower_node.rejectImplicitNet(self, n.name, n.main_tok);
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
    self.mir.is_cell = Preprocessor.CellRegion.inForce(self.directives.cells, self.tokStart(module.main_tok), false);

    const entry = try self.mir.addBlock(self.arena);
    assert(entry == .entry);
    try self.builder.sealBlock(entry);
    self.cur = entry;

    try lower_discipline.collectDisciplines(self); // §3.6.1/§3.6.2 (annex D.1 is inlined here)
    try lower_discipline.checkNatureTable(self); // §3.6.1/§3.13 — the declaration table itself

    // §3.4 parameters BEFORE the ports, because a range is a constant
    // expression over them: §6.5.2.2's own example is `input [1:width] dt`
    // with `width` a module parameter, and `foldDim` cannot answer that from
    // an empty `consts`. Nothing in a parameter declaration can name a net —
    // §3.4 defaults are constant expressions — so the two orders differ only
    // in what is already known, never in what is reachable.
    for (module.params) |*p| try lower_param.lowerParamDecl(self, p);
    // §7.3.6.5: a mixed module's digital-owned values are host-written inputs.
    // Before the ports and nets, so none of them becomes an analog node.
    try lower_context.declareDiscreteInputs(self, module);

    // §6.5 ports first: this order IS the host device's terminal order.
    for (module.ports) |p| {
        // §3.6.3/§6.5.2 a vector port is N terminals, in declaration order.
        if (try lower_node.portRange(self, &p)) |r| {
            const name = self.file.str(p.name);
            const disc = self.strOrEmpty(p.discipline);
            for (0..r.size()) |k| {
                const idx = try lower_node.internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, r.at(@intCast(k)) }), disc);
                self.node_dir.items[idx] = p.direction;
            }
            try self.vectors.put(self.arena, name, r);
            continue;
        }
        const idx = try lower_node.internNode(self, try lower_node.netKey(self, self.file.str(p.name), p.main_tok), self.strOrEmpty(p.discipline));
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
        if (self.discrete_inputs.contains(self.file.str(n.name))) continue;
        // §2.8.1 vs §3.6.3 — see `netKey`. A RANGED declaration is a vector and
        // its own name never reaches the node table, so the key is the scalar
        // path's and the `vectors` entry below keeps the declared spelling.
        const name = try lower_node.netKey(self, self.file.str(n.name), n.main_tok);
        // §3.6.3 a vector net is N independent nets, scalarised here.
        //
        // §3.6.3.2's bus initializer is scalarised with them: "In the case of
        // analog buses, a constant array expression is used as an initializer.
        // A null value in the constant array indicates that no nodeset value is
        // being specified for this element of the bus." `flattenPattern` is
        // already the per-cell reader the §3.4.4 parameter arrays use, and it
        // answers `.none` for both spellings of "nothing here" — the clause's
        // hole and a pattern shorter than the bus.
        if (n.range) |d| {
            if (try lower_node.foldDim(self, d, n.main_tok)) |r| {
                // ONLY a pattern seeds nodesets, and a non-pattern initializer
                // is NOT an error here. §3.6.3.2's rule is about the analog
                // bus spelling — "a constant array expression is used as an
                // initializer" — and `wire [3:0] wbus = 4'h5;` is not that: it
                // is A.2.2.1's `net_declaration` with a continuous assignment
                // of one sized value to the whole vector, which is legal 1364
                // that VerA does not model yet (the same `assign` gap the ch07
                // rows are blocked on, PLAN.md §3). Refusing it here rejected
                // `annex_a_syntax/52_net_and_variable_types.va`, whose whole
                // claim is that the eleven net_type spellings compile.
                //
                // ponytail: so the value is dropped, exactly as it was before
                // the per-cell seeding below existed. Upgrade path: when
                // `assign` lands, a non-pattern initializer becomes its
                // continuous assignment rather than a nodeset, and this arm
                // routes there instead of ignoring it.
                const seeds: []const Ast.ExprId = if (n.init == .none or
                    self.file.exprs.tag(n.init) != .assign_pattern)
                    &.{}
                else
                    try lower_param.flattenPattern(self, n.init, &.{lower_param.Bounds{ .lo = 0, .hi = r.size() - 1 }});
                for (0..r.size()) |k| {
                    const idx = try lower_node.internNode(self, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, r.at(@intCast(k)) }), self.strOrEmpty(n.discipline));
                    if (k < seeds.len and seeds[k] != .none)
                        try lower_node.recordNodeset(self, idx, seeds[k], n.main_tok, name);
                }
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
        const idx = try lower_node.internNode(self, name, self.strOrEmpty(n.discipline));
        // §3.6.3.2 the net_decl_assignment, folded. `consts` is already loaded
        // — the parameter loop runs above the port loop — so a nodeset written
        // over a parameter folds here and not later.
        if (n.init != .none) try lower_node.recordNodeset(self, idx, n.init, n.main_tok, name);
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
    for (module.ports) |p| try lower_node.applyDefaultToAll(self, self.file.str(p.name), p.main_tok);
    for (module.nets) |n| if (!self.discrete_inputs.contains(self.file.str(n.name)))
        try lower_node.applyDefaultToAll(self, self.file.str(n.name), n.main_tok);

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
        var key_buf: [lower_param.elem_key_len]u8 = undefined;
        const probe_name = if (self.vectors.get(base)) |r| try lower_param.elemKey(self, &key_buf, base, &.{r.at(0)}) else base;
        const idx = self.node_voltages.get(probe_name) orelse continue;
        if (idx == ground) continue;
        const dname = self.node_disciplines.items[idx];
        if (!lower_node.isSignalFlow(self, dname)) continue;
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
        if (!self.param_index.contains(alias) and try lower_param.aliasSystemParam(self, alias, target)) continue;
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
            (try lower_node.foldDim(self, d, b.main_tok) orelse continue)
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
            const p = try lower_node.nodeOf(self, b.hi);
            for (0..(if (arr) |r| r.size() else 1)) |k| {
                const key = if (arr) |r| try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, r.at(@intCast(k)) }) else base;
                try self.port_branches.put(self.arena, key, p);
            }
        } else if (arr) |r| {
            // A.2.3's branch ARRAY: the elements share one (hi, lo) and are
            // separate branches over it (§5.4.1 "any number of named branches
            // between any two signals"), so each takes its own identity and its
            // own accumulator — `br1[0]` and `br1[1]` are two sources.
            const hi = try lower_node.nodeOf(self, b.hi);
            const lo = if (b.lo == .none) ground else try lower_node.nodeOf(self, b.lo);
            try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo); // §3.12 → §3.11
            for (0..r.size()) |k|
                try self.branches.put(self.arena, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, r.at(@intCast(k)) }), .{
                    .hi = hi,
                    .lo = lo,
                    .id = lower_node.newBranchId(self),
                });
        } else if (lower_node.vecTerminal(self, b.hi) != null or lower_node.vecTerminal(self, b.lo) != null) {
            // §3.12 a branch with a vector terminal is a vector branch.
            try lower_node.declareVectorBranch(self, &b);
            continue;
        } else {
            const hi = try lower_node.nodeOf(self, b.hi);
            const lo = if (b.lo == .none) ground else try lower_node.nodeOf(self, b.lo);
            // §3.12: "The disciplines for the specified nets shall be
            // compatible (see 3.11)." Only the two-terminal form has two
            // disciplines to compare — the one-terminal form's second net is
            // ground, and §3.12 says the branch then "derives" its discipline
            // from the one net that is named.
            try lower_discipline.checkNetCompat(self, b.main_tok, hi, lo);
            try self.branches.put(self.arena, base, .{ .hi = hi, .lo = lo, .id = lower_node.newBranchId(self) });
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
    try lower_param.markHeldVars(self, module);
    try lower_param.checkOneItemPerScope(self, module.vars);
    // A.6.2 the digital `initial` block, for the same reason and at the same
    // point as the §5.10 scan above: what a variable holds at the top of every
    // evaluation is decided at its declaration. `initial x = 3;` and
    // `integer x = 3;` therefore lower to one write, and the AST edit below is
    // the whole of the difference.
    try lower_context.collectInitialState(self, module);
    for (module.vars) |*v| {
        if (self.discrete_inputs.contains(self.file.str(v.name))) continue;
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
        try lower_param.declareVarDecl(self, &d, .module);
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
    try lower_func.checkFuncRecursion(self, module.functions);

    // §2.9/§2.9.2 — AFTER the declarations, because "constant expression" is a
    // question about the scopes, and BEFORE the analog block, so an attribute is
    // reported at its own token rather than after a body that may not compile.
    try lower_param.checkAttributes(self, module.attrs);

    // §7.2.2 the DISCRETE context. Before the analog blocks because the rules
    // below relate the two, and it is the discrete side that names the variables
    // the continuous side is then judged against.
    try lower_context.checkDiscreteContext(self, module);

    // §9.17.3 the user-function `$limit` state slots. BEFORE the body, because
    // each slot's previous-iterate read has to be seeded in the ENTRY block —
    // a site under an `if` must still leave a value the end-of-block read can
    // find, and a slot minted inside the arm would not dominate it.
    for (module.analog) |blk| try lower_func.scanCallSites(self, blk.body, true, {}, {});

    // IEEE 1364 §19.10, also before the body and for a related reason: the pull
    // on an unconnected `input` is the OUTSIDE driving the port, so it is there
    // when the child's equations read it, not added after them.
    try lower_node.applyUnconnectedDrive(self);

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
            try lower_control.lowerBranchStmt(self, flag, blk.body, .none, false);
            self.in_analog_initial = false;
            self.restrict = prev;
        } else {
            try lower_stmt.lowerStmt(self, blk.body);
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
    try lower_contrib.checkProbeBranches(self);
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
/// Only `cond_depth == 0` calls join DIRECTLY. They lie on the straight-line
/// spine of the analog block, so each one dominates `self.cur` here; a call
/// inside an `if` arm does not, and chaining it would be invalid SSA. Those
/// reach the root through `display_cond_place` instead — one read of a place
/// the arms wrote, which is an ordinary phi and dominates like any other value.
/// §9.4.6 is satisfied by WHERE the call sits, not by whether it is chained:
/// the call stays in the arm's block and codegen emits the arm as an `if`.
///
/// ponytail: PRINT ORDER is MIR order, and the two rules pull opposite ways —
/// a guarded call must stay in its arm, an unconditional one is minted here
/// (`queueDisplay`) — so a module that prints both shows the guarded lines
/// first, whatever the source order. Nothing that printed before this existed
/// moved: the unconditional group keeps its position and its order, and the
/// guarded lines are new output. Upgrade path, if a fixture ever needs the two
/// interleaved: give `Display` a source-order index and have codegen emit the
/// display unit's calls by it rather than by block walk.
fn finishDisplays(self: *Lower) Oom!void {
    try lower_event.lowerDeferredDisplays(self);
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
    if (self.display_cond_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        root = if (first) v else try self.emit(.fadd, &.{ root, v });
    }
    self.display_root = root;
}

/// Carry one guarded §9.4/§9.5/§9.7 call into the display slice. The value is
/// discarded at the root like every other print result; what the `fadd` buys is
/// a USE, without which codegen's slice drops the call and the print with it.
pub fn chainCondDisplay(self: *Lower, v: Mir.Value) Oom!void {
    const p = self.display_cond_place orelse blk: {
        const np = self.builder.newPlace();
        try self.builder.writeVariable(np, .entry, .f_zero);
        self.display_cond_place = np;
        break :blk np;
    };
    const prev = try self.builder.readVariable(p, self.cur);
    try self.builder.writeVariable(p, self.cur, try self.emit(.fadd, &.{ prev, v }));
}

/// Fetch (creating on first use) a kernel-control place, seeded to +inf in the
/// entry block. `+inf` is the identity of `fmin` AND the correct "the model
/// asked for nothing" default for both tasks, so no separate "was it called"
/// flag has to survive the CFG.
pub fn kernelCtlPlace(self: *Lower, slot: *?Ssa.Place) Oom!Ssa.Place {
    if (slot.*) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_inf);
    slot.* = p;
    return p;
}

fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8 {
    return if (id == .none) "" else self.file.str(id);
}

// §7.2.2 the discrete context: which statements and nets are digital — lower/context.zig
const lower_context = @import("lower/context.zig");

// §3.6 disciplines and natures, §3.11 net compatibility — lower/discipline.zig
const lower_discipline = @import("lower/discipline.zig");

// §1.3.1 nodes: nets, ports, ground and the solver-unknown order — lower/node.zig
const lower_node = @import("lower/node.zig");
pub const nodeName = lower_node.nodeName;

// §3.4 parameters and §3.2 variables and scopes — lower/param.zig
const lower_param = @import("lower/param.zig");

// §5 analog statements: blocks, assignments, named blocks — lower/stmt.zig
const lower_stmt = @import("lower/stmt.zig");

// §5.6 contributions: `<+`, indirect contributions, switch branches — lower/contrib.zig
const lower_contrib = @import("lower/contrib.zig");

// §5.8 conditionals and §5.9 loops — lower/control.zig
const lower_control = @import("lower/control.zig");

// §5.10 analog events: `@(...)`, cross/above/timer, initial_step/final_step — lower/event.zig
const lower_event = @import("lower/event.zig");
pub const isSimCtlTask = lower_event.isSimCtlTask;
pub const isFileOutTask = lower_event.isFileOutTask;
pub const isFileCall = lower_event.isFileCall;
pub const isDisplayTask = lower_event.isDisplayTask;
pub const isMonitor = lower_event.isMonitor;
pub const distOf = lower_event.distOf;
pub const distParamName = lower_event.distParamName;

// §4.2 expressions, §4.3 math functions, §4.4 signal access — lower/expr.zig
const lower_expr = @import("lower/expr.zig");
pub const unaryMathOp = lower_expr.unaryMathOp;
pub const binaryMathOp = lower_expr.binaryMathOp;

// §4.5 analog operators and filters — lower/analog_op.zig
const lower_analog_op = @import("lower/analog_op.zig");

// Clause 9 system functions and tasks in analog context, and their arguments — lower/sysfunc.zig
const lower_sysfunc = @import("lower/sysfunc.zig");
pub const simparamValue = lower_sysfunc.simparamValue;
pub const simparamIsRuntime = lower_sysfunc.simparamIsRuntime;
pub const simparamHostField = lower_sysfunc.simparamHostField;
pub const sysFuncTy = lower_sysfunc.sysFuncTy;

// §9.21 `$table_model` — lower/table_model.zig
const lower_table_model = @import("lower/table_model.zig");

// `$limit`: the limiting-function call and its per-call state slot — lower/limit.zig
const lower_limit = @import("lower/limit.zig");

// §9.16 `$simprobe` and §9.20 hierarchical reference strings — lower/hier_name.zig
const lower_hier_name = @import("lower/hier_name.zig");

// §4.7 user-defined analog functions — lower/func.zig
const lower_func = @import("lower/func.zig");

// Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds — lower/constfold.zig
const lower_constfold = @import("lower/constfold.zig");

// Lowering self-checks: source in, diagnostics or MIR out — lower/test.zig
const lower_test = @import("lower/test.zig");

test {
    _ = lower_context;
    _ = lower_discipline;
    _ = lower_node;
    _ = lower_param;
    _ = lower_stmt;
    _ = lower_contrib;
    _ = lower_control;
    _ = lower_event;
    _ = lower_expr;
    _ = lower_analog_op;
    _ = lower_sysfunc;
    _ = lower_table_model;
    _ = lower_limit;
    _ = lower_hier_name;
    _ = lower_func;
    _ = lower_constfold;
    _ = lower_test;
}
