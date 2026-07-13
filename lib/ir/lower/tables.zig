//! `Lowered`: the tables lowering hands to every later stage, as one value.
//!
//! `Lower` builds these (with its symbol tables, SSA builder and scopes); this is the
//! part that outlives it. Every later stage takes a `*const Lowered`, so none can reach
//! lowering state. Every buffer is arena-owned, like the MIR it indexes.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");
const Mir = @import("../mir.zig");
const Elaborate = @import("../elaborate.zig");
const Lower = @import("../lower.zig");
const lower_sysfunc = @import("sysfunc.zig");

/// Lowering's output; later stages read it through `*const Lowered`.
pub const Lowered = @This();

/// One explicit D2A event term (`discrete_events`): §7.3.4's `posedge`,
/// `negedge` or bare `expression` over a digital name, or §5.10.4's named event
/// triggered by the digital context.
pub const DiscreteEvent = struct {
    /// The digital variable, net or named event the term watches.
    name: []const u8,
    edge: enum { any, posedge, negedge },
    /// The `Model` field the host sets for the solve the event is delivered to.
    param: []const u8,
};

/// §7.8.4 one port an automatic connect module was inserted on (`inserts`).
pub const Inserted = Elaborate.Inserted;

/// One §9.7.3 `$fatal`/`$error` call in the analog context (`status_sites`).
pub const StatusSite = struct {
    fatal: bool,
    /// The format string, "" when the call has none.
    fmt: []const u8,
    /// The call token, for the site's source line.
    tok: u32,
};

/// How many numeric arguments a status site carries (`status_args`).
pub const status_arg_max = 4;

/// One row of `nodes`.
pub const Node = struct {
    /// The unknown's unique spelling (codegen's `U` member).
    name: []const u8,
    /// What the slot is, as opposed to how it is spelled (see `NodeKind`).
    kind: Lower.NodeKind,
    /// Discipline name (`""` when undeclared, §3.9). A name and not an index,
    /// because a node may name a discipline `disciplines` has no row for.
    disc: []const u8,
    /// §7.2.4 minimum potential tolerance over the signal's continuous net
    /// segments. This is node metadata, not a net's §5.5.3 nature attribute.
    potential_abstol: ?f64 = null,
    /// §6.5.2.2 port direction (`.unspecified` for an internal net or an undeclared
    /// direction). An `input` or `output` port is a §1.3.4 signal-flow port; which
    /// of the two decides §1.3.4.1's contribution-target rule (E0425).
    dir: Ast.Direction,
};

/// A device-side facility the model uses. Each gates a kernel file or an
/// `Instance`/`Model` field in codegen; `uses` is the set.
pub const Kernel = enum {
    /// §9.5.3/§9.5.4.2 `$sformat`/`$swrite`/`$sscanf` → `str_kernels.zig`.
    /// A flag, not a site list: codegen finds each site by its MIR instruction.
    str_tasks,
    /// §9.5.1-§9.5.8 the file-descriptor family → `file_kernels.zig`, only in the
    /// `display == .emit` artifact. A descriptor table is a host facility; without one
    /// the device answers as §9.5.1 does for a file that "cannot be opened": zero.
    file_tasks,
    /// §9.21 `$table_model` → `table_kernels.zig`.
    table_model,
    /// §9.13 one of Table 9-10's 17 probabilistic distributions → `rng_kernels.zig`.
    rng,
    /// §9.15 the model queries the runtime Newton iteration number.
    newton_iter,
    /// §9.15 the model reads a `$simparam` whose value is the HOST's
    /// (`host_simparams`), so codegen owes its Model that reserved field. Set
    /// at the call, because a §3.4 parameter default such as
    /// `parameter real tnom = $simparam("tnom")` is lowered outside the block stream.
    host_tnom,
    host_reltol,
    host_abstol,
    host_vntol,
    /// §9.17.1 `$discontinuity(-1)`: `reject_iteration` is a live root and the
    /// device carries the rejection flag.
    reject_iteration,
    /// §9.19 a top-level `$port_connected`: the Model owes the host-written
    /// connection mask `port_connected__`.
    port_mask,
    /// §9.12 `$test$plusargs`/`$value$plusargs`: the `Instance.plusargs`
    /// field the host writes and the `zPlusarg` search over it.
    plusargs,
};

// ---- the source, for diagnostics and host facts ----
/// The parsed (and elaborated) file every `Ast` id below indexes.
file: *const Ast.SourceFile,
/// Preprocessed source and the lexer's `.start` column, kept only so a token
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
/// written in and the instance path it was inlined at. Flattening erases both,
/// so elaboration publishes them (`Design.units`).
unit_paths: []const Elaborate.UnitPath = &.{},
/// §3.4 the constant table as lowering left it: every module parameter's
/// folded value, by flat name. The VPI's `vpiParameter` values.
consts: std.StringHashMapUnmanaged(Lower.Const) = .empty,
/// §3.6.3 declared vector nets and §3.12 vector branches, by base name.
/// Vectors are scalarised (`electrical [3:0] p` interns nodes `p[3]`..`p[0]`), so
/// this map is the only place a range survives. It answers whether a name is a
/// vector and whether an index is one of its elements (E0351, E0352).
vectors: std.StringHashMapUnmanaged(Lower.VecRange) = .empty,

// ---- §1.3.1 the unknown table ----
/// The U-enum index space, one row per solver unknown: ports (§6.5) first,
/// then internal nodes (§3.6.3), then branch-flow unknowns (§5.4.2).
/// Append-only, so row indices are stable. SoA because every consumer reads one column.
///
/// A row index is a `u16` everywhere (`ground` is its max), not the device's `u8`:
/// lowering holds more than 256 unknowns so codegen can refuse the module with a
/// diagnostic instead of overflowing here.
nodes: std.MultiArrayList(Node) = .{},
/// §6.5 the port rows are `nodes[0..num_ports]`. A `u16` because it is a row
/// index (see `nodes`).
num_ports: u16 = 0,
/// §5.4.2 branch-flow identity: the node pair → its unknown's `nodes` row.
/// Keyed on the pair, so `I(a)` and `I(a,gnd)` stay distinct when a plain net is
/// spelled `gnd` (see `flowUnknown`).
flow_unknowns: std.AutoHashMapUnmanaged(Lower.FlowKey, u16) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the module's KCL sum
/// at `port`; codegen emits that row. Append-only, so the order is deterministic.
port_probes: std.ArrayList(Lower.PortProbe) = .empty,
/// §3.6.3.2 the net_decl_assignments of this module, in declaration order and
/// already folded. Sparse (most modules declare none), so codegen emits the
/// optional `u_nodeset` table only when this is non-empty.
nodesets: std.ArrayList(Lower.Nodeset) = .empty,
disciplines: std.StringHashMapUnmanaged(Lower.DisciplineInfo) = .empty, // §3.6.2

// ---- §3.4 the model card and §5.6 the equations ----
params: std.ArrayList(Lower.ParamInfo) = .empty, // §3.4
/// §3.4.7 parameter aliases, in declaration order, for the model card. An alias
/// carries an override (`#(.trise(5))` and `#(.dtemp(5))` mean the same thing), so it
/// needs its own card field; `params` has one entry per real parameter, and
/// `param_index` does not say which name is the alias.
aliases: std.ArrayList(Lower.Alias) = .empty,
contributions: std.ArrayList(Lower.Contribution) = .empty, // §5.6
/// §5.4.1 the OTHER instances whose `<+` a row accumulated
/// (`Contribution.shared`): `row` is a `contributions` index, `unit` the
/// instance. The row's own `unit` is not repeated here. Each still declares its
/// own unnamed branch (§5.4.2), which the VPI's §11.6.6 model lists.
contrib_sharers: std.ArrayList(struct { row: u32, unit: u32 }) = .empty,
/// §5.6.1.2 every charge site, in source order (`Lower.ChargeSite`).
charge_sites: std.ArrayList(Lower.ChargeSite) = .empty,

// ---- instance state ----
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable retains its value between analog evaluations
/// (`@(cross(...)) x = V(p);`), which an SSA place re-initialised every evaluation
/// cannot express, so each gets a persistent `Instance` slot.
held_vars: std.ArrayList(Lower.HeldVar) = .empty,
/// §5.10.3.3 final start/period expressions, distinct from the call operands
/// which decided whether to execute the event body. Only changed controls
/// have a row; codegen reads these for the following breakpoint.
timer_controls: std.AutoHashMapUnmanaged(Mir.Inst, [2]Mir.Value) = .empty,
/// §3.2.2 the arrays some subscript indexes at run time. Each is ONE storage
/// of `len` elements (dimensions flattened in declaration order), reached
/// through `Mir.Opcode.anew`/`fload`/`iload`/`store` instead of one SSA place
/// per element; `anew` names its array by index into this list.
mem_arrays: std.ArrayList(Lower.MemArray) = .empty,
/// §9.17.3 the user-function `$limit` state, one entry per ACCESS FUNCTION.
/// Collected by `scanCallSites` before the analog block is lowered.
limit_slots: std.ArrayList(Lower.LimitSlot) = .empty,
/// VerA's `vera_timepoint` statements (§2.9), in source order: each one's
/// per-timepoint cache in `Instance` (`Lower.TpBlock`).
timepoints: std.ArrayList(Lower.TpBlock) = .empty,
/// First-call sample counts, one entry per array-source call site.
table_samples: std.ArrayList(u32) = .empty,
/// §9.13.1 implementation-chosen starting seeds for omitted-seed call sites.
/// Each `Instance` latch advances on the accepted step. Explicit constant and
/// parameter seeds instead use held SSA storage, updated by the executed call.
rng_auto_seeds: std.ArrayList(i64) = .empty,

// ---- live roots: values no contribution reads, kept alive by codegen ----
/// §9.4 display tasks, in source order. Nothing reads a display call's result, so
/// `display_root` keeps them live (see `finishDisplays`).
displays: std.ArrayList(Lower.Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// Source-order chain over table captures and required runtime checks; a core
/// live-out.
table_effect: Mir.Value = .f_zero,
/// §9.17.1 rejection belongs to the Newton iteration, not timestep history:
/// the final value of the rejection flag, meaningful when
/// `uses.contains(.reject_iteration)`.
reject_iteration: Mir.Value = .zero,
/// VerA's `$vera_reject_step`: the earliest retry time any call asked for
/// (+inf when none ran), or `.undef` when the module never calls it.
/// `updateState` turns it into `contract.UpdateResult.request_reject_at`.
reject_step: Mir.Value = .undef,
/// §9.7.3 `$fatal`/`$error` in the analog context, in source order: a
/// device (`--display=drop`) reports the first one an evaluation reaches
/// through `Instance.vera_status__` (`contract.StatusSite`).
status_sites: std.ArrayList(StatusSite) = .empty,
/// The status code the evaluation ends with: 0 when no site ran, else the
/// FIRST site's `(severity << 24) | (site + 1)`. `.undef` without sites.
status: Mir.Value = .undef,
/// The first site's numeric arguments, after its format string (0 past
/// its count, and for a string argument).
status_args: [status_arg_max]Mir.Value = @splat(.undef),

// ---- which kernels the device needs ----
/// The device-side facilities the model needs (see `Kernel`).
uses: std.EnumSet(Kernel) = .initEmpty(),

// ---- §7.3.6.5/§8 the discrete half ----
/// §7.3.6.5/§8.5 a mixed module's digital-owned values the analog block may
/// read, name → declaring token, in first-write order.
discrete_inputs: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §8.5 / §8.5.3.6 explicit D2A: every digital event term of an analog event
/// control, keyed by the term's expression. Each is a host-written `Model`
/// flag (`DiscreteEvent.param`), nonzero for the solve at the digital tick the
/// event occurred in.
discrete_events: std.AutoArrayHashMapUnmanaged(Ast.ExprId, DiscreteEvent) = .empty,
/// §8.5.3.6 the digital values read INSIDE a statement guarded by an explicit
/// D2A event: each is read from a `<name>__1b` `Model` field holding the value
/// after region 1 of the event's tick, not the live one region 3b sees.
discrete_snaps: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §7.3.2 the `discrete_inputs` the analog block reads through `===`, `!==`
/// or a `case` subject: their unknown plane arrives in a `<name>__xz` `Model`
/// field beside the value plane, and an x or z there is not an error.
discrete_xz: std.StringArrayHashMapUnmanaged(void) = .empty,
/// §7.3.6.4 / §7.3.1 the other direction: module variables a digital
/// expression reads and the discrete context does not assign (the analog
/// block's), name → first reading token. The mixed runner copies each one's
/// §5.10 held value into the digital engine after every accepted solution.
discrete_reads: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §6.3.4 scalar parameters read by the discrete source, including defaults
/// they depend on. The mixed host transports selected real values from the
/// derived model card; unrelated analog parameters need no digital storage.
discrete_params: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// The module's discrete half needs the event queue (`lower_context.isMixed`).
mixed_signal: bool = false,
/// §7.8.4 the connect modules elaboration inserted (see `Elaborate.Design.inserts`).
inserts: []const Inserted = &.{},

/// Returns the byte range of token `tok`, for a diagnostic.
pub fn tokenSpan(self: *const Lowered, tok: u32) diag.Span {
    return Lexer.tokenSpan(self.src, self.tok_starts, tok);
}

/// Returns the name codegen prints for a `nodes` row, or "gnd" for `ground`.
pub fn nodeName(self: *const Lowered, idx: u16) []const u8 {
    return if (idx == Lower.ground) "gnd" else self.nodes.items(.name)[idx];
}

/// Returns the compile-time value of `$simparam(name)`, or null (LRM §9.15 Table 9-27).
pub fn simparamValue(self: *const Lowered, name: []const u8) ?f64 {
    return lower_sysfunc.simparamValueIn(&self.directives, name);
}
