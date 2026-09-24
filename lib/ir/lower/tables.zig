//! `Lowered` — what lowering hands to every later stage, as one value.
//!
//! ARCHITECTURE §3 `lower/tables.zig`, §6 phase 6. `Lower` is the machine that
//! BUILDS these tables (symbol tables, the SSA builder, scopes, accumulators);
//! this is the part that outlives it. proof, analysis, naming, codegen, the
//! testbench runner and the VPI take a `*const Lowered`, so none of them can
//! reach lowering state, and everything they read is listed below.
//!
//! Every buffer is arena-owned, like the MIR it indexes.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const Mir = @import("../mir.zig");
const Ssa = @import("../ssa.zig");
const Elaborate = @import("../elaborate.zig");
const Lower = @import("../lower.zig");
const lower_sysfunc = @import("sysfunc.zig");

pub const Lowered = @This();

// ---- the source, for diagnostics and host facts ----
/// The parsed (and elaborated) file every `Ast` id below indexes.
file: *const Ast.SourceFile,
/// Preprocessed source and the lexer's `.start` column, kept ONLY so a token
/// index can become a `diag.Span` (`tokenSpan`).
src: []const u8 = "",
tok_starts: []const u32 = &.{},
/// The preprocessor's positional directive events (`Preprocessor.Directives`).
/// Downstream reads two of them: §10.3's `default_transition (codegen's
/// `transition()` default) and §9.15's `timescale (`simparamValue`, the
/// testbench's mixed-signal time unit).
directives: Preprocessor.Directives = .{},

// ---- the elaborated hierarchy (§6), for the VPI ----
/// The module being lowered (§6.2). Set by `lowerModule`.
module: ?*const Ast.ModuleDecl = null,
/// §6.7 path → flat name, from elaboration. Lowering reads it in `flatName`,
/// the VPI to resolve a path.
hier_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// §9.15/§9.16, indexed by `Ast.AnalogBlock.unit`: the module a block was
/// WRITTEN in and the instance path it was inlined at. See `Design.units` —
/// flattening erases both, so elaboration publishes them.
unit_paths: []const Elaborate.UnitPath = &.{},
/// §3.4 the constant table as lowering left it: every module parameter's
/// folded value, by flat name. The VPI's `vpiParameter` values.
consts: std.StringHashMapUnmanaged(Lower.Const) = .empty,
/// §3.6.3 declared vector nets and §3.12 vector branches, by base name.
///
/// SCALARISED, so this map is the only place a range survives elaboration:
/// `electrical [3:0] p` interns four ordinary nodes called `p[3]`…`p[0]` and
/// the node table never learns that ranges exist. Everything downstream —
/// `internNode`, `probe`, the contribution index, codegen's `U` enum — sees
/// four unrelated nets and needs no change at all. What is left over is the
/// two questions a reference has to answer: is this name a vector, and is
/// this index one of its elements (E0351, E0352).
vectors: std.StringHashMapUnmanaged(Lower.VecRange) = .empty,

// ---- §1.3.1 the unknown table ----
/// The U-enum index space: ports (§6.5) first, then internal nodes (§3.6.3),
/// then branch-flow unknowns (§5.4.2). Append-only ⇒ stable.
node_order: std.ArrayList([]const u8) = .empty,
/// What each node_order slot IS, as opposed to what it is SPELLED. One entry
/// per slot, appended by `appendNode` — see `NodeKind` for why the two had to
/// come apart.
node_kind: std.ArrayList(Lower.NodeKind) = .empty,
/// Discipline name per node_order slot (`""` when undeclared, §3.9).
node_disciplines: std.ArrayList([]const u8) = .empty,
/// §6.5.2.2 port direction per node_order slot (`.unspecified` for an internal
/// net or a port whose direction is never declared). A DIRECTIONAL port —
/// `input` or `output` — is the one place the LRM's signal-flow port model
/// (§1.3.4) is unambiguous, and codegen has to refuse those; which of the two
/// it is decides §1.3.4.1's contribution-target rule (see E0425).
node_dir: std.ArrayList(Ast.Direction) = .empty,
num_ports: usize = 0, // §6.5
/// §5.4.2 branch-flow identity: the node PAIR → its unknown's node_order slot.
/// The pair is the identity the LRM gives the branch, and keying on it is what
/// stopped `I(a)` and `I(a,gnd)` sharing an unknown when a plain net is spelled
/// `gnd` — see `flowUnknown`. Bounded by the branch count of one module.
flow_unknowns: std.AutoHashMapUnmanaged(Lower.FlowKey, u16) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the module's KCL sum
/// at `port`; codegen emits that row. Append-only ⇒ deterministic.
port_probes: std.ArrayList(Lower.PortProbe) = .empty,
/// §3.6.3.2 the net_decl_assignments of this module, in declaration order and
/// already folded. Sparse — most modules declare none — so codegen emits the
/// optional `u_nodeset` table only when this is non-empty.
nodesets: std.ArrayList(Lower.Nodeset) = .empty,
disciplines: std.StringHashMapUnmanaged(Lower.DisciplineInfo) = .empty, // §3.6.2

// ---- §3.4 the model card and §5.6 the equations ----
params: std.ArrayList(Lower.ParamInfo) = .empty, // §3.4
/// §3.4.7 the alias side of `Lower.param_index`, in declaration order, for the ONE
/// consumer that cannot read it out of `param_index`: the model card. An alias
/// exists to carry an override — "nmos2 #(.trise(5))" and "nmos2 #(.dtemp(5))"
/// have to mean the same thing — so the alias needs a field of its own on the
/// card, which `params` (one entry per real parameter) has no slot for.
/// `param_index` cannot answer this because it holds both names with nothing
/// saying which is the alias.
aliases: std.ArrayList(Lower.Alias) = .empty,
contributions: std.ArrayList(Lower.Contribution) = .empty, // §5.6

// ---- instance state ----
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable RETAINS its value between analog evaluations — that
/// is the entire point of `@(cross(...)) x = V(p);`, and an ordinary SSA place
/// cannot express it, because every module variable is re-initialised from its
/// declaration at the top of every evaluation. Each entry gets a persistent
/// `Instance` slot instead; codegen reads it directly.
held_vars: std.ArrayList(Lower.HeldVar) = .empty,
/// §9.17.3 the user-function `$limit` state, one entry per ACCESS FUNCTION.
/// Collected by `scanCallSites` before the analog block is lowered.
limit_slots: std.ArrayList(Lower.LimitSlot) = .empty,
/// First-call sample counts, one entry per array-source call site.
table_samples: std.ArrayList(u32) = .empty,
/// §9.13.1 — how many call sites took the SEEDLESS form (`$random` with no
/// argument, or a constant/parameter seed, whose "internal seed ... is not
/// visible from the source"). One `Instance` latch slot each: codegen emits the
/// array, `updateState` advances it on the accepted step, and the residual only
/// reads it. Per SITE and not one shared counter because §9.13.1 says the
/// internal seed "gets updated every time the call to $arandom is made", so two
/// call sites are two streams, not two reads of one.
rng_auto_sites: u32 = 0,

// ---- live roots: values no contribution reads, kept alive by codegen ----
/// §9.4 display tasks, in source order. A display call's RESULT is never read,
/// so it is dead code the moment codegen slices a unit out of the MIR — and the
/// print vanishes with it. `display_root` is the one live root that keeps them
/// all: see `finishDisplays`.
displays: std.ArrayList(Lower.Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// Source-order chain over table captures and distribution checks; a core
/// live-out.
table_effect: Mir.Value = .f_zero,
/// §9.17.1 rejection belongs to the Newton iteration, not timestep history.
reject_iteration_place: ?Ssa.Place = null,
reject_iteration: Mir.Value = .zero,

// ---- which kernels the device needs ----
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
/// §9.15 the model queries the runtime Newton iteration number.
uses_newton_iter: bool = false,
/// §9.15 the model reads a `$simparam` whose value is the HOST's
/// (`simparamHostField`), so codegen owes its Model the reserved field. Set at
/// the call because a §3.4 parameter default is lowered outside the block
/// stream, and `parameter real tnom = $simparam("tnom")` is the whole use.
uses_host_simparam: bool = false,

// ---- §7.3.6.5/§8 the discrete half ----
/// §7.3.6.5/§8.5 a mixed module's digital-owned values the analog block may
/// read, name → declaring token, in first-write order.
discrete_inputs: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// The module's discrete half needs the event queue (`lower_context.isMixed`).
mixed_signal: bool = false,

/// Byte range of a token — the currency every diagnostic reports in.
pub fn tokenSpan(self: *const Lowered, tok: u32) diag.Span {
    return Lexer.tokenSpan(self.src, self.tok_starts, tok);
}

/// The name codegen prints for a node_order index (naming.zig unit targets).
pub fn nodeName(self: *const Lowered, idx: u16) []const u8 {
    return if (idx == Lower.ground) "gnd" else self.node_order.items[idx];
}

/// §9.15 Table 9-27 — see `lower_sysfunc.simparamValueIn`.
pub fn simparamValue(self: *const Lowered, name: []const u8) ?f64 {
    return lower_sysfunc.simparamValueIn(&self.directives, name);
}
