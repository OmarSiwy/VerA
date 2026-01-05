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
const Ast = @import("../frontend/ast.zig");
const Mir = @import("mir.zig");
const Ssa = @import("ssa.zig");
const Elaborate = @import("elaborate.zig");
const Lexer = @import("../frontend/lexer.zig");
const Preprocessor = @import("../frontend/preprocessor.zig");
const diag = @import("../diag.zig");
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
    noise_kind: ?NoiseKind = null, // §4.6.4
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
};

pub const Kind = enum(u8) { direct, indirect };

/// §5.4.3 one probed module port: the port's node_order slot and the
/// node_order slot of the flow unknown that carries `I(<port>)`.
pub const PortProbe = struct { port: u16, u: u16 };

/// §5.4.2.1 one access function READ, kept for the end-of-module probe sweep.
pub const BranchRead = struct { access: Access, hi: u16, lo: u16, tok: u32 };

pub const NoiseKind = enum(u8) { thermal, flicker }; // §4.6.4.1/.2

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
num_ports: usize = 0, // §6.5
node_voltages: std.StringHashMapUnmanaged(u16) = .empty, // §1.3.1 name → index
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
/// §5.9 break/continue targets.
loops: std.ArrayList(LoopCtx) = .empty,
/// §4.7.1 the function currently being inlined (return slot + exit block).
ret: ?RetCtx = null,
/// §4.7.1 recursion guard — names on the inline stack.
inlining: std.ArrayList([]const u8) = .empty,
/// Non-null inside an `analog initial` block (§5.2.1) or an analog function
/// (§4.7.2); names the context in the "not allowed here" diagnostic.
restrict: ?[]const u8 = null,
/// §9.20 the analog_net_reference of every alias call so far, in source order.
/// The clause's last rule relates two calls — "It shall be an error for the
/// hierarchical_reference_string to reference a node that is used as an
/// analog_net_reference in ANOTHER ... call" — and this is the only state that
/// needs. Names, not indices: the comparison is against a §6.7 path string.
alias_refs: std.ArrayList([]const u8) = .empty,
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
/// §9.4 display tasks, in source order. A display call's RESULT is never read,
/// so it is dead code the moment codegen slices a unit out of the MIR — and the
/// print vanishes with it. `display_root` is the one live root that keeps them
/// all: see `finishDisplays`.
displays: std.ArrayList(Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable RETAINS its value between analog evaluations — that
/// is the entire point of `@(cross(...)) x = V(p);`, and an ordinary SSA place
/// cannot express it, because every module variable is re-initialised from its
/// declaration at the top of every evaluation. Each entry gets a persistent
/// `Instance` slot instead; codegen reads it directly.
held_vars: std.ArrayList(HeldVar) = .empty,
/// Source names `markHeldVars` found under an `@(...)`, collected BEFORE the
/// module's variables are declared. Empty for a module with no event control.
held_names: std.StringHashMapUnmanaged(void) = .empty,
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

const VarSlot = struct { place: Ssa.Place, ty: Ty };
const ScopeEntry = struct { name: []const u8, prev: ?VarSlot };
/// A declared array's shape (§3.2), one `Bounds` per dimension, outermost
/// first. `dims.len` is the number of subscripts a reference must supply.
const ArrayInfo = struct {
    dims: []const Bounds,
    ty: Ty,

    /// The first dimension, for the callers that only handle a flat vector
    /// (a whole array passed to §4.5.11's coefficient slot, §3.4.4's parameter
    /// element walk).
    fn first(a: ArrayInfo) Bounds {
        return a.dims[0];
    }
};
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };
const Accum = struct { resist: Ssa.Place, react: Ssa.Place };

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
    pub fn asInt(c: Const) i64 {
        return switch (c) {
            .int => |i| i,
            // §4.2.1.1 real→integer rounds, ties away from zero.
            .real => |r| @intFromFloat(@round(r)),
            .str => 0,
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
    self.node_disciplines.deinit(gpa);
    self.node_dir.deinit(gpa);
    self.port_probes.deinit(gpa);
    self.node_voltages.deinit(gpa);
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
    self.inlining.deinit(gpa);
    self.displays.deinit(gpa);
    self.held_vars.deinit(gpa);
    self.held_names.deinit(gpa);
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

pub fn exprSpan(self: *const Lower, e: Ast.ExprId) diag.Span {
    return self.tokenSpan(self.file.exprs.mainTok(e));
}

/// Record an error and keep going. Callers substitute a poison value; nothing
/// downstream runs because `lowerFile` fails at the end.
fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    self.had_error = true;
    return self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
}

fn errAt(self: *Lower, e: Ast.ExprId, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    return self.err(self.file.exprs.mainTok(e), code, fmt, args);
}

/// Same, for a diagnostic that wants a label, a note or a suggestion. The
/// caller must `emit()`.
fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    self.had_error = true;
    return self.bag.build(.lower, code, self.tokenSpan(tok));
}

fn errAtWith(self: *Lower, e: Ast.ExprId, code: diag.Code) diag.Builder {
    return self.errWith(self.file.exprs.mainTok(e), code);
}

/// A poison real. Lowering continues so the run reports every error at once.
const poison: TypedValue = .{ .v = .undef, .ty = .real };

// ---------------------------------------------------------------------------
// Small MIR helpers
// ---------------------------------------------------------------------------

fn newBlock(self: *Lower) Oom!Mir.Block {
    return self.mir.addBlock(self.arena);
}

fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    return self.mir.emit(self.arena, self.cur, op, ops);
}

fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    const callee = try self.mir.internString(self.arena, name);
    return self.mir.emitCall(self.arena, self.cur, callee, args);
}

fn fconst(self: *Lower, x: f64) Oom!Mir.Value {
    return self.mir.addFloatConst(self.arena, x);
}

fn iconst(self: *Lower, x: i64) Oom!Mir.Value {
    return self.mir.addIntConst(self.arena, x);
}

/// Close `self.cur` with a jump and register the CFG edge (ssa.zig requires the
/// edge before the target is sealed).
fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Start a fresh predecessor-less block. Everything appended to it is dead
/// (post-`break`/`return` code, §5.9/§4.7.1); sealing it immediately keeps the
/// SSA builder from ever waiting on an edge that will not arrive.
fn startUnreachable(self: *Lower) Oom!void {
    const b = try self.newBlock();
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
        .str_const => |s| .{ .v = try self.iconst(strToInt(s, 64)), .ty = .integer },
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
            try self.errAt(e, .E0354, "assigning a string to {s}", .{@tagName(ty)});
            return zeroOf(ty);
        }
        // §3.3's "right justified and either truncated on the left or zero
        // filled on the left" is measured against the DECLARED type, and §3.2
        // fixes `integer` at 32 bits: "hello" is 40 bits and loses its 'h'.
        // That width is the LRM's and not VerA's storage — see `strToInt`.
        if (ty == .integer) return self.iconst(strToInt(bytes.items, 32));
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
/// header for why the MIR gains no hierarchy concept — so a design of one unit
/// (all any file can hold while §6.2.2 instantiation is refused in the parser)
/// reaches `lowerModule` exactly as the module AST did before the pass existed.
/// When a flattened instance list arrives it is walked HERE, and `lowerModule`
/// stays the per-unit body it already is.
///
/// Elaboration is called from lowering rather than from the driver because its
/// input is the AST and its only consumer is the next line: a `Lower` field set
/// by root.zig would buy a second entry path and nothing else.
pub fn lowerFile(self: *Lower) Error!void {
    const design = try Elaborate.elaborate(.{
        .arena = self.arena,
        .file = self.file,
        .src = self.src,
        .tok_starts = self.tok_starts,
        .bag = self.bag,
    });
    self.hier_names = design.names;
    try self.lowerModule(design.top);
    if (self.had_error) return error.DiagnosticsReported;
}

/// LRM §6.2/§6.9. Register ports (§6.5) into node_order, elaborate the
/// declarations, then lower each analog block (§5.2) in source order —
/// multiple analog blocks are executed as if concatenated (§6.9.1).
pub fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    self.module = module;
    self.mir.name = self.file.str(module.name);

    const entry = try self.newBlock();
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
                const idx = try self.internNode(try self.vecElem(name, r.at(@intCast(k))), disc);
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
        if (n.range) |d| {
            if (try self.foldDim(d, n.main_tok)) |r| {
                for (0..r.size()) |k|
                    _ = try self.internNode(try self.vecElem(name, r.at(@intCast(k))), self.strOrEmpty(n.discipline));
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
        _ = try self.internNode(name, self.strOrEmpty(n.discipline));
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
        const probe_name = if (self.vectors.get(base)) |r| try self.vecElem(base, r.at(0)) else base;
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
            if (diag.didYouMeanMap(self.arena, target, self.param_index)) |s|
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
                const key = if (arr) |r| try self.vecElem(base, r.at(@intCast(k))) else base;
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
                try self.branches.put(self.arena, try self.vecElem(base, r.at(@intCast(k))), .{
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

    // §5.2 analog blocks, concatenated (§6.9.1).
    for (module.analog) |blk| {
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
            try self.lowerGuarded(flag, blk.body);
            self.in_analog_initial = false;
            self.restrict = prev;
        } else {
            try self.lowerStmt(blk.body);
        }
    }

    try self.checkProbeBranches();

    // §5.6.1.3 the contribution accumulators' final values.
    for (self.contributions.items, self.accum.items) |*c, acc| {
        c.resist_val = try self.builder.readVariable(acc.resist, self.cur);
        c.react_val = try self.builder.readVariable(acc.react, self.cur);
    }
    // §5.10 the same, for every held variable. Reads only — no `call` — so the
    // unit enumeration below is untouched.
    for (self.held_vars.items) |*h| h.final = try self.builder.readVariable(h.place, self.cur);

    // §9.17 analog kernel control. Emitted LAST and in this fixed order so the
    // unit enumeration stays a pure function of the source.
    try self.finishKernelCtl();
    // §9.4 display tasks. AFTER the kernel-control calls on purpose: those two
    // become naming units, and inserting anything ahead of them would renumber
    // every Instance state field. The display chain adds no unit of its own.
    try self.finishDisplays();
}

/// §9.17.1/§9.17.2. Turn each accumulated kernel-control place into exactly one
/// synthetic `call`, whose single argument is the value the host must read.
/// `naming.enumerateUnits` gives that call a unit; `codegen.emitStateMachine`
/// evaluates the unit once per accepted step and stores it into `Instance`.
fn finishKernelCtl(self: *Lower) Oom!void {
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
    var root: Mir.Value = .f_zero;
    var first = true;
    for (self.displays.items) |d| {
        if (d.conditional) continue;
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
        try self.scanDiscrete(blk.body, blk.main_tok, &ctx);
    }
    // The continuous side second: §7.2.2's conflict and §5.2.1's read are both
    // "this analog statement, against what the discrete blocks own", so the
    // discrete set has to be complete first. §7.2.2 is symmetric, and reporting
    // it at the ANALOG statement is the choice the clause's own wording makes —
    // "the domain of a variable is that of the context from which its value is
    // assigned" gives the variable to whichever context is not the intruder, and
    // a module with a discrete block in it has already been told about that.
    for (module.analog) |blk| try self.scanContinuous(blk.body, blk.is_initial, &ctx);
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

/// One statement of an `initial`/`always` body. Collects the §7.2.2 assignment
/// targets and checks every expression under it.
///
/// ponytail: a name declared in a NAMED BLOCK inside the discrete body shadows
/// the module-level one, and this scan does not model that — the
/// `self.vars.contains` filter is what keeps the false positive out, by only
/// ever recording a name the module itself declared. A block-local `integer x`
/// shadowing a module-level `real x` would still be recorded; give
/// `Ast.SeqBlock` a scope walk here if a model ever does that.
fn scanDiscrete(self: *Lower, id: Ast.StmtId, blk_tok: u32, ctx: *DiscreteCtx) Oom!void {
    if (id == .none) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .assign => |a| {
            // The target of `bus[3] = ...` is the array, so walk down to the
            // base name — §7.2.2's domain is a property of the DECLARATION.
            var t = a.target;
            while (t != .none and (ex.tag(t) == .index or ex.tag(t) == .range)) t = ex.lhs(t);
            if (t != .none and ex.tag(t) == .ident) {
                const name = self.file.str(ex.strOf(t));
                if (self.vars.contains(name)) try ctx.assigned.put(self.arena, name, blk_tok);
            }
            try self.scanDiscreteExpr(a.value, ctx);
        },
        .block => |b| for (b.body) |s| try self.scanDiscrete(s, blk_tok, ctx),
        .if_stmt => |s| {
            try self.scanDiscreteExpr(s.cond, ctx);
            try self.scanDiscrete(s.then_s, blk_tok, ctx);
            try self.scanDiscrete(s.else_s, blk_tok, ctx);
        },
        .case_stmt => |s| {
            try self.scanDiscreteExpr(s.scrutinee, ctx);
            for (s.arms) |arm| {
                for (arm.labels) |l| try self.scanDiscreteExpr(l, ctx);
                try self.scanDiscrete(arm.body, blk_tok, ctx);
            }
        },
        .for_stmt => |s| {
            try self.scanDiscrete(s.init, blk_tok, ctx);
            try self.scanDiscreteExpr(s.cond, ctx);
            try self.scanDiscrete(s.step, blk_tok, ctx);
            try self.scanDiscrete(s.body, blk_tok, ctx);
        },
        .while_stmt => |s| {
            try self.scanDiscreteExpr(s.cond, ctx);
            try self.scanDiscrete(s.body, blk_tok, ctx);
        },
        .repeat_stmt => |s| {
            try self.scanDiscreteExpr(s.count, ctx);
            try self.scanDiscrete(s.body, blk_tok, ctx);
        },
        .event_control => |s| {
            try self.scanDiscreteExpr(s.event, ctx);
            try self.scanDiscrete(s.body, blk_tok, ctx);
        },
        .sys_task => |s| for (s.args) |a| try self.scanDiscreteExpr(a, ctx),
        // A contribution or an indirect contribution in a discrete block is
        // §5.6's own "the analog context" rule, not one of the four above, and
        // the block has already been refused. Nothing to add.
        .empty, .contribute, .indirect, .event_trigger, .disable, .jump => {},
    }
}

/// Every expression reachable from a discrete statement. The child edges are the
/// per-tag column usage documented on `Ast.ExprTag`; the `args` whitelist is the
/// set of tags whose `extra` is an ExprId list offset — the others park a literal
/// value or a StrId list there, and reading them as expressions would walk
/// garbage.
fn scanDiscreteExpr(self: *Lower, e: Ast.ExprId, ctx: *DiscreteCtx) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    switch (tag) {
        // §4.5.15, verbatim: analog operators "can not be used inside an initial
        // or always block". Same code as the analog-function-body and
        // analog-initial cases, because it is the same sentence's family of
        // contexts: an operator carries state from one accepted timepoint to the
        // next, and none of these has a timepoint to advance.
        .filter_call => try self.errAt(e, .E0422, "not allowed in {s}", .{ctx.where}),
        .call => {
            const name = self.file.str(ex.strOf(e));
            if (ctx.funcs.contains(name)) {
                var b = self.errAtWith(e, .E0430);
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
    try self.scanDiscreteExpr(ex.lhs(e), ctx);
    try self.scanDiscreteExpr(ex.rhs(e), ctx);
    if (tag == .ternary) try self.scanDiscreteExpr(ex.ternaryElse(e), ctx);
    switch (tag) {
        .call,
        .builtin_call,
        .sys_call,
        .filter_call,
        .noise_call,
        .event_function,
        .concat,
        .assign_pattern,
        => for (ex.args(e)) |a| try self.scanDiscreteExpr(a, ctx),
        else => {},
    }
}

/// The continuous side of the same two sets: §7.2.2's both-contexts conflict on
/// an assignment target, and §5.2.1's digital read inside an `analog initial`.
/// Runs only in a module that HAS a discrete block, so the ordinary analog path
/// pays nothing.
fn scanContinuous(self: *Lower, id: Ast.StmtId, is_initial: bool, ctx: *DiscreteCtx) Oom!void {
    if (id == .none or ctx.assigned.count() == 0) return;
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .assign => |a| {
            var t = a.target;
            while (t != .none and (ex.tag(t) == .index or ex.tag(t) == .range)) t = ex.lhs(t);
            if (t != .none and ex.tag(t) == .ident) {
                const name = self.file.str(ex.strOf(t));
                if (ctx.assigned.get(name)) |dtok| {
                    var b = self.errAtWith(t, .E0432);
                    b.msg("`{s}`", .{name});
                    b.label(
                        self.tokenSpan(dtok),
                        "`{s}` is also assigned here, in the discrete context",
                        .{name},
                    );
                    try b.emit();
                }
            }
            try self.scanContinuousExpr(a.value, is_initial, ctx);
        },
        .block => |b| for (b.body) |s| try self.scanContinuous(s, is_initial, ctx),
        .if_stmt => |s| {
            try self.scanContinuousExpr(s.cond, is_initial, ctx);
            try self.scanContinuous(s.then_s, is_initial, ctx);
            try self.scanContinuous(s.else_s, is_initial, ctx);
        },
        .case_stmt => |s| {
            try self.scanContinuousExpr(s.scrutinee, is_initial, ctx);
            for (s.arms) |arm| {
                for (arm.labels) |l| try self.scanContinuousExpr(l, is_initial, ctx);
                try self.scanContinuous(arm.body, is_initial, ctx);
            }
        },
        .for_stmt => |s| {
            try self.scanContinuous(s.init, is_initial, ctx);
            try self.scanContinuousExpr(s.cond, is_initial, ctx);
            try self.scanContinuous(s.step, is_initial, ctx);
            try self.scanContinuous(s.body, is_initial, ctx);
        },
        .while_stmt => |s| {
            try self.scanContinuousExpr(s.cond, is_initial, ctx);
            try self.scanContinuous(s.body, is_initial, ctx);
        },
        .repeat_stmt => |s| {
            try self.scanContinuousExpr(s.count, is_initial, ctx);
            try self.scanContinuous(s.body, is_initial, ctx);
        },
        .event_control => |s| {
            try self.scanContinuousExpr(s.event, is_initial, ctx);
            try self.scanContinuous(s.body, is_initial, ctx);
        },
        .contribute => |s| try self.scanContinuousExpr(s.rhs, is_initial, ctx),
        .indirect => |s| try self.scanContinuousExpr(s.eqn, is_initial, ctx),
        .sys_task => |s| for (s.args) |a| try self.scanContinuousExpr(a, is_initial, ctx),
        .empty, .event_trigger, .disable, .jump => {},
    }
}

/// §5.2.1: "digital values cannot be accessed from the analog initial block as
/// they have not yet been assigned when the analog initial block is executed."
/// Only the READ is diagnosed, and only inside an `analog initial` — the same
/// read from the ordinary analog block is what §7.3.1 Table 7-1 is the
/// conversion table for.
fn scanContinuousExpr(self: *Lower, e: Ast.ExprId, is_initial: bool, ctx: *DiscreteCtx) Oom!void {
    if (e == .none or !is_initial) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (tag == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (ctx.assigned.get(name)) |dtok| {
            var b = self.errAtWith(e, .E0431);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(dtok), "`{s}` is assigned here, in the discrete context", .{name});
            try b.emit();
        }
    }
    try self.scanContinuousExpr(ex.lhs(e), is_initial, ctx);
    try self.scanContinuousExpr(ex.rhs(e), is_initial, ctx);
    if (tag == .ternary) try self.scanContinuousExpr(ex.ternaryElse(e), is_initial, ctx);
    switch (tag) {
        .call,
        .builtin_call,
        .sys_call,
        .filter_call,
        .noise_call,
        .event_function,
        .concat,
        .assign_pattern,
        => for (ex.args(e)) |a| try self.scanContinuousExpr(a, is_initial, ctx),
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
    // match in `checkAccessMatch`; see `isGeneric` there.
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
    if (self.natureAttrExpr(name, "abstol")) |v| {
        if (self.constEval(v)) |c| out.abstol = c.asReal();
    }
    if (self.natureAttrExpr(name, "access")) |v| {
        if (self.file.exprs.tag(v) == .ident) out.access = self.file.str(self.file.exprs.strOf(v));
    }
    if (self.natureAttrExpr(name, "units")) |v| {
        if (self.file.exprs.tag(v) == .str_literal) out.units = self.file.str(self.file.exprs.strOf(v));
    }
    return out;
}

/// §3.6.1.1: the value expression a (possibly derived) nature gives `attr`.
/// Lives on `Ast.SourceFile` because `ir/elaborate.zig` needs the same walk (see
/// `Flatten.primitiveAccess`) and it is a pure query over the parsed natures and
/// disciplines; this is the shorthand the rest of lowering was written against.
fn natureAttrExpr(self: *Lower, name: Ast.StrId, attr: []const u8) ?Ast.ExprId {
    return self.file.natureAttrExpr(name, attr);
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
    for (0..r.size()) |k|
        try self.applyDefaultDiscipline(try self.vecElem(name, r.at(@intCast(k))), main_tok);
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

/// Register (or find) a node. Undeclared names are implicit nets (§3.6.5), so
/// this never fails; registration order is source order ⇒ deterministic.
fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u16 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.node_disciplines.items[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx: u16 = @intCast(self.node_order.items.len);
    assert(idx != ground);
    try self.node_order.append(self.arena, name);
    try self.node_disciplines.append(self.arena, discipline);
    try self.node_dir.append(self.arena, .unspecified);
    try self.probe_cache.append(self.arena, .undef);
    gop.value_ptr.* = idx;
    return idx;
}

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
                try self.errAt(e, .E0351, "`{s}` is a vector [{d}:{d}]; name one element of it", .{ name, r.msb, r.lsb });
                return ground;
            }
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
                var b = self.errAtWith(e, .E0901);
                b.msg("`{s}` names no net in the elaborated design", .{name});
                try b.emit();
                return ground;
            }
            return self.internNode(name, "");
        },
        .index => {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) {
                try self.errAt(e, .E0306, "", .{});
                return ground;
            }
            const name = self.file.str(ex.strOf(base));
            const r = self.vectors.get(name) orelse {
                try self.errAt(e, .E0351, "`{s}` was not declared with a range", .{name});
                return ground;
            };
            // §5.5.2 "The index must be a constant expression, though it may
            // include genvar variables" — which `constEval` reads out of
            // `consts`, where `tryUnrollFor` binds the genvar of the enclosing
            // §5.9.3 `for` for the duration of each unrolled copy.
            const i = self.constEval(ex.rhs(e)) orelse {
                try self.errAt(e, .E0352, "index into `{s}` is not a constant expression", .{name});
                return ground;
            };
            if (!r.has(i.asInt())) {
                try self.errAt(e, .E0352, "`{s}` is [{d}:{d}], so {d} is not one of its elements", .{ name, r.msb, r.lsb, i.asInt() });
                return ground;
            }
            return self.internNode(try self.vecElem(name, i.asInt()), "");
        },
        else => {
            try self.errAt(e, .E0306, "", .{});
            return ground;
        },
    }
}

/// The scalarised name of one vector element. `p[0]` and not `p__0`: it is the
/// spelling the source uses, so a diagnostic, a `//!` operating-point binding
/// and the emitted `U` enum all name the same thing, and naming.zig's escape
/// makes it a legal Zig identifier without anybody choosing an encoding.
fn vecElem(self: *Lower, base: []const u8, i: i64) Oom![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ base, i });
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
        const hi = if (hv) |h| try self.internNode(try self.vecElem(h_name, h.at(@intCast(k))), "") else h_scalar;
        const lo = if (lv) |l| try self.internNode(try self.vecElem(l_name, l.at(@intCast(k))), "") else l_scalar;
        // §3.12 → §3.11 once, not `size` times: every element of a vector
        // branch pairs the same two DISCIPLINES, so the verdict is the same on
        // all of them and only the first has anything new to say.
        if (k == 0) try self.checkNetCompat(b.main_tok, hi, lo);
        try self.branches.put(self.arena, try self.vecElem(name, @intCast(k)), .{
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
/// `x[i]`; the parenthesised name cannot collide with an identifier.
fn flowUnknown(self: *Lower, hi: u16, lo: u16) Oom!u16 {
    const name = try std.fmt.allocPrint(self.arena, "flow({s},{s})", .{ self.nodeName(hi), self.nodeName(lo) });
    return self.internNode(name, "");
}

/// §5.4.3 the unknown carrying `I(<p>)`. Spelled `flow(<p>)` on purpose: it is
/// parenthesised (so no §2.7/§2.8.1 identifier can collide with it), it keeps
/// codegen's `flow(` prefix predicate — which classifies an unknown as a
/// CURRENT — correct with no change, and it can never be mistaken for a
/// `flow(a,b)` branch unknown (that form always has a comma).
fn portFlowUnknown(self: *Lower, p: u16) Oom!u16 {
    const name = try std.fmt.allocPrint(self.arena, "flow(<{s}>)", .{self.nodeName(p)});
    const u = try self.internNode(name, ""); // dedupes by name
    for (self.port_probes.items) |pp| {
        if (pp.port == p) return u;
    }
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

    // §3.4.4 array parameters are scalarized into `name[i]` entries.
    if (decl.dims.len != 0) return self.lowerParamArray(decl, name);

    const folded = self.constEval(decl.default);
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
    // elaboration and the dependent has to follow it. `elabConst` is precisely
    // the fold that refuses to look through a parameter, so it is the "may this
    // be baked into the model card?" test; `folded` above cannot be, for the
    // §6.6.1 reason. Codegen turns the surviving expression into `derive()`.
    const frozen = self.elabConst(decl.default);

    const default: Mir.Value = if (frozen) |c| switch (c) {
        .int => try self.iconst(c.asInt()),
        .real => try self.fconst(c.asReal()),
        .str => |s| try self.mir.addStrConst(self.arena, s),
    } else blk: {
        // `parameter real b = a*2;` where `a` is itself overridable: keep it as
        // an expression over other params.
        const tv = try self.lowerExpr(decl.default);
        break :blk if (astTy(ty) == .real) try self.toReal(tv) else tv.v;
    };

    try self.addParam(name, ty, default, folded, decl.ranges, decl.is_local, decl.main_tok);
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
    // A.2.5's string form is a SET, not an interval; §3.4.2 gives it its own
    // sentence and it needs string equality, not ordering. Unimplemented, and
    // silent rather than wrong.
    if (c == .str) return;
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
    try self.addParam(alias, .real, try self.fconst(1.0), .{ .real = 1.0 }, &.{}, false, Mir.no_tok);
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
        var b = self.errAtWith(decl.default, .E0349);
        b.msg("initialising array parameter `{s}`", .{name});
        b.help("write the list as an assignment pattern: `'{{ ... }}`", .{});
        try b.emit();
    }
    const elems = try self.flattenPattern(decl.default, dims);

    try self.arrays.put(self.arena, name, .{ .dims = dims, .ty = astTy(ty) });
    var sub: [8]i64 = undefined;
    for (elems, 0..) |elem, k| {
        const idx = if (dims.len <= sub.len) sub[0..dims.len] else try self.arena.alloc(i64, dims.len);
        shapeSubscripts(dims, k, idx);
        const default: Mir.Value = if (elem == .none)
            (if (astTy(ty) == .real) Mir.Value.f_zero else Mir.Value.zero)
            // §6.3.4 again: `elabConst`, not `constEval` — an element written
            // over another parameter tracks it exactly like a scalar default.
        else if (self.elabConst(elem)) |c|
            (if (astTy(ty) == .real) try self.fconst(c.asReal()) else try self.iconst(c.asInt()))
        else blk: {
            const tv = try self.lowerExpr(elem);
            break :blk if (astTy(ty) == .real) try self.toReal(tv) else tv.v;
        };
        // §3.4.4 an omitted element is the type's zero; anything else folds
        // through the declared defaults exactly as a scalar's does.
        const folded: ?Const = if (elem == .none)
            (if (astTy(ty) == .real) Const{ .real = 0 } else Const{ .int = 0 })
        else
            self.constEval(elem);
        try self.addParam(try self.elemName(name, idx), ty, default, folded, decl.ranges, decl.is_local, decl.main_tok);
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
    @memset(out, .none);
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
        b.* = .{ .lo = @min(x, y), .hi = @max(x, y) };
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
        out[i] = dims[i].lo + @as(i64, @intCast(rest % n));
        rest /= n;
    }
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

/// The one-dimensional spelling of the two above, for the many callers that
/// index a `[lo:hi]` array with a single subscript.
fn elemKey1(self: *Lower, buf: *[elem_key_len]u8, name: []const u8, i: i64) Oom![]const u8 {
    return self.elemKey(buf, name, &.{i});
}

// ---- §3.2 variables and scopes ---------------------------------------------

fn openScope(self: *const Lower) usize {
    return self.scope_log.items.len;
}

fn closeScope(self: *Lower, mark: usize) void {
    while (self.scope_log.items.len > mark) {
        const e = self.scope_log.pop().?;
        if (e.prev) |p| {
            self.vars.putAssumeCapacity(e.name, p);
        } else {
            _ = self.vars.remove(e.name);
        }
    }
}

/// Bind `name` to a fresh SSA place, remembering what it shadowed (§5.3.2).
fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot {
    const slot: VarSlot = .{ .place = self.builder.newPlace(), .ty = ty };
    try self.scope_log.append(self.arena, .{ .name = name, .prev = self.vars.get(name) });
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

/// Where a `declareVarDecl` sits. Only a MODULE-level variable can take a
/// persistent §5.10 slot — see `holdSlot`.
const VarScope = enum { module, local };

/// §3.2 declare and initialize. Verilog-AMS variables start at zero, so a read
/// on a path that never assigned is 0 rather than the SSA builder's `.undef`
/// (which codegen could not emit).
fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void {
    const name = self.file.str(decl.name);
    const ty = astTy(decl.ty);
    // §5.10. `.string` is deliberately excluded: a string never reaches the
    // residual (§3.3 strings only feed §9.4 tasks, which re-run every
    // evaluation anyway), so a persistent slot for one would be storage
    // nothing can observe.
    const hold = scope == .module and ty != .string and self.held_names.contains(name);

    if (decl.dims.len != 0) {
        const dims = try self.dimsBounds(decl.dims, decl.main_tok, name) orelse return;
        try self.arrays.put(self.arena, name, .{ .dims = dims, .ty = ty });
        // §3.3's own example is `string names[1:3] = '{"first","middle","last"}`:
        // the declaration takes an initializer exactly like the §3.4.4 array
        // PARAMETER does, and dropping it silently zeroed every element. The
        // pattern is positional over the declared range, so element k lands at
        // `dims[0].lo + k` — a 1:3 range puts "first" at index 1, not 0 — and
        // one list per dimension for a multidimensional array (§3.3, §3.4.8).
        const elems = try self.flattenPattern(decl.init, dims);
        var sub: [8]i64 = undefined;
        for (elems, 0..) |elem, k| {
            const idx = if (dims.len <= sub.len) sub[0..dims.len] else try self.arena.alloc(i64, dims.len);
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
                try self.holdSlot(en, ty, init_val, slot.place)
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
        try self.holdSlot(name, ty, init_val, slot.place)
    else
        init_val);
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
    const seed = try self.call(if (ty == .integer) "$held_int" else "$held_real", &.{try self.iconst(idx)});
    try self.held_vars.append(self.arena, .{
        .name = name,
        .ty = ty,
        .init = init_val,
        .seed = seed,
        .place = place,
    });
    return seed;
}

/// §5.10. Collect the names assigned inside an `@(<event>)` body, before any of
/// them is declared.
///
// ponytail: MODULE-level variables only. A variable declared in a §5.3.2 named
// block inside the analog block still resets — its declaration is lowered once
// per execution of the block, so a slot keyed on the source name would collide
// with itself under a §6.6.1 unrolled `for`. Upgrade path: key the slot on the
// SSA place and give each re-declaration a group-local ordinal, the same way
// `naming.assignDisambig` does for same-target units.
fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.analog) |blk| try self.scanHeld(blk.body, false);
}

/// One walk, two modes: outside an event body we are only looking for the
/// `@(...)`; inside one, every assignment target names a variable that has to
/// survive to the next evaluation.
fn scanHeld(self: *Lower, id: Ast.StmtId, in_event: bool) Oom!void {
    if (id == .none) return;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try self.scanHeld(s, in_event),
        .assign => |a| {
            if (!in_event) return;
            const ex = &self.file.exprs;
            // §3.2.2 `x[i] = …` holds the ARRAY; `declareVarDecl` scalarizes it.
            const t = if (ex.tag(a.target) == .index) ex.lhs(a.target) else a.target;
            if (ex.tag(t) != .ident) return;
            try self.held_names.put(self.arena, self.file.str(ex.strOf(t)), {});
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
        .disable => try self.lowerDisable(tok),
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
fn lowerDisable(self: *Lower, tok: u32) Oom!void {
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    return self.err(tok, .E0402, "", .{});
}

fn lowerStmts(self: *Lower, body: []const Ast.StmtId) Oom!void {
    for (body) |s| try self.lowerStmt(s);
}

/// §5.3.2 named sequential block: its declarations shadow for the block only.
fn lowerSeqBlock(self: *Lower, b: Ast.SeqBlock) Oom!void {
    const mark = self.openScope();
    defer self.closeScope(mark);
    for (b.params) |*p| try self.lowerParamDecl(p); // §5.3.2 local parameters
    try self.checkOneItemPerScope(b.vars);
    for (b.vars) |*v| try self.declareVarDecl(v, .local);
    try self.lowerStmts(b.body);
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
            var sub: [8]i64 = undefined;
            for (elems, 0..) |elem, k| {
                if (elem == .none) continue;
                const idx = if (info.dims.len <= sub.len) sub[0..info.dims.len] else try self.arena.alloc(i64, info.dims.len);
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
}

/// `a[i] = v` for a non-constant `i` over a one-dimensional array. True when it
/// was handled; false leaves the ordinary `resolveLvalue` path and its
/// diagnostics (a constant index, a multidimensional array, a non-array name).
///
/// Every element is rewritten as `select(i == k, v, a[k])`, so an index outside
/// the declared range writes nothing at all — §3.2.2 leaves that case undefined,
/// and dropping the write is the one answer that cannot corrupt a neighbour.
///
/// ponytail: N selects per assignment, so a loop over an N-element array is
/// O(N²) instructions. Fine at the sizes §3.2 arrays are written at (the LRM's
/// own examples are 2 and 4 elements) and the alternative is real memory in the
/// emitted device, which is the whole thing scalarization exists to avoid.
fn assignRuntimeIndex(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!bool {
    var subs: [8]Ast.ExprId = undefined;
    const chain = self.indexChain(target, &subs) orelse return false;
    if (chain.subs.len != 1) return false;
    if (self.constEval(chain.subs[0]) != null) return false;
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse return false;
    if (info.dims.len != 1) return false;

    const iv = try self.toInt(try self.lowerExpr(chain.subs[0]));
    const tv = try self.lowerExpr(value);
    const d = info.first();
    var key_buf: [elem_key_len]u8 = undefined;
    var i = d.lo;
    while (i <= d.hi) : (i += 1) {
        const slot = self.vars.get(try self.elemKey(&key_buf, name, &.{i})) orelse continue;
        const old = try self.builder.readVariable(slot.place, self.cur);
        const new = try self.coerceTo(value, slot.ty, tv);
        const c = try self.emit(.ieq, &.{ iv, try self.iconst(i) });
        try self.builder.writeVariable(slot.place, self.cur, try self.emit(.select, &.{ c, new, old }));
    }
    return true;
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
        var b = self.errAtWith(target, .E0429);
        b.msg("array `{s}` has {d} dimensions and `{s}` has {d}", .{
            dst_name, dst.dims.len, src_name, src.dims.len,
        });
        try b.emit();
        return true;
    }
    for (dst.dims, src.dims, 0..) |d, s, k| {
        if (d.count() == s.count()) continue;
        var b = self.errAtWith(target, .E0429);
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
        var b = self.errAtWith(target, .E0429);
        b.msg("array `{s}` holds `{s}` and `{s}` holds `{s}`", .{
            dst_name, @tagName(dst.ty), src_name, @tagName(src.ty),
        });
        try b.emit();
        return true;
    }

    var key_buf: [elem_key_len]u8 = undefined;
    var d_sub: [8]i64 = undefined;
    var s_sub: [8]i64 = undefined;
    const n = shapeCells(dst.dims);
    for (0..n) |k| {
        const di = if (dst.dims.len <= d_sub.len) d_sub[0..dst.dims.len] else try self.arena.alloc(i64, dst.dims.len);
        const si = if (src.dims.len <= s_sub.len) s_sub[0..src.dims.len] else try self.arena.alloc(i64, src.dims.len);
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
                var b = self.errAtWith(e, .E0312);
                b.msg("`{s}`", .{name});
                b.help("declare a `real` variable if the value changes during the solve", .{});
                try b.emit();
                return null;
            }
            var b = self.errAtWith(e, .E0313);
            b.msg("`{s}`", .{name});
            const near = diag.didYouMeanMap(self.arena, name, self.vars) orelse
                diag.didYouMeanMap(self.arena, name, self.param_index);
            if (near) |s| b.suggestHere(s);
            try b.emit();
            return null;
        },
        .index => {
            var subs: [8]Ast.ExprId = undefined;
            const chain = self.indexChain(e, &subs) orelse {
                try self.errAt(e, .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
                return null;
            };
            const name = self.file.str(chain.name);
            var idx: [8]i64 = undefined;
            const at = if (chain.subs.len <= idx.len) idx[0..chain.subs.len] else try self.arena.alloc(i64, chain.subs.len);
            for (chain.subs, at) |s, *o| {
                const c = self.constEval(s) orelse {
                    // ponytail: a runtime array index would need a select chain or
                    // real memory; every fixture indexes with a constant/genvar.
                    try self.errAt(e, .E0311, "indexing `{s}`", .{name});
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
            var b = self.errAtWith(e, .E0316);
            b.msg("a hierarchical name is not an assignment target", .{});
            b.note("§5.7: \"Hierarchical assignment of a variable from another scope/module is not allowed\"", .{});
            try b.emit();
            return null;
        },
        // A.6.3: `{a, b} = ...` is net_lvalue/variable_lvalue, a different
        // production from the §4.2.13 expression, and it is not in the analog
        // subset (annex C). Named so the message does not blame the rhs.
        .concat, .multi_concat => {
            try self.errAt(e, .E0317, "", .{});
            return null;
        },
        else => {
            try self.errAt(e, .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
            return null;
        },
    }
}

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, idx: []const i64) Oom!?VarSlot {
    const info = self.arrays.get(name) orelse {
        try self.errAt(e, .E0309, "`{s}`", .{name});
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
/// The chain is walked from the OUTSIDE in (`.index` nests to the left), so the
/// subscripts come out reversed and are flipped once, in place.
const IndexChain = struct { name: Ast.StrId, subs: []const Ast.ExprId };
fn indexChain(self: *const Lower, e: Ast.ExprId, buf: []Ast.ExprId) ?IndexChain {
    const ex = &self.file.exprs;
    var n: usize = 0;
    var cur = e;
    while (ex.tag(cur) == .index) {
        if (n == buf.len) return null; // deeper than any legal declaration here
        buf[n] = ex.rhs(cur);
        n += 1;
        cur = ex.lhs(cur);
    }
    if (ex.tag(cur) != .ident or ex.strOf(cur) == .none) return null;
    std.mem.reverse(Ast.ExprId, buf[0..n]);
    return .{ .name = ex.strOf(cur), .subs = buf[0..n] };
}

/// §3.2: a reference supplies one subscript per declared dimension. Separate
/// from the range check below because a runtime subscript has a COUNT but no
/// value — and a caller that checked only the range would read `flag_array[3]`,
/// a whole ROW, as if it were a scalar.
fn checkSubscriptCount(self: *Lower, e: Ast.ExprId, name: []const u8, info: ArrayInfo, n: usize) Oom!bool {
    if (n == info.dims.len) return true;
    var b = self.errAtWith(e, .E0356);
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
        try self.errAt(e, .E0310, "index {d} is outside dimension {d} of `{s}[{d}:{d}]`", .{
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
        try self.errAt(lhs, .E0405, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Contribution statements cannot be used inside an event control
    // block because it can generate discontinuity in analog signals"; A.6.4
    // `analog_event_statement` states it structurally.
    if (self.in_event_stmt) {
        try self.errAt(lhs, .E0406, "", .{});
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
        try self.errAt(lhs, .E0426, "", .{});
        return;
    }
    const ex = &self.file.exprs;
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+." (§4.4 says the same of branch assignment.)
    if (ex.tag(lhs) == .port_access) {
        var b = self.errAtWith(lhs, .E0407);
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        _ = try self.lowerExpr(rhs);
        return;
    }
    if (ex.tag(lhs) != .branch_access) {
        try self.errAt(lhs, .E0408, "", .{});
        _ = try self.lowerExpr(rhs);
        return;
    }
    try self.checkZeroTransitionZFilter(rhs);
    const target = try self.branchOf(lhs) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot be
    // contributed to using the branch contribution operator <+."
    if (self.indirectOn(target.hi, target.lo)) {
        var b = self.errAtWith(lhs, .E0409);
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
        var b = self.errAtWith(lhs, .E0425);
        b.msg("`{s}` is an `input` port of discipline `{s}`", .{ self.node_order.items[n], self.node_disciplines.items[n] });
        try b.emit();
        return;
    }
    if (target.access == .flow) try self.checkMfactorDoubleScaling(lhs, rhs);
    const idx = try self.contribIndex(target, self.file.exprs.mainTok(lhs));

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
    // §4.6.4 the noise kind belongs to the target, not to one statement.
    if (self.noiseKindOf(rhs)) |k| self.contributions.items[idx].noise_kind = k;
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
    var b = self.errAtWith(lhs, .E0912);
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
    var b = self.errAtWith(rhs, .E0518);
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
    try self.errAt(lhs, .E0424, "{s}", .{
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
        try self.errAt(lhs, .E0410, "not allowed in {s}", .{ctx});
        return;
    }
    if (self.in_event_stmt) {
        try self.errAt(lhs, .E0411, "", .{});
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
        try self.errAt(lhs, .E0413, "", .{});
        return;
    }
    // §5.6.7 "The left-hand side of the equality operator must either be an
    // access function, or ddt, idt or idtmod applied to an access function."
    if (!self.isIndirectProbe(probe_e)) {
        var b = self.errAtWith(probe_e, .E0414);
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
        var b = self.errAtWith(lhs, .E0415);
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
fn branchKey(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        .index => blk: {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) break :blk null;
            const i = self.constEval(ex.rhs(e)) orelse break :blk null;
            break :blk try self.vecElem(self.file.str(ex.strOf(base)), i.asInt());
        },
        else => null,
    };
}

/// The port a §3.12.1 port branch names, when the single argument of an access
/// function is one. `null` for everything else, including a two-argument
/// access — a port branch is a name, never a pair.
fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u16 {
    if (self.file.exprs.rhs(e) != .none) return null;
    const key = try self.branchKey(self.file.exprs.lhs(e)) orelse return null;
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
        var b = self.errAtWith(e, .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(self.arena, name, self.access_kind)) |s|
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
        var b = self.errAtWith(e, .E0407);
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
        if (try self.branchKey(first)) |key| {
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
        var b = self.errAtWith(e, .E0315);
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

fn isGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, generic_potential) or std.mem.eql(u8, name, generic_flow);
}

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
        var b = self.errAtWith(e, .E0337);
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
        var b = self.errAtWith(e, .E0501);
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
    if (isGeneric(name)) return;
    var b = self.errAtWith(e, .E0501);
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
    });
    const acc: Accum = .{ .resist = self.builder.newPlace(), .react = self.builder.newPlace() };
    // Seeded in the entry block, which dominates everything: a contribution
    // that only happens on one arm of an `if` reads 0 on the other (§5.8).
    try self.builder.writeVariable(acc.resist, .entry, .f_zero);
    try self.builder.writeVariable(acc.react, .entry, .f_zero);
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
/// ponytail: under a conditional the discard survives as a phi rather than a
/// constant, so an arm that discards a POTENTIAL leaves a zero potential source
/// (a short) instead of no source. Fixing that means making the ROW itself
/// switchable at run time, i.e. implementing §5.6.5's switch branch in codegen,
/// which VerA does not do for the plain `if (c) V(p,n) <+ 0;` shape either.
fn discardOpposite(self: *Lower, t: Target) Oom!void {
    const other: Access = if (t.access == .potential) .flow else .potential;
    for (self.contributions.items, self.accum.items) |c, acc| {
        if (c.kind != .direct or c.access != other or c.hi != t.hi or c.lo != t.lo) continue;
        // §5.6.1.3 is stated of "a branch", so only the OTHER quantity of THIS
        // branch is discarded. A parallel named branch over the same pair is a
        // different source and keeps what it retained.
        if (c.br != t.br) continue;
        try self.builder.writeVariable(acc.resist, self.cur, .f_zero);
        try self.builder.writeVariable(acc.react, self.cur, .f_zero);
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
        const v = try self.lowerReactive(e) orelse return;
        try self.accumulate(&out.react, v, negate);
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

/// The charge/flux of a reactive term: strip exactly one `ddt` from a
/// multiplicative spine (§5.6.1.2).
fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
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
                    try self.errAt(e, .E0502, "", .{});
                    return null;
                }
                // args[1] (abstol/nature, §4.5.3) only affects tolerance, so
                // it is not lowered — but it still has to be LEGAL, on the same
                // grounds as the E0502 agreement above: this spine bypasses
                // `lowerFilter`, where §5.5.3's ban on a non-constant attribute
                // reference is otherwise reached through `lowerExpr`.
                if (args.len > 1) _ = try self.lowerAbstolArg(args[1]);
                return try self.toReal(try self.lowerExpr(args[0]));
            }
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return self.lowerReactive(ex.lhs(e)),
            .minus => {
                const v = try self.lowerReactive(ex.lhs(e)) orelse return null;
                return try self.emit(.fneg, &.{v});
            },
            else => {},
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                const l_has = self.containsDdt(ex.lhs(e));
                const r_has = self.containsDdt(ex.rhs(e));
                if (l_has and r_has) break :spine;
                if (l_has) {
                    const a = try self.lowerReactive(ex.lhs(e)) orelse return null;
                    const b = try self.toReal(try self.lowerExpr(ex.rhs(e)));
                    return try self.emit(.fmul, &.{ a, b });
                }
                const a = try self.toReal(try self.lowerExpr(ex.lhs(e)));
                const b = try self.lowerReactive(ex.rhs(e)) orelse return null;
                return try self.emit(.fmul, &.{ a, b });
            },
            .div => {
                if (self.containsDdt(ex.rhs(e))) break :spine; // ddt in a divisor
                const a = try self.lowerReactive(ex.lhs(e)) orelse return null;
                const b = try self.toReal(try self.lowerExpr(ex.rhs(e)));
                return try self.emit(.fdiv, &.{ a, b });
            },
            else => {},
        },
        else => {},
    }
    var b = self.errAtWith(e, .E0503);
    b.help("assign the derivative to a variable, then use that variable in the contribution", .{});
    try b.emit();
    return null;
}

/// §4.6.4 the small-signal noise source a contribution carries, if any.
fn noiseKindOf(self: *const Lower, e: Ast.ExprId) ?NoiseKind {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a STIMULUS,
            // not a noise source; listing it in `noise_gens` would invent a
            // noise generator the model never declared.
            if (std.mem.eql(u8, n, "ac_stim")) return null;
            // §4.6.4.2 flicker_noise; every other source is white (§4.6.4.1).
            return if (std.mem.eql(u8, n, "flicker_noise")) .flicker else .thermal;
        },
        .call, .builtin_call, .sys_call, .filter_call => {
            for (ex.args(e)) |a| if (self.noiseKindOf(a)) |k| return k;
            return null;
        },
        else => {
            if (self.noiseKindOf(ex.lhs(e))) |k| return k;
            return self.noiseKindOf(ex.rhs(e));
        },
    }
}

// ---------------------------------------------------------------------------
// Class 4 — control flow (LRM §5.8, §5.9)
// ---------------------------------------------------------------------------

/// §6.6: "All expressions in generate schemes shall be constant expressions,
/// deterministic at elaboration time." The scheme of an if-generate is its
/// condition and of a case-generate its selector; the loop generate's three
/// parts are E0417-E0419, judged in `tryUnrollFor` where the unroll needs them.
///
/// `constEval`, NOT `elabConst`: a `parameter` is a `constant_primary` (A.8.4)
/// and §6.6's stated purpose is "the ability for parameter values to affect the
/// structure of the model", so a parameterized scheme is exactly what the clause
/// is for. What it excludes is a module variable or anything reading the
/// solution — the things `constEval` returns null for.
///
/// Reported and then lowered anyway: a scheme VerA cannot fold is still lowered
/// as the §5.8 runtime branch it looks like, so a second mistake inside the
/// selected arm is reported in the same run.
///
/// ponytail: a scheme this accepts is not necessarily FOLDED. `elabConst` keeps
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
    if (self.elabConst(cond)) |c| {
        return self.lowerStmt(if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try self.lowerExpr(cond));
    try self.lowerBranchStmt(c, then_s, else_s, self.isAnalysisOrConst(cond));
}

/// §5.10 the same diamond, but the condition is already a Value (event guards)
/// — and an event's `hit` flag is the definition of a condition that changes
/// during the solve, so it is never static.
fn lowerGuarded(self: *Lower, cond: Mir.Value, body: Ast.StmtId) Oom!void {
    try self.lowerBranchStmt(cond, body, .none, false);
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
/// Deliberately NOT `elabConst`: that folds to a VALUE and refuses a parameter
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
    const then_b = try self.newBlock();
    const else_b = try self.newBlock();
    const join = try self.newBlock();

    _ = try self.mir.emitBranch(self.arena, self.cur, cond, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    try self.builder.sealBlock(else_b);

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

    const then_b = try self.newBlock();
    const else_b = try self.newBlock();
    const join = try self.newBlock();
    _ = try self.mir.emitBranch(self.arena, self.cur, cond.?, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    try self.builder.sealBlock(else_b);

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
    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.newBlock();
    const exit = try self.newBlock();
    // `self.cur`, NOT `header`: a §4.2.7 short-circuit (`while (i<=4 && f(x))`)
    // splits the condition across blocks of its own and leaves `cur` at the
    // join. Branching from `header` regardless appended a SECOND terminator to
    // a block that already ended in the `&&`'s branch — the join and the rhs
    // block then had no predecessor, codegen never emitted them, and the loop
    // branched on a temporary nothing ever assigned. Same hazard as `?:` in a
    // condition. Pinned by codegen.zig's test "§5.9.1 a short-circuit loop
    // condition still reaches the loop's branch".
    _ = try self.mir.emitBranch(self.arena, self.cur, c, body_b, exit);
    try self.builder.addPredecessor(body_b, self.cur);
    try self.builder.addPredecessor(exit, self.cur);
    try self.builder.sealBlock(body_b);

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

    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.newBlock();
    const step_b = try self.newBlock();
    const exit = try self.newBlock();
    _ = try self.mir.emitBranch(self.arena, header, c, body_b, exit);
    try self.builder.addPredecessor(body_b, header);
    try self.builder.addPredecessor(exit, header);
    try self.builder.sealBlock(body_b);

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
    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.newBlock();
    const step_b = try self.newBlock();
    const exit = try self.newBlock();
    // `self.cur`, not `header` — see `lowerWhile`: the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    _ = try self.mir.emitBranch(self.arena, self.cur, c, body_b, exit);
    try self.builder.addPredecessor(body_b, self.cur);
    try self.builder.addPredecessor(exit, self.cur);
    try self.builder.sealBlock(body_b);

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
        try self.errAt(cond, .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    try self.consts.put(self.arena, gv, start);

    var n: u32 = 0;
    while (n < max_unroll) : (n += 1) {
        const c = self.constEval(cond) orelse {
            try self.errAt(cond, .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        try self.lowerStmt(body);
        const next = self.constEval(self.assignValueOf(step) orelse .none) orelse {
            try self.errAt(cond, .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    if (n == max_unroll)
        try self.errAt(cond, .E0420, "gave up after {d} iterations", .{max_unroll});
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
        try self.errAt(event, .E0702, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Nested event control statements are not allowed" — and A.6.4
    // agrees: `analog_event_statement` has no
    // `analog_event_control_statement` alternative.
    if (self.in_event_stmt) {
        try self.errAt(event, .E0703, "", .{});
        return;
    }
    // §5.8 "Event control statements (e.g.: timer, cross) cannot be used inside
    // conditional statements unless the conditional expression is a constant
    // expression"; §5.9 bans them in repeat/while/non-genvar for outright;
    // §5.10.3.1 repeats it for `cross`. STRICTER than E0514 on purpose — the
    // carve-out here is a constant expression, so `analysis("dc")` does not
    // license it and `static_cond_depth` is deliberately not consulted.
    if (self.cond_depth != 0) {
        var b = self.errAtWith(event, .E0707);
        b.help("put `@(...)` on the spine and make the statement it guards conditional", .{});
        try b.emit();
    }
    const cond = try self.lowerEventExpr(event) orelse return;
    const prev = self.in_event_stmt;
    self.in_event_stmt = true;
    defer self.in_event_stmt = prev;
    try self.lowerGuarded(cond, body);
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
                try self.errAt(e, .E0513, "", .{});
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
            try self.errAt(e, .E0704, "", .{});
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
            try self.errAt(e, .E0705, "`{s}`", .{name});
            return null;
        },
        else => {
            try self.errAt(e, .E0706, "", .{});
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
                try self.errAt(args[d], .E0517, "`cross()` direction shall evaluate to an integer, got {d}", .{v});
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
        try self.errAt(args[i], .E0517, "`{s}()` {s} shall be non-negative, got {d}", .{
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
            var b = self.errAtWith(e, .E0517);
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
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args) |a| {
        if (a == .none) continue; // A.6.9 empty argument slot
        try vals.append(self.arena, try self.lowerSysArg(a));
    }
    const v = try self.call(name, vals.items);
    if (isFileOutTask(name)) {
        self.uses_file_tasks = true;
        // The §9.4.3 formatter renders into a scratch row before the write, so a
        // module with a §9.5.2 output task needs the string kernels too.
        self.uses_str_tasks = true;
    }
    if (isDisplayTask(name) or isFileOutTask(name)) try self.displays.append(self.arena, .{
        .val = v,
        .name = name,
        .tok = tok,
        .conditional = self.cond_depth != 0,
    });
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
        return try self.iconst(0);
    }
    const fd = try self.lowerSysArg(args[fd_at]);
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
    if (scan and fmt == null) return try self.iconst(0);

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
                try self.errAt(a, .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
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
        const v = try self.call(callee, &.{ n, fd, fmt.?, try self.iconst(item) });
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
        "$fopen", "$fgets", "$fscanf", "$ftell",
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
        try self.errAt(args[0], .E0813, "`{s}` writes into a `string` variable, and this one is {s}", .{ name, @tagName(slot.ty) });
        return;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // Types are preserved, not coerced: the conversion `cg_display.appendConv`
    // picks depends on the operand's own type (§9.4.3 `%d` on a real is a
    // §4.2.1.1 conversion, `%s` on a string is the text).
    for (args[1..]) |a| {
        if (a == .none) continue;
        try vals.append(self.arena, (try self.lowerExpr(a)).v);
    }
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
        return self.iconst(0);
    }
    const src = (try self.lowerExpr(args[0])).v;
    const fmt = (try self.lowerExpr(args[1])).v;
    // Only a literal format can be checked, and only a literal one is worth
    // checking: a conversion code the scanner does not implement would consume
    // nothing and still be counted, so the model would read a plausible number.
    if (self.constEval(args[1])) |c| switch (c) {
        .str => |s| if (try self.checkScanFormat(tok, s)) return self.iconst(0),
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
        const v = try self.call(callee, &.{ src, fmt, try self.iconst(item) });
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
/// §9.13.1/§9.13.2 state for it.
const Dist = struct {
    /// Source spelling, `$` included.
    name: []const u8,
    /// `rng_kernels.zig` entry point, or "" for the two whose only argument is
    /// the seed (`$random`/`$arandom`, handled by `$rng$rand`).
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
    .{ .name = "$dist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_t", .kernel = "$rng$t", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .integer, .positive = 0b11 },
    // §9.13.2, the real family.
    .{ .name = "$rdist_uniform", .kernel = "$rng$uniform", .nparam = 2, .ty = .real, .ordered = true },
    .{ .name = "$rdist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .real },
    .{ .name = "$rdist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_t", .kernel = "$rng$t", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .real, .positive = 0b11 },
};

fn distOf(name: []const u8) ?*const Dist {
    for (&dists) |*d| if (std.mem.eql(u8, name, d.name)) return d;
    return null;
}

/// The name §9.13.2 gives parameter `i` of `d`, for the diagnostics.
fn distParamName(d: *const Dist, i: usize) []const u8 {
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
    // `type_string` ("instance" or "global") selects which paramset override the
    // stream belongs to, and there is no paramset here — §6.4 paramsets are a
    // separate compilation unit and VerA compiles a module. So a string in the
    // last slot is a scope error, not an unsupported argument.
    if (given.items.len > 0) {
        const last = given.items[given.items.len - 1];
        if (ex.tag(last) == .str_literal) {
            try self.errAt(last, .E0816, "`{s}`'s `type_string` argument is only meaningful within a paramset (§6.4)", .{name});
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
            try self.errAt(sa, .E0816, "the seed argument shall be an integer, and this one is {s}", .{@tagName(tv.ty)});
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
        const latch = try self.call("$rng$auto", &.{try self.iconst(site)});
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
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, seed);
    for (given.items[@min(1, given.items.len)..], 0..) |a, i| {
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, try self.toReal(tv));
        // Only a folded argument can be judged; a runtime one is the host's
        // problem, and §9.13.2 gives the kernels a defined answer either way.
        const c = self.constEval(a) orelse continue;
        if (c == .str) continue;
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and c.asReal() <= 0)
            try self.errAt(a, .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{
                name, distParamName(d, i), c.asReal(),
            });
    }
    if (d.ordered and vals.items.len == 3) {
        const lo = self.constEval(given.items[1]);
        const hi = self.constEval(given.items[2]);
        if (lo != null and hi != null and lo.? != .str and hi.? != .str and
            lo.?.asReal() >= hi.?.asReal())
        {
            var b = self.errAtWith(given.items[1], .E0816);
            b.msg("the start value shall be smaller than the end value, got {d} and {d}", .{ lo.?.asReal(), hi.?.asReal() });
            b.note("§9.13.2: start and end \"bound the values returned\", and an interval with start above end is empty", .{});
            try b.emit();
        }
    }

    // ---- the two calls ------------------------------------------------------
    const v = try self.call(d.kernel, vals.items);
    // §9.13.1/§9.13.2: "a value is passed to the function and A DIFFERENT VALUE
    // IS RETURNED. The variable is initialized by the user and only updated by
    // the system function." Written AFTER the variate is computed, so both read
    // the same incoming seed however the two calls end up ordered in the MIR.
    if (write_back) |s| {
        const next = try self.call("$rng$next", &.{seed});
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
                try self.errAt(args[0], .E0803, "got {d}", .{c.asReal()});
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
                try self.errAt(real_args[0], .E0805, "", .{});
                return true;
            };
            degree = c.asInt();
        }
        // §9.17.1 "A special form of the $discontinuity task, $discontinuity(-1),
        // is used with the $limit() function". VerA leaves the limiting
        // ALGORITHM to the host (codegen renders `$limit` as its own argument),
        // so there is no -1 announcement to make and dropping it here is exact —
        // it is not a substitute value, it is the whole content of the request.
        if (degree < 0) return true;
        const p = try self.kernelCtlPlace(&self.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.fconst(@floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

// THE "DELIBERATELY UNSUPPORTED" LIST IS GONE, and with it E0801 (retired).
//
// It held two families and both left for the same reason — the LRM defines them
// for the analog context, so refusing them refused a conforming source. §9.13's
// 17 probabilistic names went first: a draw that changes between Newton
// iterations would make the residual non-deterministic, but §9.13.1's seed is an
// inout argument ("a value is passed to the function and a different value is
// returned"), so a variate is a pure function of the seed and is fixed across the
// iterations at one point by construction (`lowerRandom`, `rng_kernels.zig`).
// §9.16's `$simprobe` went second: Table 9-13 marks it analog-context Yes and the
// clause fixes what an unresolvable probe returns, which is a value and not an
// error whenever the fallback is supplied (`lowerSimprobe`).
//
// An empty list is a diagnostic that cannot fire, so the list and the code went
// rather than sitting here as one. A function this compiler genuinely cannot host
// gets a code that says which rule it broke — E0806 for a digital-only name,
// E0817 for an unresolvable probe — not a capability class.

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
        "$driver_count",      "$receiver_count",       "$driver_state",
        "$driver_strength",
        // §9.23.1–§9.23.4, the supplementary pending-event queries.
        "$driver_delay",      "$driver_next_state",
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
        .int_literal => return .{ .v = try self.iconst(ex.intValue(e)), .ty = .integer }, // §2.6.1
        .real_literal => return .{ .v = try self.fconst(ex.realValue(e)), .ty = .real }, // §2.6.2
        .str_literal => return .{
            .v = try self.mir.addStrConst(self.arena, self.file.str(ex.strOf(e))),
            .ty = .string,
        }, // §2.7
        // A.2.5 — only legal inside a value range, which proof.zig reads from
        // the AST directly; lowering one is harmless.
        .pos_inf => return .{ .v = .f_inf, .ty = .real },
        .neg_inf => return .{ .v = try self.fconst(-std.math.inf(f64)), .ty = .real },

        .ident => return self.lookupIdent(e),
        .hier_ident => {
            // §5.5.3 Syntax 5-4 first: a nature attribute reference is a
            // CONSTANT this module can resolve, unlike a §6.8 hierarchical name,
            // which needs an instance tree (E0901).
            if (self.natureAttrRef(e)) |r| switch (r) {
                .value => |c| return switch (c) {
                    .real, .int => .{ .v = try self.fconst(c.asReal()), .ty = .real },
                    .str => .{ .v = try self.mir.addStrConst(self.arena, c.str), .ty = .string },
                },
                .banned => |attr| {
                    var b = self.errAtWith(e, .E0359);
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
            if (self.vars.contains(name)) {
                var vb = self.errAtWith(e, .E0910);
                vb.msg("`{s}`", .{name});
                vb.note("§6.7.1 permits a hierarchical parameter, branch probe or analog function; a variable is the one entry on that list it forbids", .{});
                try vb.emit();
                return poison;
            }
            if (self.param_index.contains(name) or
                self.consts.contains(name) or self.node_voltages.contains(name))
                return self.lookupName(e, name);
            var b = self.errAtWith(e, .E0901);
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
            try self.errAt(e, .E0509, "", .{});
            return poison;
        },
        .range => {
            try self.errAt(e, .E0329, "", .{});
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
            try self.errAt(e, .E0701, "", .{});
            return poison;
        },
    }
}

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `select` chain over them (the array is
/// scalarized, so there is no memory to index).
fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    var subs: [8]Ast.ExprId = undefined;
    const chain = self.indexChain(e, &subs) orelse {
        try self.errAt(e, .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    };
    const name = self.file.str(chain.name);
    const info = self.arrays.get(name) orelse {
        try self.errAt(e, .E0309, "`{s}`", .{name});
        return poison;
    };

    var idx: [8]i64 = undefined;
    const at = if (chain.subs.len <= idx.len) idx[0..chain.subs.len] else try self.arena.alloc(i64, chain.subs.len);
    var all_const = true;
    for (chain.subs, at) |s, *o| {
        if (self.constEval(s)) |c| o.* = c.asInt() else all_const = false;
    }
    if (!try self.checkSubscriptCount(e, name, info, at.len)) return poison;
    if (all_const) {
        if (!try self.checkSubscripts(e, name, info, at)) return poison;
        return (try self.arrayElemValue(name, at)) orelse poison;
    }

    // Runtime index: fold from the top down so element `lo` is the fallback.
    // An out-of-range index yields element `lo` (§3.2.2 leaves it undefined).
    //
    // ponytail: one dimension only. A multidimensional runtime index would fold
    // a select chain over the whole cartesian product — every cell tested with a
    // conjunction of subscript comparisons — and no fixture writes one; §3.2's
    // own examples index a multidimensional array with literals. `for (i…) a[i]`
    // (§4.7.1's `arrayadd`) is the shape that needs the chain, and it is flat.
    if (info.dims.len != 1) {
        try self.errAt(e, .E0311, "indexing the multidimensional array `{s}`", .{name});
        return poison;
    }
    const d = info.first();
    const iv = try self.toInt(try self.lowerExpr(chain.subs[0]));
    var acc: ?TypedValue = null;
    var i = d.hi;
    while (true) : (i -= 1) {
        const el = (try self.arrayElemValue(name, &.{i})) orelse return poison;
        if (acc) |a| {
            const ty = unify(el.ty, a.ty);
            const c = try self.emit(.ieq, &.{ iv, try self.iconst(i) });
            const ev = if (ty == .real) try self.toReal(el) else el.v;
            const av = if (ty == .real) try self.toReal(a) else a.v;
            acc = .{ .v = try self.emit(.select, &.{ c, ev, av }), .ty = ty };
        } else {
            acc = el;
        }
        if (i == d.lo) break;
    }
    return acc orelse poison;
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
        try self.errAt(e, .E0326, "", .{});
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
                try self.errAt(ex.lhs(e), .E0328, "", .{});
                return poison;
            },
        };
        // §4.2.13: the replication constant is "non-negative, non-x and
        // non-z". Zero is legal and yields the empty string.
        if (copies < 0) {
            try self.errAt(ex.lhs(e), .E0327, "a replication constant shall be non-negative, got {d}", .{copies});
            return poison;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (elems) |el| {
        const tv = try self.lowerExpr(el);
        if (tv.ty != .string) {
            try self.errAt(e, .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            else => {
                try self.errAt(e, .E0328, "", .{});
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
fn lookupIdent(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    return self.lookupName(e, self.file.str(self.file.exprs.strOf(e)));
}

/// Same resolution, for a name that is not the node's own `str`: §6.7's dotted
/// path, joined by `flatName`. Split out rather than parameterised in place so
/// the hierarchical read gets the identical shadowing order and the identical
/// diagnostics — E0315's "probe it" advice is as true of `u.a` as of `a`.
fn lookupName(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!TypedValue {
    if (self.vars.get(name)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.iconst(c.asInt()), .ty = .integer },
        .real => .{ .v = try self.fconst(c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errAtWith(e, .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errAtWith(e, .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(self.arena, name, self.vars) orelse
        diag.didYouMeanMap(self.arena, name, self.param_index) orelse
        diag.didYouMeanMap(self.arena, name, self.node_voltages) orelse
        diag.didYouMeanMap(self.arena, name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
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
                    return .{ .v = try self.iconst(-x), .ty = a.ty },
                .float_const => |x| return .{ .v = try self.fconst(-x), .ty = a.ty },
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
                try self.errAt(e, .E0318, "`~` on a {s}", .{@tagName(a.ty)});
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
                try self.errAt(e, .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            try self.errAt(e, .E0348, "", .{});
            return poison;
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode (annex C).
        .reduce_xor, .reduce_xnor => {
            try self.errAt(e, .E0320, "", .{});
            return poison;
        },
    }
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
fn lowerBinary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const op = ex.binOp(e);

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
                try self.errAt(e, .E0321, "", .{});
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
                try self.errAt(e, .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
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
            var d = self.errAtWith(e, .E0323);
            d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
            try d.emit();
            return poison;
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errAtWith(e, .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        else => {
            try self.errAt(e, .E0325, "`{s}`", .{@tagName(op)});
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

    const then_b = try self.newBlock();
    const else_b = try self.newBlock();
    const join = try self.newBlock();
    _ = try self.mir.emitBranch(self.arena, self.cur, c, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    try self.builder.sealBlock(else_b);

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

    const rhs_b = try self.newBlock();
    const join = try self.newBlock();
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
        try self.errAt(e, .E0421, "not allowed in {s}", .{ctx});
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
            // the read is the ACCUMULATOR, read at THIS point in the block.
            // §5.6.1.2 states retention sequentially ("adds the value of the
            // right-hand side to any previously retained value", the assignment
            // being made at the end of the simulation cycle), so a read placed
            // before the first `<+` must still see nothing retained;
            // `readVariable` at `self.cur` is exactly that, and §5.8's
            // conditional arms come out as its phis with nothing written here.
            //
            // Only once a flow contribution has ALREADY been lowered onto this
            // pair, which is the distinction the clause draws: an uncontributed
            // branch is a §5.4.2.1 flow PROBE — a short whose current is a
            // genuine unknown of the solve — and a POTENTIAL source's branch
            // current is pinned by the branch row codegen emits for it. Both of
            // those keep the unknown and read it.
            if (self.flowAccum(t)) |acc| {
                // ponytail: the resistive half only. A reactive flow
                // contribution retains a CHARGE (§5.6.1.2 strips the `ddt`), so
                // reading the branch flow back would have to differentiate it
                // again; that needs a second `ddt` operator instance and no
                // fixture reads the current of a capacitive branch.
                const v = try self.builder.readVariable(acc.resist, self.cur);
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
        try self.errAt(e, .E0421, "not allowed in {s}", .{ctx});
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
        var b = self.errAtWith(e, .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(self.arena, name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.errAt(e, .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.num_ports) {
        var b = self.errAtWith(e, .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, self.nodeName(p) });
        if (diag.didYouMeanMap(self.arena, self.nodeName(p), self.node_voltages)) |s|
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
    var b = self.errAtWith(e, .E0512);
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
    try self.errAt(e, .E0506, "`{s}()` takes {d}", .{ name, want });
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
        try self.errAt(e, .E0422, "not allowed in {s}", .{ctx});
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
        var b = self.errAtWith(e, .E0514);
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
            try self.errAt(e, .E0504, "", .{});
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
            try self.errAt(args[1], .E0504, "a potential across two nets is not one unknown", .{});
            return poison;
        }
        const u: u16 = switch (t.access) {
            .potential => t.hi,
            .flow => try self.flowUnknown(t.hi, t.lo),
        };
        const d = try self.call("ddx", &.{ f, try self.iconst(u) });
        // §1.3.1.2 again: `ddx(f, I(n,p))` differentiates with respect to the
        // negation of the one canonical unknown, so the derivative negates too.
        // A potential probe reaches here only in the single-net form, which the
        // check above enforces and which is never reversed.
        return .{ .v = if (t.neg) try self.emit(.fneg, &.{d}) else d, .ty = .real };
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
                try vals.append(self.arena, try self.iconst(0));
                continue;
            }
            try self.errAt(e, .E0505, "`{s}()`", .{name});
            return poison;
        }
        // A.8.3 `abstol_expression ::= constant_expression | nature_identifier`.
        // The second arm is the ONLY place a nature name is a value, so it is
        // resolved here and not in `lookupIdent`: natures and disciplines share
        // one global scope (§3.13.1), and letting that scope answer general
        // identifier lookup would shadow every variable named after a nature.
        if (abstol_slot == i) {
            if (self.natureAbstol(a)) |t| {
                try vals.append(self.arena, try self.fconst(t));
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
    const d = for (self.file.disciplines) |*x| {
        if (std.mem.eql(u8, self.file.str(x.name), dname)) break x;
    } else return null;
    const nat = if (is_potential) d.potential else d.flow;
    if (nat == .none) return null;
    const v = self.natureAttrExpr(nat, attr) orelse return .{ .banned = attr };
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
        try self.errAt(args[r.i], .E0516, "`{s}()` argument `{s}` shall be {s}, got {d}", .{ name, r.arg, r.want.word(), v });
    }

    // §4.5.10: "The optional direction indicator shall evaluate to an integer
    // expression +1, -1, or 0." An enumeration of three, not a range — +2 does
    // not select anything and there is nothing to clamp it onto.
    if (std.mem.eql(u8, name, "last_crossing") and args.len > 1 and args[1] != .none) {
        if (self.constEval(args[1])) |c| {
            const v = c.asReal();
            if (c != .str and (v != @round(v) or @abs(v) > 1))
                try self.errAt(args[1], .E0516, "`last_crossing()` direction indicator shall be +1, -1 or 0, got {d}", .{v});
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
            try out.append(self.arena, try self.iconst(@intCast(elems.len)));
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
            const d = info.first();
            try out.append(self.arena, try self.iconst(d.count()));
            var i = d.lo;
            while (i <= d.hi) : (i += 1) {
                const el = (try self.arrayElemValue(name, &.{i})) orelse return true;
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
    for (ex.args(e)) |a| {
        if (a == .none) continue;
        if (try self.appendVectorArg(&vals, a)) continue;
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    return .{ .v = try self.call(name, vals.items), .ty = .real };
}

// ---- ch9 system functions ---------------------------------------------------

/// ch9 system function in expression position. Everything not on the
/// deliberately-unsupported list becomes a `call`; codegen.emitCall dispatches
/// on the name and owns the simulator semantics.
fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (isDigitalOnlySysFunc(name)) { // §9.2
        try self.errAt(e, .E0806, "`{s}`", .{name});
        return poison;
    }
    // §9.22/§9.23 — the driver access family, refused because this is not a
    // connect module (see `isConnectModuleOnlySysFunc` for why the test is a
    // name test today and what it narrows into later).
    if (isConnectModuleOnlySysFunc(name)) {
        var b = self.errAtWith(e, .E0818);
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
        var b = self.errAtWith(e, .E0808);
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
                        var b = self.errAtWith(e, .E0809);
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
    if (std.mem.eql(u8, name, "$simparam")) {
        const args = ex.args(e);
        if (args.len == 1) {
            if (self.constEval(args[0])) |c| switch (c) {
                .str => |s| if (self.simparamValue(s) == null) {
                    var b = self.errAtWith(e, .E0811);
                    b.msg("`\"{s}\"`", .{s});
                    b.note("$simparam(\"{s}\", <expression>) supplies the value to use instead, and §9.15 makes that form legal for any name", .{s});
                    try b.emit();
                    return poison;
                },
                else => {},
            };
        }
    }
    const sys_args = if (ex.extraOf(e) < ex.pool.items.len) ex.args(e) else &[_]Ast.ExprId{};
    // §9.20 the two alias functions: six validity rules, all of them about the
    // CALL rather than the value, so all of them here (E0812).
    if (std.mem.eql(u8, name, "$analog_node_alias") or std.mem.eql(u8, name, "$analog_port_alias")) {
        if (try self.checkAliasCall(e, name, sys_args)) return poison;
    }
    // §9.17.3 Syntax 9-12's THIRD form, `$limit(access, analog_function_identifier,
    // arg_list)`. The second argument names a §4.7 function, so it is not a value
    // and must not be looked up as one (E0314 was the whole gap): it is dropped
    // here, along with the tail that §9.17.3 says is passed on to that function.
    if (std.mem.eql(u8, name, "$limit") and sys_args.len >= 2) {
        if (try self.limitUserFunc(sys_args[1])) |fd| {
            // "The arguments of the user-defined function shall all be declared
            // input." The simulator supplies all of them — the probe's value for
            // this iteration, the value $limit returned on the previous one, then
            // the call's tail — so an `output` formal would write back into the
            // solver's own iteration history mid-Newton-step, and §9.17.3 defines
            // no meaning for that.
            for (fd.args) |formal| {
                if (formal.direction == .input) continue;
                var b = self.errAtWith(e, .E0814);
                b.msg("formal `{s}` of the `$limit` limiter `{s}` is declared `{s}`", .{
                    self.file.str(formal.name), self.file.str(fd.name), @tagName(formal.direction),
                });
                b.note("§9.17.3: \"The arguments of the user-defined function shall all be declared input\"", .{});
                try b.emit();
                return poison;
            }
            // §4.5.15 lets the simulator decline a limiting request ("the
            // simulator may choose to ignore the limiting request"), and §9.17.3
            // only calls the user function "if the simulator determines that
            // limiting is needed to improve convergence". VerA declines: the
            // limiter is not called, and §9.17.3's converged answer — "When the
            // simulator has converged, the return value of the $limit() function
            // is the value of the access function reference, within appropriate
            // tolerances" — is what is left, which is the probe. Written as the
            // one-argument form so `cg_limit` reaches its own decline path and
            // renders the identity of the probe.
            //
            // ponytail: declined, not inlined. Inlining the limiter would mean
            // emitting it into the contract's `limit` hook with the PREVIOUS
            // return as its second argument, i.e. one more piece of per-call
            // solver state; the identity answer above is what §9.17.3 promises at
            // convergence either way, and no fixture can see the difference
            // (a non-identity limiter would, which is why this is written down).
            return .{
                .v = try self.call(name, &.{try self.lowerSysArg(sys_args[0])}),
                .ty = sysFuncTy(name),
            };
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
        try self.errAt(e, .E0813, "`{s}` is a task and has no value; call it as a statement", .{name});
        return poison;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (sys_args) |a| {
        if (a == .none) continue;
        try vals.append(self.arena, try self.lowerSysArg(a));
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
///     $table_model(ND, NP, NCOL, dep, "<extrap>", in₀…in_{ND-1}, row₀…row_{NP-1})
///
/// — the dimensionality, the sample count, the column count, the dependent
/// COLUMN the selector picked, two Table 9-31 extrapolation characters per
/// dimension, then the lookup point and the flat row-major sample block.
///
/// Everything §9.21.2 and §9.21.1 decide is decided HERE, and the reason is the
/// same one that puts §9.20's rules in lowering: none of it is a value. The
/// control string is a constant, so a scheme VerA cannot honour has to be
/// reported rather than approximated (E0815); the data source is a set of ARRAY
/// IDENTIFIERS or a file name, neither of which survives into MIR. What reaches
/// codegen is a call whose every operand is a number, a string or a probe.
///
/// A FILE data source is read at compile time and its rows emitted as constants.
/// That is not a shortcut around run-time I/O, it is what §9.21.1 says the
/// semantics are: "The state of the data source is captured on the first call to
/// the table model function. Any change after this point is ignored." A residual
/// re-read per Newton iteration would be both slower and less faithful.
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
        try self.errAt(e, .E0815, "`$table_model(table_inputs, table_data_source [, table_control_string])` — one lookup expression per dimension, then the data source", .{});
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
        try self.errAt(e, .E0815, "trailing argument to `$table_model` is neither an array data source nor a constant string", .{});
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
            try self.errAt(e, .E0815, "an array data source takes at most one control string", .{});
            return poison;
        }
        ctl = strs[0];
        ncol = cols.items.len;
        np = cols.items[0].len;
        if (ncol <= nd) {
            try self.errAt(e, .E0815, "{d} lookup input(s) need {d} independent arrays plus an output array, got {d}", .{ nd, nd, ncol });
            return poison;
        }
        for (cols.items) |c| {
            if (c.len != np) {
                try self.errAt(e, .E0815, "the arrays of a `$table_model` data source are columns of one table and must be the same length; got {d} and {d}", .{ np, c.len });
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
            try self.errAt(e, .E0815, "`$table_model` needs a data source: a file name, or one array per dimension plus an output array", .{});
            return poison;
        }
        ctl = strs[1];
        const nums = (try self.readTableFile(e, strs[0], nd)) orelse return poison;
        ncol = nums.cols;
        np = nums.vals.len / ncol;
        const flat = try self.arena.alloc(Mir.Value, nums.vals.len);
        for (nums.vals, flat) |v, *out| out.* = try self.fconst(v);
        rows = flat;
    }

    // §9.21: "The minimum data requirement is to have the product of at least
    // two points per dimension (2ᴺ for N dimensions)."
    if (np < std.math.pow(usize, 2, @min(nd, 30))) {
        try self.errAt(e, .E0815, "a {d}-dimensional table needs at least {d} samples, got {d}", .{ nd, std.math.pow(usize, 2, @min(nd, 30)), np });
        return poison;
    }

    const ext = try self.arena.alloc(u8, 2 * nd);
    const dep = (try self.parseTableCtl(e, ctl, nd, ncol, ext)) orelse return poison;

    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.appendSlice(self.arena, &.{
        try self.iconst(@intCast(nd)),
        try self.iconst(@intCast(np)),
        try self.iconst(@intCast(ncol)),
        try self.iconst(@intCast(dep)),
        try self.mir.addStrConst(self.arena, ext),
    });
    for (args[0..nd]) |a| try vals.append(self.arena, try self.toReal(try self.lowerExpr(a)));
    for (rows) |v| try vals.append(self.arena, v);
    self.uses_table_model = true;
    return .{ .v = try self.call("$table_model", vals.items), .ty = .real };
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
            try self.errAt(e, .E0815, "cannot read the `$table_model` data source \"{s}\"", .{name});
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
                try self.errAt(e, .E0815, "\"{s}\": `{s}` is not a real or integer number", .{ name, tok });
                return null;
            };
            try vals.append(self.arena, x);
            n += 1;
        }
        if (n == 0) continue; // blank line, or a line that was only a comment
        if (cols == 0) cols = n;
        if (n != cols) {
            try self.errAt(e, .E0815, "\"{s}\": every sample point is one row of {d} columns; found a row of {d}", .{ name, cols, n });
            return null;
        }
    }
    if (cols <= nd) {
        try self.errAt(e, .E0815, "\"{s}\": {d} lookup input(s) need {d} independent columns plus a dependent one, found {d}", .{ name, nd, nd, cols });
        return null;
    }
    return .{ .vals = vals.items, .cols = cols };
}

/// §9.21.2 the control string. Writes `2*nd` Table 9-31 extrapolation characters
/// into `ext` (low end then high end, per dimension) and returns the dependent
/// COLUMN index, or null when the string asks for something VerA does not
/// implement.
///
/// The interpolation character is validated and then DROPPED, because only one
/// value of it survives: Table 9-30's `1`. `D`, `2` and `3` (closest point,
/// quadratic and cubic splines) and `I` (ignore this column) are refused at the
/// call. So is Table 9-31's `E` — "an extrapolation error is reported if the
/// $table_model function is requested to evaluate a point beyond the
/// interpolation region", and a device residual has no channel to report one on;
/// silently extrapolating instead is exactly the wrong-number failure the refusal
/// exists to prevent.
fn parseTableCtl(self: *Lower, e: Ast.ExprId, ctl: []const u8, nd: usize, ncol: usize, ext: []u8) Oom!?usize {
    // "the function defaults to performing linear interpolation and linear
    // extrapolation in both dimensions" (§9.21.5), which Table 9-32's first row
    // states for every dimension: `""` is "default linear interpolation and
    // extrapolation".
    @memset(ext, 'L');
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
    if (sel == 0 or nd + sel - 1 >= ncol) {
        try self.errAt(e, .E0815, "dependent selector {d} names no dependent column: the data source has {d} column(s) and {d} independent(s)", .{ sel, ncol, nd });
        return null;
    }

    var d: usize = 0;
    var it = std.mem.splitScalar(u8, head, ',');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t");
        if (d >= nd) {
            // One sub-string per independent variable, "with the first
            // sub-string applying to the outermost dimension and so on".
            if (s.len == 0) continue;
            try self.errAt(e, .E0815, "the control string has more interpolation sub-strings than the {d} lookup input(s)", .{nd});
            return null;
        }
        defer d += 1;
        var j: usize = 0;
        if (s.len != 0 and std.mem.indexOfScalar(u8, "ID123", s[0]) != null) {
            if (s[0] != '1') {
                try self.errAt(e, .E0815, "VerA implements Table 9-30's `1` (linear interpolation) only; `{c}` is not implemented", .{s[0]});
                return null;
            }
            j = 1;
        }
        const xs = s[j..];
        if (xs.len > 2) {
            try self.errAt(e, .E0815, "`{s}`: a control sub-string carries at most 2 extrapolation characters", .{s});
            return null;
        }
        for (xs) |c| if (c != 'C' and c != 'L') {
            try self.errAt(e, .E0815, "`{c}` is not an extrapolation method VerA implements (Table 9-31 `C` or `L`)", .{c});
            return null;
        };
        // "When one extrapolation method character is given, the specified
        // extrapolation method will be used for both ends. When two ... the
        // first character specifies the extrapolation method used for the end
        // with the lower coordinate value."
        if (xs.len == 1) {
            ext[2 * d] = xs[0];
            ext[2 * d + 1] = xs[0];
        } else if (xs.len == 2) {
            ext[2 * d] = xs[0];
            ext[2 * d + 1] = xs[1];
        }
    }
    return nd + sel - 1;
}

/// The §4.7 function a `$limit` second argument names, or null when the argument
/// is not one — Syntax 9-12's other two forms put a string there, or nothing.
///
/// The ordinary scopes are consulted FIRST, so a variable or parameter that
/// happens to share a function's name still wins (§2.8), exactly as
/// `natureAbstol` arranges for a nature identifier in a tolerance slot.
fn limitUserFunc(self: *Lower, a: Ast.ExprId) Oom!?*const Ast.FuncDecl {
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

/// §9.20's validity list for `$analog_node_alias()` / `$analog_port_alias()`.
/// True when the call was refused.
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
fn checkAliasCall(self: *Lower, e: Ast.ExprId, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    // 1. "It shall be an error for the $analog_node_alias() and
    // $analog_port_alias() system functions to be used outside the analog
    // initial block." The next sentence gives the reason: both "shall be
    // re-evaluated each sweep point of a dc sweep", i.e. between solves.
    if (!self.in_analog_initial) {
        try self.errAt(e, .E0812, "`{s}` is used outside an analog initial block", .{name});
        return true;
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
    // ponytail: a `?:` whose arms are the call is not counted — lowering emits a
    // `select`, not a conditional body. No fixture writes one; the day one does,
    // the place to count it is `lowerTernary`.
    //
    // The `analog initial` block is itself ONE guarded body — `lowerModule`
    // wraps it in the `initial_step` flag rather than splitting the CFG — so the
    // depth inside an EMPTY initial block is already 1/0. That guard is not a
    // §9.20 conditional, it is the context the clause requires, so it is
    // discounted (saturating, since rule 1 above is what guarantees it is there).
    if ((self.cond_depth -| 1) != self.static_cond_depth) {
        try self.errAt(e, .E0812, "`{s}` is used inside conditional statement whose condition can change during the simulation", .{name});
        return true;
    }
    // 3/4/5. The analog_net_reference. "The analog_net_reference shall be either
    // a scalar or vector continuous node declared in the module containing the
    // system function call."
    const ref = if (args.len > 0) args[0] else Ast.ExprId.none;
    if (ref == .none) {
        try self.errAt(e, .E0812, "`{s}` needs an analog_net_reference and a hierarchical_reference_string", .{name});
        return true;
    }
    switch (ex.tag(ref)) {
        .ident => {
            const rname = self.file.str(ex.strOf(ref));
            const idx = self.node_voltages.get(rname);
            if (idx == null or idx.? == ground or self.vars.contains(rname)) {
                try self.errAt(e, .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
                return true;
            }
            // 4. "It shall be an error for the analog_net_reference to be a port
            // or to be involved in port connections." A port is already bound to
            // whatever the instantiating netlist connected it to, and the alias
            // would bind the same matrix position a second time.
            if (idx.? < self.num_ports) {
                try self.errAt(e, .E0812, "§9.20 does not allow the analog_net_reference to be a port: `{s}`", .{rname});
                return true;
            }
        },
        // 5. "If the analog_net_reference is a vector node, it shall reference
        // the full vector node, it shall be an error for it to be a bit select
        // or part select of a vector node." The asymmetry is deliberate: the
        // scalar ELEMENT is what the hierarchical_reference_string may name.
        .index, .range => {
            try self.errAt(e, .E0812, "a vector analog_net_reference must be the whole vector, not a bit select or part select", .{});
            return true;
        },
        else => {
            try self.errAt(e, .E0812, "the analog_net_reference of `{s}` is not a continuous node declared in this module", .{name});
            return true;
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
        try self.errAt(e, .E0812, "the hierarchical_reference_string of `{s}` is not a constant string (a string literal or a string parameter)", .{name});
        return true;
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
    if (std.mem.indexOfScalar(u8, target, '.') == null) {
        for (self.alias_refs.items) |prev| {
            if (!std.mem.eql(u8, prev, target)) continue;
            try self.errAt(e, .E0812, "`\"{s}\"` is already the analog_net_reference of another $analog_node_alias/$analog_port_alias call", .{target});
            return true;
        }
    }
    try self.alias_refs.append(self.arena, ref_name);
    return false;
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
fn lowerSimprobe(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const args = ex.args(e);
    if (args.len < 2) {
        var b = self.errAtWith(e, .E0809);
        b.msg("`$simprobe` takes an instance name and a parameter name", .{});
        try b.emit();
        return poison;
    }
    const inst = self.constStrArg(args[0]);
    const param = self.constStrArg(args[1]);
    if (inst != null and param != null) {
        const path = try std.mem.concat(self.arena, u8, &.{ inst.?, &[_]u8{Elaborate.sep}, param.? });
        if (self.param_index.get(path)) |pi|
            return .{ .v = self.param_values.items[pi], .ty = astTy(self.params.items[pi].ty) };
    }
    // Unresolved. §9.16's own two outcomes, in the clause's order.
    if (args.len >= 3 and args[2] != .none) return self.lowerExpr(args[2]);
    var b = self.errAtWith(e, .E0817);
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

/// Several ch9 functions take a NET or PORT reference rather than a value —
/// §9.19 `$port_connected`, §9.20 `$analog_node_alias`, §9.22/§9.23 driver
/// access. A bare net name in argument position lowers to its node_order
/// index, which is what codegen needs; anything else is an ordinary value.
fn lowerSysArg(self: *Lower, e: Ast.ExprId) Oom!Mir.Value {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        const is_value = self.vars.contains(name) or self.param_index.contains(name) or
            self.consts.contains(name);
        if (!is_value) {
            if (self.node_voltages.get(name)) |idx| return self.iconst(idx);
        }
    }
    return (try self.lowerExpr(e)).v;
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
/// number: "iteration" and "gdev" are properties of a solver run this compiler
/// does not host, and "simulatorVersion" is required to increase monotonically
/// across releases, which a constant cannot do.
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
    if (eq(u8, name, "tnom")) return 27.0;
    // Three unit-valued homotopy/geometry factors: a device compiled here is
    // never being stepped or shrunk, so 1.0 is the true answer, not a stand-in.
    if (eq(u8, name, "scale") or eq(u8, name, "shrink") or eq(u8, name, "sourceScaleFactor")) return 1.0;
    return null;
}

/// ch9 return types. Everything not listed is real (§9.14/§9.15 dominate).
///
/// `pub` for one consumer: analysis.zig's "sysFuncTy and callTy agree" test.
/// The two type the same call from opposite sides of the MIR and their comments
/// have said MUST AGREE since both were written; the test is what turns that
/// into something a build can fail on.
pub fn sysFuncTy(name: []const u8) Ty {
    const ints = [_][]const u8{
        "$param_given", "$port_connected", // §9.19
        "$test$plusargs", "$value$plusargs", // §9.12
        // §9.11 Table 9-8. `$bitstoreal` is deliberately NOT here: it maps a
        // bit pattern TO a real, so its result is a real. Typing it as an
        // integer made codegen assign an `S` expression to an `i64` slot, which
        // does not even compile — see tests/fixtures/exhaustive/122.
        "$rtoi",          "$clog2",
        "$realtobits",
        // The §9.22/§9.23 driver access family is NOT here, and neither is it in
        // `analysis.callTy`: `isConnectModuleOnlySysFunc` refuses every one of
        // those calls before it becomes a `call`, so no MIR node carries the name
        // and there is nothing left to type. A row here would be a type for an
        // expression that cannot exist.
        // §9.20 "The return value for both system functions shall be one (1) if
        // the alias was successfully created and zero (0) otherwise" — a status,
        // not a measurement. Typed real, the §4.1.9 status assignment forced an
        // int→real→int round trip through the `integer` slot and `status << 1`
        // collected a false E0322 on legal code.
        "$analog_node_alias", "$analog_port_alias",
        // §9.5.4.2 the scan count, and the item flavour whose destination is an
        // integer variable. Synthetic names `lowerScan` builds; the flavour name
        // IS the type, so this and `analysis.callTy` agree by construction.
         "$sscanf",
        "$sscanf$int",
        // §9.5.1/§9.5.4/§9.5.5/§9.5.7/§9.5.8 — every descriptor function is
        // integer-valued, and each digit is one the LRM writes down: a 32-bit
        // mcd or fd, a character count, an item count, a byte offset, a -1/0
        // status, an errno, a nonzero-or-zero EOF flag. They read `.real` until
        // this list existed, so `integer fd = $fopen(…)` rounded a float 0.0.
        "$fopen",         "$fgets",
        "$fscanf",        "$fscanf$int",
        "$ftell",         "$fseek",
        "$rewind",        "$ferror",
        "$feof",
    };
    for (ints) |i| if (std.mem.eql(u8, name, i)) return .integer;
    if (std.mem.eql(u8, name, "$simparam$str")) return .string; // §9.15
    // §9.5.3 the formatted text itself, and §9.5.4.2's string-valued item.
    if (std.mem.eql(u8, name, "$sformat") or std.mem.eql(u8, name, "$sscanf$str")) return .string;
    // §9.5.4.1's string, §9.5.4.2's string-valued item and §9.5.7's description.
    if (std.mem.eql(u8, name, "$fgets$str") or std.mem.eql(u8, name, "$fscanf$str") or
        std.mem.eql(u8, name, "$ferror$str")) return .string;
    return .real;
}

// ---------------------------------------------------------------------------
// Class 9 — user-defined analog functions (LRM §4.7)
// ---------------------------------------------------------------------------

/// §4.7.3: "An analog user-defined function ... shall not call itself directly
/// or indirectly, i.e., recursive functions are not permitted."
///
/// The sentence constrains the FUNCTION, so the check cannot be left to
/// `inlineUserFunc`'s inline stack: that one only fires when the analog block
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
        try self.scanCallees(fd.body, fns, out);
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

/// Collect the §4.7 functions one statement tree calls, as indices into `fns`.
/// A name that is not a declared function is not an edge — `lowerUserCall`
/// reports it (E0512) when the call is reached.
fn scanCallees(self: *Lower, id: Ast.StmtId, fns: []const Ast.FuncDecl, out: *std.ArrayList(u32)) Oom!void {
    if (id == .none) return;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try self.scanCallees(s, fns, out),
        .assign => |a| {
            try self.scanCalleesExpr(a.target, fns, out);
            try self.scanCalleesExpr(a.value, fns, out);
        },
        .contribute => |c| {
            try self.scanCalleesExpr(c.lhs, fns, out);
            try self.scanCalleesExpr(c.rhs, fns, out);
        },
        .indirect => |c| {
            try self.scanCalleesExpr(c.lhs, fns, out);
            try self.scanCalleesExpr(c.probe, fns, out);
            try self.scanCalleesExpr(c.eqn, fns, out);
        },
        .if_stmt => |s| {
            try self.scanCalleesExpr(s.cond, fns, out);
            try self.scanCallees(s.then_s, fns, out);
            try self.scanCallees(s.else_s, fns, out);
        },
        .case_stmt => |s| {
            try self.scanCalleesExpr(s.scrutinee, fns, out);
            for (s.arms) |arm| {
                for (arm.labels) |l| try self.scanCalleesExpr(l, fns, out);
                try self.scanCallees(arm.body, fns, out);
            }
        },
        .for_stmt => |s| {
            try self.scanCallees(s.init, fns, out);
            try self.scanCalleesExpr(s.cond, fns, out);
            try self.scanCallees(s.step, fns, out);
            try self.scanCallees(s.body, fns, out);
        },
        .while_stmt => |s| {
            try self.scanCalleesExpr(s.cond, fns, out);
            try self.scanCallees(s.body, fns, out);
        },
        .repeat_stmt => |s| {
            try self.scanCalleesExpr(s.count, fns, out);
            try self.scanCallees(s.body, fns, out);
        },
        .event_control => |s| try self.scanCallees(s.body, fns, out),
        .sys_task => |s| for (s.args) |a| try self.scanCalleesExpr(a, fns, out),
        .jump => |j| try self.scanCalleesExpr(j.value, fns, out),
        else => {},
    }
}

fn scanCalleesExpr(self: *Lower, e: Ast.ExprId, fns: []const Ast.FuncDecl, out: *std.ArrayList(u32)) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (tag == .call) {
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
            for (ex.args(e)) |a| try self.scanCalleesExpr(a, fns, out);
        },
        .ternary => try self.scanCalleesExpr(ex.ternaryElse(e), fns, out),
        else => {},
    }
    // `lhs`/`rhs` are `.none` on every tag that does not use them.
    try self.scanCalleesExpr(ex.lhs(e), fns, out);
    try self.scanCalleesExpr(ex.rhs(e), fns, out);
}

fn lowerUserCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const m = self.module orelse return poison;
    for (m.functions) |*fd| {
        if (!std.mem.eql(u8, self.file.str(fd.name), name)) continue;
        return self.inlineUserFunc(fd, ex.args(e), e);
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
pub fn inlineUserFunc(
    self: *Lower,
    fd: *const Ast.FuncDecl,
    arg_exprs: []const Ast.ExprId,
    site: Ast.ExprId,
) Oom!TypedValue {
    const name = self.file.str(fd.name);
    for (self.inlining.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            try self.errAt(site, .E0510, "`{s}`", .{name});
            return poison;
        }
    }
    if (arg_exprs.len != fd.args.len) {
        try self.errAt(site, .E0511, "`{s}()` takes {d}, got {d}", .{ name, fd.args.len, arg_exprs.len });
        return poison;
    }

    // Actuals are evaluated in the CALLER's scope, before it is swapped out.
    // An ARRAY formal (§4.7.2.3) takes one Value per element — the formal is
    // scalarized inside the function exactly as a §3.2 array is anywhere else,
    // so the pass is element-wise in both directions.
    var actuals: std.ArrayList([]const Mir.Value) = .empty;
    defer actuals.deinit(self.arena);
    for (fd.args, arg_exprs) |formal, actual| {
        const ty = astTy(formal.ty);
        if (formal.dims.len != 0) {
            const n = try self.funcArrayLen(&formal, site) orelse return poison;
            const vals = try self.arena.alloc(Mir.Value, n);
            // §4.7.2.3: "All output arguments ... are initialized, zero (0) if
            // numeric, which in turn means that the argument passed to it is
            // reset to zero." An `inout` is NOT (§4.7.2.4 copies in).
            if (formal.direction == .output) {
                @memset(vals, zeroOf(ty));
            } else if (!try self.funcArrayIn(actual, ty, vals)) {
                try self.errAt(actual, .E0511, "`{s}()` argument `{s}` needs {d} elements", .{
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
    const saved_loops = self.loops.items.len;
    const log_mark = self.scope_log.items.len;
    self.vars = .empty;
    self.arrays = .empty;
    self.restrict = "an analog function";
    try self.inlining.append(self.arena, name);

    // §4.7.2 local parameters fold to constants; they never reach the Model.
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
            try self.arrays.put(self.arena, fname, .{ .dims = dims, .ty = ty });
            const slots = try self.arena.alloc(VarSlot, vals.len);
            var sub: [8]i64 = undefined;
            for (vals, slots, 0..) |v, *slot, k| {
                const idx = if (dims.len <= sub.len) sub[0..dims.len] else try self.arena.alloc(i64, dims.len);
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

    const exit = try self.newBlock();
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
    self.loops.shrinkRetainingCapacity(saved_loops);

    var w: usize = 0;
    for (fd.args, arg_exprs) |formal, actual| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        defer w += 1;
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

/// How many scalars an array FORMAL declares (§4.7.2.3). Its bounds are a
/// `constant_expression` like any other array's, folded in the CALLER's scope
/// because a formal's range may name a module parameter.
fn funcArrayLen(self: *Lower, formal: *const Ast.FuncArg, site: Ast.ExprId) Oom!?usize {
    const dims = try self.dimsBounds(formal.dims, formal.main_tok, self.file.str(formal.name)) orelse {
        _ = site;
        return null;
    };
    return shapeCells(dims);
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
            var sub: [8]i64 = undefined;
            for (out, 0..) |*v, k| {
                const idx = if (info.dims.len <= sub.len) sub[0..info.dims.len] else try self.arena.alloc(i64, info.dims.len);
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
            var sub: [8]i64 = undefined;
            for (vals, 0..) |v, k| {
                const idx = if (info.dims.len <= sub.len) sub[0..info.dims.len] else try self.arena.alloc(i64, info.dims.len);
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

/// The same fold with parameters EXCLUDED. A procedural `if (p > 0)` must stay
/// a runtime branch — `p` is overridable by the model card, so folding it to
/// its default would silently compile the wrong arm (§3.4 vs §6.6.2).
fn elabConst(self: *const Lower, e: Ast.ExprId) ?Const {
    return self.foldExpr(e, false);
}

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
            if (!params and self.param_index.contains(name)) return null;
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
        // The one overflowing division is -2^31 / -1, whose 2's complement
        // answer is -2^31 again.
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = wrap32(@divTrunc(a.asInt(), b.asInt())) })
        else
            Const{ .real = x / y },
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @rem(a.asInt(), b.asInt()) })
        else
            Const{ .real = @rem(x, y) },
        .pow => .{ .real = std.math.pow(f64, x, y) },
        .eq => .{ .int = @intFromBool(x == y) },
        .neq => .{ .int = @intFromBool(x != y) },
        .lt => .{ .int = @intFromBool(x < y) },
        .le => .{ .int = @intFromBool(x <= y) },
        .gt => .{ .int = @intFromBool(x > y) },
        .ge => .{ .int = @intFromBool(x >= y) },
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
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        else => null,
    };
}

// ponytail: ONE deferral is listed here, because it is the only one with no home
// at a declaration or a call site — every other ceiling in this file says so in
// its own `ponytail:` comment, where it cannot drift out of agreement with the
// code beside it. This list used to hold four more, and all four had shipped:
// §4.4.2/§5.4.3 port probes (see `port_probes` and `lowerPortAccess`, with their
// own solver unknown), §3.12 branch arrays and §6.5.2 vector ports (scalarised —
// see the `vectors` map), §6.2.2 module instantiation (src/ir/elaborate.zig), and
// §3.2.2 runtime array indices, which fold to a select chain for one dimension
// and name their remaining ceiling at the fold itself. A block comment listing
// what the file does not do is a register in the worst place for one.
//   · §4.7.2 function-local `parameter` declarations fold into `consts` and
//     are not restored on exit: a module parameter of the same name would be
//     shadowed for the rest of the module. Give `consts` the same save/restore
//     treatment as `vars` if a fixture ever does that.

// ---------------------------------------------------------------------------
// Self-check: the whole frontend on two small modules — the split that class 6
// and codegen depend on, plus one diagnostic. Runs on std.testing.allocator
// through an arena, so a leaked byte fails the test.
// ---------------------------------------------------------------------------

const Parser = @import("../frontend/parser.zig");

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
    // here — one artifact serves every model card — and `elabConst` treats a
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
        // The name codegen's `flow(` predicate keys on, and which no §2.7/§2.8.1
        // identifier and no `flow(a,b)` branch unknown can collide with.
        try std.testing.expect(std.mem.startsWith(u8, h.low.nodeName(pp.u), "flow(<"));
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
        var minted = false;
        for (g.low.node_order.items) |name| {
            if (std.mem.eql(u8, name, "flow(p,n)")) minted = true;
        }
        try std.testing.expectEqual(c.unknown, minted);
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

test "lower: §9.17.1 $discontinuity folds its degree; the $limit form (-1) emits nothing" {
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
    // §9.17.1's `-1` exists only for `$limit`; there is no announcement to make,
    // so no place, no synthetic call, and therefore no unit.
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
