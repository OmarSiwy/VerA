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
/// The module being lowered (§6.2).
module: ?*const Ast.ModuleDecl = null,
/// §6.7 path → flat name, from elaboration.
hier_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// §9.15/§9.16, indexed by `Ast.AnalogBlock.unit`: the module a block was
/// WRITTEN in and the instance path it was inlined at (`Design.units`).
unit_paths: []const Elaborate.UnitPath = &.{},
/// §3.4 the constant table as lowering left it: every module parameter's
/// folded value, by flat name. The VPI's `vpiParameter` values.
consts: std.StringHashMapUnmanaged(Lower.Const) = .empty,
/// §3.6.3 declared vector nets and §3.12 vector branches, by base name — the
/// only place a range survives scalarisation (see `Lower.vectors`).
vectors: std.StringHashMapUnmanaged(Lower.VecRange) = .empty,

// ---- §1.3.1 the unknown table ----
/// The U-enum index space: ports (§6.5) first, then internal nodes (§3.6.3),
/// then branch-flow unknowns (§5.4.2). Append-only ⇒ stable.
node_order: std.ArrayList([]const u8) = .empty,
/// What each node_order slot IS, as opposed to what it is SPELLED.
node_kind: std.ArrayList(Lower.NodeKind) = .empty,
/// Discipline name per node_order slot (`""` when undeclared, §3.9).
node_disciplines: std.ArrayList([]const u8) = .empty,
/// §6.5.2.2 port direction per node_order slot (`.unspecified` for an internal
/// net or a port whose direction is never declared).
node_dir: std.ArrayList(Ast.Direction) = .empty,
num_ports: usize = 0, // §6.5
/// §5.4.2 branch-flow identity: the node PAIR → its unknown's node_order slot.
flow_unknowns: std.AutoHashMapUnmanaged(Lower.FlowKey, u16) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the port's KCL sum.
port_probes: std.ArrayList(Lower.PortProbe) = .empty,
/// §3.6.3.2 the net_decl_assignments of this module, in declaration order and
/// already folded.
nodesets: std.ArrayList(Lower.Nodeset) = .empty,
disciplines: std.StringHashMapUnmanaged(Lower.DisciplineInfo) = .empty, // §3.6.2

// ---- §3.4 the model card and §5.6 the equations ----
params: std.ArrayList(Lower.ParamInfo) = .empty, // §3.4
/// §3.4.7 the alias side of the parameter map, in declaration order: each
/// alias is a field of its own on the model card.
aliases: std.ArrayList(Lower.Alias) = .empty,
contributions: std.ArrayList(Lower.Contribution) = .empty, // §5.6

// ---- instance state ----
/// §5.10 module variables assigned inside an `@(<event>)` body: each gets a
/// persistent `Instance` slot.
held_vars: std.ArrayList(Lower.HeldVar) = .empty,
/// §9.17.3 the user-function `$limit` state, one entry per ACCESS FUNCTION.
limit_slots: std.ArrayList(Lower.LimitSlot) = .empty,
/// §9.21 first-call sample counts, one entry per array-source call site.
table_samples: std.ArrayList(u32) = .empty,
/// §9.13.1 how many call sites took the SEEDLESS form; one `Instance` latch
/// slot each.
rng_auto_sites: u32 = 0,

// ---- live roots: values no contribution reads, kept alive by codegen ----
/// §9.4 display tasks, in source order (the driver's W0850 reads them).
displays: std.ArrayList(Lower.Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing.
display_root: Mir.Value = .f_zero,
/// Source-order chain over table captures and distribution checks; a core
/// live-out.
table_effect: Mir.Value = .f_zero,
/// §9.17.1 rejection belongs to the Newton iteration, not timestep history.
reject_iteration_place: ?Ssa.Place = null,
reject_iteration: Mir.Value = .zero,

// ---- which kernels the device needs ----
/// §9.5.3/§9.5.4.2 `$sformat`/`$swrite`/`$sscanf` → `str_kernels.zig`.
uses_str_tasks: bool = false,
/// §9.5.1–§9.5.8 the file-descriptor family → `file_kernels.zig`.
uses_file_tasks: bool = false,
/// §9.21 `$table_model` → `table_kernels.zig`.
uses_table_model: bool = false,
/// §9.13 Table 9-10's distributions → `rng_kernels.zig`.
uses_rng: bool = false,
/// §9.15 the model queries the runtime Newton iteration number.
uses_newton_iter: bool = false,
/// §9.15 the model reads a `$simparam` whose value is the HOST's
/// (`simparamHostField`), so codegen owes its Model the reserved field.
uses_host_simparam: bool = false,

// ---- §7.3.6.5/§8 the discrete half ----
/// §7.3.6.5/§8.5 a mixed module's digital-owned values the analog block may
/// read, name → declaring token, in first-write order.
discrete_inputs: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// The module's discrete half needs the event queue.
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
