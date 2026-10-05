//! Elaboration: a parsed `Ast.SourceFile` → one flattened `Design` whose top
//! module holds a renamed copy of every reachable instance, so nothing after
//! this stage sees hierarchy. LRM §6.2.2 instantiation, §6.3 parameter
//! overrides and §6.3.1 defparam, §6.4 paramsets, §6.6 if-generate, §6.7
//! hierarchical names (`Design.names`), §7.8 connect-module insertion, and
//! Annex F.2 discipline resolution.
//!
//! The spine, `elaborate` then `Flatten.run`:
//!
//!     alias.checkSource           §3.4.7 alias reads, before anything folds
//!     gen_instances, pickTop      §6.6 table, §6.2.2 the root
//!     names / resolve checks      E.3.3, §7.7, A.2.1.3, §7.4.2 (every module)
//!     run: seed the top           its own declarations, unrenamed
//!       instance.walkInstances    per level: override.collectDefparams,
//!                                 resolve.collectOoc, insert.plan, then per
//!                                 instance inlineInstance (ports, overrides,
//!                                 names, clone.*, recurse)
//!       resolve post-passes       E.3.2.2 primitive ports, F.2.1 step 4
//!       override.reportUnused...  §6.3.1 E0907
//!       publish `fate`            one `Ast.ModuleDecl`, plus `Design` tables
//!       alias.checkFlat           §3.4.7 hierarchical alias reads
//!
//! Who writes which `Flatten` table: the synthesized declaration lists,
//! `unit_paths`, `names`, `implicit_nets`, `unconnected_inputs`,
//! `port_concats`, `port_widths`, `ps_hidden` and `prim_ports` are
//! `instance.zig`'s (with `clone.cloneParams` appending `params`/
//! `aliasparams`); `defparams` and `paramset_defparams` are `override.zig`'s;
//! `nets`, `disc_of`, `segs`, `port_resolved`, `ooc` and
//! `signal_disciplines` are `resolve.zig`'s (`addNet` is the only net
//! append); `inserts` is `insert.zig`'s; `selection_params` is
//! `paramset.zig`'s; `attribute_disciplines`, `pending_attributes` and
//! `expression_aliases` are written by `clone.zig` during the clone and
//! settled by `resolve.resolveMultiCandidates`. `unit` is not a table but the
//! namespace in force: `inlineInstance` pushes and pops it, and a pass that
//! clones text written in another scope (`override.collectOverrides`,
//! `paramset.paramsetOverrides`, `clone.paramsetOomr`) swaps it and restores.

const std = @import("std");
const hier_param = @import("hier_param.zig");
const elab_alias = @import("elaborate/alias.zig");
const elab_clone = @import("elaborate/clone.zig");
const elab_insert = @import("elaborate/insert.zig");
const elab_instance = @import("elaborate/instance.zig");
const elab_names = @import("elaborate/names.zig");
const elab_override = @import("elaborate/override.zig");
const elab_paramset = @import("elaborate/paramset.zig");
const elab_resolve = @import("elaborate/resolve.zig");
const elab_segment = @import("elaborate/segment.zig");
/// §6.7 a hierarchical expression → the flat name it denotes; lowering's
/// path resolution and the §3.4.7 alias check share it. See
/// `elaborate/names.zig`.
pub const flatReference = elab_names.flatReference;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const diag = @import("diag");
const discipline = @import("discipline_rules.zig");

/// `NoModule`: A.1.2 lets a source_text hold no module_declaration at all
/// (a file of `discipline`/`nature` declarations is legal), but a device needs
/// one. The caller reports E1001, since "no module" is only an error relative
/// to what was asked for.
///
/// `DiagnosticsReported`: something in the instance tree was diagnosed; the
/// bag holds the diagnostics and no design is returned.
pub const Error = error{ OutOfMemory, NoModule, DiagnosticsReported };

/// The separator between levels of a flattened hierarchical name (LRM §6.7).
///
/// A period, as §6.7's `hierarchical_identifier` writes it, so a flat name in
/// a diagnostic or an emitted identifier reads like the source reference. An
/// escaped identifier may contain a period (§2.8.1, `\x.y `), but
/// `parser.internTok` interns that period as a space, so a period in a flat
/// name is always a join and the mangling is injective.
pub const sep = '.';

/// §6.2.2 how deep the instance tree may go before the walk gives up.
///
/// A cycle is caught by name first (E0905 keeps the module stack), so hitting
/// the limit means a deep but finite design. The limit turns that into a
/// diagnostic (E1018) instead of a stack overflow.
pub const max_depth = 64;

/// The elaborated design lowering walks: one module with the hierarchy already
/// applied. Runtime dynamic hierarchical access (`$simprobe` with a computed
/// path) cannot be answered from it; every §6.7 reference must resolve here.
pub const Design = struct {
    /// The root of §6.2.2's instance tree, with every reachable child inlined:
    /// the module whose ports are the device's terminals.
    top: *const Ast.ModuleDecl,
    /// §6.7 hierarchical path → the flat name that path denotes.
    ///
    /// Holds only the rows that are not the identity: the flat name is the
    /// path joined with `sep`, so every reader does `get(p) orelse p`. The rows
    /// are connected child ports: `u.a` bound to parent net `p` has no node of
    /// its own, and §6.7.1 still lets `V(u.a)` name it.
    ///
    /// Empty for a tree of one: with nothing renamed there is no path but the
    /// module's own names, and those resolve without it.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// §3.6.5's STRUCTURAL implicit nets: "Nets can be used in structural
    /// descriptions without being declared." One entry per instance port actual
    /// naming a net the instantiating module never declared.
    ///
    /// Reported, not judged: the child's declaration already supplies the
    /// discipline (§7.4), and legality is IEEE 1364 §19.2 `default_nettype`, a
    /// positional directive this pass cannot see (`Lower.rejectImplicitNet`).
    implicit_nets: []const NameSite = &.{},
    /// §6.2.2 "a blank port connection shall represent the situation where the
    /// port is not to be connected", for an `input` port. One entry per such
    /// port, naming the internal net the flatten gave it.
    ///
    /// Judged later for the same reason: IEEE 1364 §19.9 `unconnected_drive`
    /// is positional text (`Lower.applyUnconnectedDrive`).
    unconnected_inputs: []const NameSite = &.{},
    /// §9.15 Table 9-28's two hierarchy rows, indexed by `Ast.AnalogBlock.unit`:
    /// "module" is "the name of the module from which $simparam$str is called"
    /// and "instance" is "the hierarchical name of the instance". Flattening
    /// erases both, so the walk publishes them here. §9.16's sibling scope
    /// ("in the parent of the current instance") reads `path` too.
    units: []const UnitPath = &.{},
    /// §7.8.4 every port an automatic connect module was inserted on, for the
    /// mixed-signal runner: its digital engine elaborates the SOURCE hierarchy,
    /// in which the bridges do not exist.
    inserts: []const Inserted = &.{},
    /// §6.5.7.1 "a vector port can be connected to a vector net or
    /// concatenated net expression of the matching width". One entry per port
    /// connected to a concatenation: the child's vector, renamed to a flat
    /// name of its own, whose element k (declaration order, msb first per IEEE
    /// 1364 §12.3.9.2) is the parent net `elems[k]`. Lowering interns no node for it: each element
    /// aliases its net's node (`Lower.lowerModule`).
    port_concats: []const PortConcat = &.{},
    /// §6.5.7.1 "The sizes of the ports and net must match." One entry per
    /// port bound to a net: the bound flat net and the child's declared range
    /// (null for a scalar port), for lowering to fold and compare.
    port_widths: []const PortWidth = &.{},
    /// §7.2.4's continuous segments of one signal retain their local
    /// disciplines even when flattening gives the signal one net declaration.
    /// Lowering folds their potential tolerances into the shared node's minimum.
    signal_disciplines: []const SignalDiscipline = &.{},
    /// §5.5.3 attribute reads on bound ports keep the source segment's
    /// discipline even after the expression names the shared flattened net.
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    /// §4.4 accesses in a child that `names.localAccess` already judged
    /// against the child's own declaration, on a node whose discipline binds
    /// no nature for that half (§3.11.1's natureless or domainless parent).
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    /// §6.4.3 "If a paramset variable without a description has the same name
    /// as a module output variable, the module output variable shall not be
    /// available for instances using the paramset." The flat names of those
    /// variables, for §9.16's `$simprobe` to treat as unresolvable.
    ps_hidden: []const []const u8 = &.{},
    /// §6.3.1/§6.4 defparams encountered below a paramset instance, with the
    /// generate condition that decides whether that hierarchy exists. Lowering
    /// judges them after the final parameter values (including --param) exist.
    paramset_defparams: []const ParamsetDefparam = &.{},
    /// §6.4.2 values read while choosing an overloaded paramset. The host must
    /// re-elaborate when these shape parameters change, as for generate schemes.
    selection_params: []const Ast.StrId = &.{},
    /// §9.18 Table 9-29 domains to check at card time (`SystemCheck`).
    system_checks: []const SystemCheck = &.{},
};

/// A defparam is forbidden only in an instantiated paramset hierarchy:
/// §6.6.2 leaves an unselected generate arm out of the model. Flattening keeps
/// both arms, so the flattened gate travels with the source diagnostic site.
pub const ParamsetDefparam = struct {
    main_tok: u32,
    instance: []const u8,
    gate: Ast.ExprId,
};

/// One `Design.port_widths` row: a port bound to a flat net, for the §6.5.7.1
/// size check.
pub const PortWidth = struct {
    net: []const u8,
    /// Cloned into the flat namespace, as `PortConcat.range` is.
    range: ?Ast.Dim,
    main_tok: u32,
};

/// One hierarchical net segment attached to the flattened signal `net`.
pub const SignalDiscipline = struct { net: []const u8, discipline: []const u8 };

/// One `Design.port_concats` row: a vector port bound to a concatenation of
/// parent nets (LRM §6.5.7.1).
pub const PortConcat = struct {
    /// The port's flat name.
    name: []const u8,
    /// The child's declared range, cloned into the flat namespace so a
    /// parameter in it folds against the instance's own overrides.
    range: Ast.Dim,
    elems: []const []const u8,
    main_tok: u32,
};

/// One port §7.8.4 re-pointed at a connect module (`elaborate/insert.zig`), by
/// name. In the module instance at `path` (instance prefix, separator
/// included, empty at the top), port `port` of child `inst` is connected to
/// the bridge `name`'s `lower_port` instead of its upper connection, and the
/// bridge (an instance of `module`) takes that upper connection on
/// `upper_port`. Merged ports share a bridge, so `name` repeats. The segment
/// between the child and the bridge is `name ++ sep ++ lower_port`.
pub const Inserted = struct {
    path: []const u8,
    inst: []const u8,
    port: []const u8,
    module: []const u8,
    name: []const u8,
    upper_port: []const u8,
    lower_port: []const u8,
};

/// One entry of `Design.units`. `path` is the instance prefix, separator
/// included and empty at the top, so `path ++ local` is the flat name.
pub const UnitPath = struct {
    module: []const u8,
    path: []const u8,
    /// The definition this unit was inlined FROM: the module `findModule`
    /// named, or the end of the §6.4.2-selected paramset's chain. Published so
    /// the VPI's `vpiDefName` and ports (Clause 11) read the answer instead of
    /// re-resolving the name by a second rule.
    decl: *const Ast.ModuleDecl,
};

/// A name the flatten wants a later stage to judge, and the token it was
/// written at. The token is what a positional compiler directive is looked up
/// by, and what a diagnostic points at.
pub const NameSite = struct { name: []const u8, main_tok: u32 };

/// §9.18 a hierarchical system parameter's specified value that reads the
/// model card, so Table 9-29's "Allowed values" can only be checked when
/// the host writes the card (codegen's `checkCard`). `value` is in the flat
/// namespace; `name` is what the check reports: `path$kind`, or a top-level
/// alias's own spelling.
pub const SystemCheck = struct { kind: hier_param.Kind, value: Ast.ExprId, name: []const u8 };

/// Everything elaboration needs from the compilation. `file` is MUTABLE because
/// flattening appends: new interned names (§6.7 paths), cloned expression rows
/// and cloned statements all land in the stores the parser filled. Nothing is
/// ever rewritten in place, so every id the parser handed out stays valid.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    file: *Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
    param_overrides: []const ParamOverride = &.{},
    discipline_resolution: DisciplineResolution = .basic,
};

/// §7.4.4 "There are two modes for this method of resolution, basic (the
/// default) and detail"; F.2.2: "The selection of this algorithm instead of
/// the default shall be controlled by a simulator option" (VerA's is
/// `--discipline-resolution=`). The mode decides where connect modules go
/// (`segment.down`, read by `insert.plan`).
pub const DisciplineResolution = enum { basic, detail };

/// §3.4 compile-time overrides, shared with Lower.Options. Elaboration needs
/// their final values when a §6.4.2 overload choice depends on a top parameter.
pub const ParamOverride = struct { name: []const u8, value: f64 };

/// Elaborates `ctx.file` into the design lowering walks. Every pointer in the
/// result points into `ctx.arena`. A top with no instances, defparams or
/// generate instances is returned by pointer, exactly as parsed. §6.5.7.1's
/// distribution of a vector net across an instance array is not supported.
pub fn elaborate(ctx: Ctx) Error!Design {
    if (ctx.file.userModules().len == 0) return error.NoModule;
    try elab_alias.checkSource(ctx); // §3.4.7, before any folding or cloning

    // §6.6 each module's generate-block instances, walked once: `pickTop`,
    // the tree-of-one test and every inlined instance read them.
    const gen_instances = try ctx.arena.alloc([]const Ast.Instance, ctx.file.modules.len);
    for (ctx.file.modules, gen_instances) |*m, *out| {
        var list: std.ArrayList(Ast.Instance) = .empty;
        for (m.analog) |blk| try elab_instance.genInstanceList(ctx.file, blk.body, ctx.arena, &list);
        out.* = list.items;
    }

    const top = try pickTop(ctx, gen_instances);

    var f: Flatten = .{ .ctx = ctx, .gen_instances = gen_instances };
    try elab_names.warnSpiceShadows(&f);
    try elab_names.warnRedefinedModules(&f); // IEEE 1364-2005 §13.2.1.1 W1152
    // §7.7's names are judged whether or not the design has a hierarchy to
    // resolve: a `connectrules` block is a description of the COMPILATION
    // (A.1.2), not of the top module, so the tree-of-one shortcut below must
    // not skip a misspelled connect module or discipline in one.
    try elab_resolve.checkConnectRules(&f);
    try elab_resolve.checkNetDisciplines(&f); // A.2.1.3, every module: see there
    // §7.4.2 "the real-value nets shall obey the rules imposed by 3.7": the
    // same structural check the digital runner makes (E0918/E0919).
    try @import("frontend").wreal.check(ctx.file, ctx.tok_starts, ctx.bag);
    if (ctx.bag.failed()) f.had_error = true;

    // A tree of one goes to lowering by pointer, untouched. A `defparam` with
    // no instance still takes the flatten: §6.3.1's path then names nothing,
    // and the flatten is where that E0907 is reported.
    if (top.instances.len == 0 and top.defparams.len == 0 and f.genInstancesOf(top).len == 0) {
        if (f.had_error) return error.DiagnosticsReported;
        try elab_alias.checkFlat(ctx, top, top.aliasparams);
        return .{ .top = top };
    }

    return f.run(top);
}

/// Which module is the device (§6.2.2): the first user module, in source
/// order, that nothing instantiates. A child may be declared before its
/// parent. Several roots are not diagnosed: A.1.2 lets a source_text hold
/// unrelated descriptions and §6.2.1 gives no rule for choosing between them.
///
/// `gen_instances` is `Flatten.gen_instances`. Every instantiated name is
/// collected once, so the choice costs one pass over the instances rather
/// than one per candidate.
fn pickTop(ctx: Ctx, gen_instances: []const []const Ast.Instance) Error!*const Ast.ModuleDecl {
    const file = ctx.file;
    // Annex E: a candidate is a module the USER wrote. The shipped Table E.1
    // primitives instantiate nothing, so all nineteen are roots of the instance
    // graph and one of them would win every time. They still count as
    // instantiators, so every module's instances are collected.
    var instantiated: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    for (file.modules, gen_instances) |*other, gen| for ([_][]const Ast.Instance{ gen, other.instances }) |list| for (list) |inst| {
        try instantiated.put(ctx.arena, inst.module, {});
        // §6.4 an instance that names a paramset is an incoming edge on
        // the module the paramset specializes.
        for (file.paramsets) |ps| {
            if (ps.name != inst.module) continue;
            // §6.4 "A chain of paramsets may be defined, but the last
            // paramset in the chain shall reference a module": follow
            // the second identifier while it keeps naming a paramset.
            // Bounded by the paramset count, so a cycle terminates.
            var target = ps.target;
            for (0..file.paramsets.len) |_| {
                target = for (file.paramsets) |p2| {
                    if (p2.name == target) break p2.target;
                } else break;
            }
            try instantiated.put(ctx.arena, target, {});
        }
    };
    for (file.userModules()) |*m| {
        // §7.6: a connect module is placed by the insertion phase, not a
        // design root. Insertion runs later, during the walk, so here every
        // connect module looks like a root. Skipped in both loops, so a file
        // of only connect modules is `NoModule`.
        if (m.is_connect) continue;
        // IEEE 1364-2005 §13.2.1.1 the last same-named module is the cell.
        if (!instantiated.contains(m.name)) return lastNamed(file, m);
    }
    // Every module is instantiated by some module, so the graph is all cycles.
    // Start at the first and let E0905 name the one that closes.
    for (ctx.file.userModules()) |*m| if (!m.is_connect) return lastNamed(file, m);
    return error.NoModule;
}

fn lastNamed(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl) *const Ast.ModuleDecl {
    var last = m;
    for (file.userModules()) |*o| if (o.name == m.name) {
        last = o;
    };
    return last;
}

// ---------------------------------------------------------------------------
// The flatten
// ---------------------------------------------------------------------------

/// One name binding in the flattened namespace: what a child's local name is
/// called after the join. §6.7's path table, in the direction the clone needs.
const Rename = std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId);

/// What the flatten does with one field of `Ast.ModuleDecl`.
const Fate = enum {
    /// The device's own: the top's value, as parsed.
    top,
    /// The top's entries followed by every inlined instance's, renamed into the
    /// flat namespace by `inlineInstance`. `Flatten` holds a list of the same
    /// name, and `run` publishes it.
    merged,
    /// Applied by the walk and gone after it; nothing downstream reads it.
    consumed,
};

/// Every field of `Ast.ModuleDecl`, classified. `EnumFieldStruct` with no
/// default makes each entry required, so a field added to `ModuleDecl` does
/// not compile until someone decides what a child's copy of it becomes. `run`
/// builds its output from this table, so the two cannot drift.
const fate: std.enums.EnumFieldStruct(std.meta.FieldEnum(Ast.ModuleDecl), Fate, null) = .{
    .name = .top,
    .ports = .top, // §6.5 the device's terminals are the top's
    .params = .merged,
    .aliasparams = .merged,
    .vars = .merged,
    .nets = .merged,
    .branches = .merged,
    .instances = .consumed, // §6.2.2 inlined; lowering must not elaborate them again
    .defparams = .consumed, // §6.3.1 applied to the parameter each names
    .genvars = .merged,
    .events = .merged,
    .functions = .merged,
    .analog = .merged,
    // §7.2.2 the discrete context. Merged: lowering reads what the analog
    // half needs of it, and the mixed runner runs it under the flat names.
    .discrete = .merged,
    .assigns = .merged,
    // Lowering reads no gate in any module; the parser's W0252 reports each.
    // Merged anyway, so a child's gate is where a top's gate is.
    .gates = .merged,
    // §7.8 pull sources, read by the digital engine only; merged like gates.
    .pulls = .merged,
    // The digital engine elaborates its own hierarchy from the source and runs
    // every task; lowering reads the top's only (what its bodies write).
    // ponytail: a child's task writes are not digital-owned to the analog side;
    // merge them (renamed like `discrete`) when a child's task needs it.
    .tasks = .top,
    // §8.5.3.5 switches, run by the digital engine; merged like gates.
    .switches = .merged,
    // A.7 specify paths and timing checks: read only by the VPI's §11.6.15
    // model, which walks each module's own declaration, never the flattened
    // one, so the flat design keeps the top's.
    .paths = .top,
    .timing_checks = .top,
    .attrs = .merged,
    // `pickTop` never picks a connect module, so this is always the top's
    // `false`; a hand-placed one (§7.1) is a child like any other.
    .is_connect = .top,
    .main_tok = .top,
};

/// The flatten's state: the synthesized module's declaration lists, the rename
/// map of the unit being cloned, and the side tables `Design` publishes. Every
/// allocation is in `ctx.arena` and lives as long as the compilation; `run`
/// hands the lists' `items` to `Design` without copying. The file header
/// names each table's writer.
pub const Flatten = struct {
    ctx: Ctx,
    /// Set by `err` and by the pre-walk checks; `run` turns it into
    /// `error.DiagnosticsReported` after the walk, so one design reports
    /// every error it has rather than the first.
    had_error: bool = false,
    /// §6.6 every module's generate-block instances (`genInstanceList`),
    /// indexed like `ctx.file.modules`; read through `genInstancesOf`.
    /// Built once by `elaborate`, read-only after.
    gen_instances: []const []const Ast.Instance,

    /// Last `Ast.AnalogBlock.unit` handed out. 0 is the top, so the first
    /// inlined instance is 1. See that field for what it is for.
    last_unit: u32 = 0,
    /// §9.15/§9.16 one entry per unit id, in issue order (so index == unit id).
    unit_paths: std.ArrayList(UnitPath) = .empty,
    /// `Design.ps_hidden`, as the walk finds them.
    ps_hidden: std.ArrayList([]const u8) = .empty,
    /// `Design.paramset_defparams`, before generate schemes have final values.
    paramset_defparams: std.ArrayList(ParamsetDefparam) = .empty,
    /// `Design.selection_params`: flat parameters a §6.4.2 overload choice
    /// read. May repeat a name; readers treat it as a set.
    selection_params: std.ArrayList(Ast.StrId) = .empty,
    /// `Design.system_checks`, as overrides are composed.
    system_checks: std.ArrayList(SystemCheck) = .empty,

    // The synthesized module's declarations, in append order.
    params: std.ArrayList(Ast.ParamDecl) = .empty,
    aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
    vars: std.ArrayList(Ast.VarDecl) = .empty,
    nets: std.ArrayList(Ast.NetDecl) = .empty,
    branches: std.ArrayList(Ast.BranchDecl) = .empty,
    genvars: std.ArrayList(Ast.StrId) = .empty,
    events: std.ArrayList(Ast.EventDecl) = .empty,
    functions: std.ArrayList(Ast.FuncDecl) = .empty,
    analog: std.ArrayList(Ast.AnalogBlock) = .empty,
    discrete: std.ArrayList(Ast.DiscreteBlock) = .empty,
    assigns: std.ArrayList(Ast.ContAssign) = .empty,
    gates: std.ArrayList(Ast.GateInst) = .empty,
    pulls: std.ArrayList(Ast.PullInst) = .empty,
    switches: std.ArrayList(Ast.SwitchInst) = .empty,
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,

    /// §6.7 path → flat name. See `Design.names`.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// See `Design.inserts`.
    inserts: std.ArrayList(Inserted) = .empty,
    /// Ports `insert.plan` bridged with nothing, judged once every net's
    /// discipline is resolved (`insert.checkUnbridged`, E0927).
    unbridged: std.ArrayList(elab_insert.Unbridged) = .empty,
    /// `segment.up`'s answers for the level `insert.plan` is planning, keyed
    /// by instance path and local net name.
    seg_up: std.StringHashMapUnmanaged(elab_segment.Seg) = .empty,
    /// The answer each port's lower connection resolved to when its parent
    /// was planned (`segment.down`), the same keys: the upper connection of
    /// the ports one level further down.
    seg_down: std.StringHashMapUnmanaged(elab_segment.Seg) = .empty,

    /// The discipline every flat net has been declared with, keyed by the flat
    /// name: §3.10's precedence orders 1 and 2 after they have been decided.
    /// Every net append goes through `addNet`, which keeps this table and
    /// `self.nets` in agreement. The top's ports are seeded first (`run`),
    /// since a discipline resolved up the hierarchy lands on one of them.
    ///
    /// One discipline per net, the answer every consumer reads. Annex F.2.1
    /// step 4.b needs the full candidate set per net, and that is `segs`.
    disc_of: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,

    /// Annex F.2.1 step 4.b's input, per flat net: EVERY discipline a child
    /// segment declared onto it, in arrival order, with the token of the first
    /// segment for the diagnostic. Fed by `resolveDiscipline` and consumed
    /// once, after the walk, by `resolveMultiCandidates`. An array
    /// hash map so the post-pass visits nets in first-binding order and a
    /// design with two errors reports them deterministically.
    segs: std.AutoArrayHashMapUnmanaged(Ast.StrId, Segs) = .empty,

    /// The flat nets whose discipline came from a bound port rather than a
    /// declaration: §3.6.5's implicit nets, the set §7.4.4.1's continuous-wins
    /// rule may overrule without overruling a real declaration.
    port_resolved: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,

    /// E.3.2's LAST source, deferred: every bound port of an analog primitive,
    /// whose own `electrical` is only "the default analog primitive" and so
    /// binds its net after the walk, and only if nothing else did (E.3.2.2 "If
    /// there are no continuous disciplines defined on the net segment").
    prim_ports: std.ArrayList(struct { path: []const u8, port: Ast.Port, bound: Ast.StrId }) = .empty,

    /// `Design.implicit_nets` / `Design.unconnected_inputs`, collected on the
    /// way through and published unchanged.
    implicit_nets: std.ArrayList(NameSite) = .empty,
    unconnected_inputs: std.ArrayList(NameSite) = .empty,
    port_concats: std.ArrayList(PortConcat) = .empty,
    port_widths: std.ArrayList(PortWidth) = .empty,
    signal_disciplines: std.ArrayList(SignalDiscipline) = .empty,
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    /// Attribute reads of undeclared ports wait for bottom-up resolution.
    pending_attributes: std.ArrayList(struct { expr: Ast.ExprId, net: Ast.StrId, path: []const u8 }) = .empty,

    /// §6.3.1 every `defparam` seen so far, keyed by the absolute flat name of
    /// the parameter it overrides: the declaring module's path joined with the
    /// path the source wrote. Collected on the way down (`override.collectDefparams`),
    /// which is before any instance below it is inlined, so a defparam is always
    /// in the map before the parameter it names is created.
    defparams: std.StringHashMapUnmanaged(elab_override.Defparam) = .empty,

    /// Annex F.2.1 step 3 / §3.10 precedence order 1: every OUT-OF-CONTEXT
    /// discipline declaration, keyed by the absolute flat name of the net segment
    /// it declares, the same key shape as `defparams`.
    /// "Apply all out-of-context node and signal declarations. For example,
    /// electrical top.middle.bottom.sig; overrides any discipline which may be
    /// declared for sig in the module where sig was declared."
    ooc: std.StringHashMapUnmanaged(Ast.StrId) = .empty,
    /// §3.6.3.2's nodeset on an out-of-context declaration
    /// (`electrical u.w = 2.75;`), in `collectOoc` order (top-down), with the
    /// initializer cloned in the declaring module's namespace. Applied after
    /// the walk by `resolve.applyOocInits`.
    ooc_inits: std.ArrayList(elab_resolve.OocInit) = .empty,

    /// The rename map in force while cloning the current unit's body, plus the
    /// per-instance rewrites §9.19 and §9.18 need. `inlineInstance` saves and
    /// restores it around the recursive call.
    unit: Unit = .{},
    /// Source aliases in each instantiated scope, including geometry aliases
    /// that cloning represents as local parameters rather than declarations.
    expression_aliases: std.ArrayList(Ast.AliasParam) = .empty,

    /// True while `paramsetOverrides` clones text written inside a §6.4
    /// paramset body, the one scope §9.13.1/§9.13.2 admit a distribution
    /// call's `type_string` in. Set and cleared with the `unit` swap there;
    /// read by `cloneExpr`'s sys_call arm (`rewriteParamsetDist`).
    in_paramset: bool = false,

    /// True while cloning the branch a `<+` or an indirect assignment DRIVES.
    /// §6.3.6's second automatic rule divides "the value returned by any branch
    /// flow probe" by $mfactor, and a contribution's left-hand side is the
    /// branch, not a probe of it. Read by `cloneExpr`'s branch_access arm.
    contrib_target: bool = false,

    /// One `segs` row: the disciplines a net's child segments declared, and
    /// the token of the first declaration (the diagnostic anchor).
    const Segs = struct {
        /// `.none` for an undeclared port: see `resolveDiscipline`.
        discs: std.ArrayList(Ast.StrId) = .empty,
        /// Each arrival's instance path, parallel to `discs`.
        paths: std.ArrayList([]const u8) = .empty,
        /// Answers for undeclared segments, keyed by their arrival index.
        resolved: std.AutoHashMapUnmanaged(u32, ?Ast.StrId) = .empty,
        tok: u32,

        comptime {
            // One row per port-bound flat net; three containers and a token.
            // A budget, not an exact size: the hash map carries a safety lock
            // in Debug/ReleaseSafe only, so the row is 96 B there and smaller
            // in ReleaseFast/ReleaseSmall.
            std.debug.assert(@sizeOf(Segs) <= 96);
        }
    };

    /// Per-instance clone state: the rename map and the §9.18/§9.19 answers
    /// that differ from one instance of a module to the next.
    pub const Unit = struct {
        /// This instance's namespace prefix, ending in `sep` below the top.
        path: []const u8 = "",
        /// Local name → flat name for this unit's declarations and ports.
        rename: Rename = .empty,
        /// §9.19 `$port_connected`: the child's local port name → was it given
        /// an expression in the connection list. Empty for the top, whose ports
        /// the host binds.
        connected: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
        /// §9.19 `$param_given`: local parameter name → was it overridden.
        given: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
        /// §4.4/§5.5.3 the discipline a BOUND port was declared with in this unit,
        /// local port name → discipline. The port is the parent's net after
        /// the join, whose discipline may be another one; `localAccess` checks
        /// this unit's access names against this, not against that. Attribute
        /// reads likewise retain this discipline when their net is renamed.
        port_disc: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,
        /// Annex E: the unit is a shipped Table E.1 primitive, whose `V`/`I`
        /// is a nature-neutral spelling of the port pair's potential and flow,
        /// not those two access functions. See `primitiveAccess`.
        primitive: bool = false,
        /// §9.18 the six resolved values in the flat namespace. `.none`
        /// denotes Table 9-29's top-level identity; descendants inherit the
        /// parent's expression unless they specify a new value to combine.
        hier: hier_param.Values = .initFill(.none),
        /// §6.6 the conjunction of if-generate schemes that brings this unit
        /// into existence, in the flat namespace; `.none` when nothing does.
        /// Every analog block of the unit is lowered under it.
        gate: Ast.ExprId = .none,
        /// §6.3.1 the nearest paramset instance above or at this unit. A
        /// descendant module inherits it even when instantiated by module name.
        paramset_instance: ?[]const u8 = null,
    };

    /// Returns `m`'s §6.6 generate-block instances. Asserts `m` is a row of
    /// `ctx.file.modules` (what `findModule` returns), not a copy.
    pub fn genInstancesOf(self: *const Flatten, m: *const Ast.ModuleDecl) []const Ast.Instance {
        const mods = self.ctx.file.modules;
        std.debug.assert(@intFromPtr(m) >= @intFromPtr(mods.ptr) and @intFromPtr(m) < @intFromPtr(mods.ptr + mods.len));
        return self.gen_instances[(@intFromPtr(m) - @intFromPtr(mods.ptr)) / @sizeOf(Ast.ModuleDecl)];
    }

    /// Reports `code` at `tok` and marks the flatten failed, so `elaborate`
    /// returns `error.DiagnosticsReported` once the walk ends.
    pub fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
        self.had_error = true;
        return self.ctx.bag.add(.lower, code, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), fmt, args);
    }

    /// The flatten's spine (see the file header): seeds the flat namespace
    /// with the top's own declarations, walks the instance tree, runs the
    /// post-walk passes and publishes `Design`.
    fn run(self: *Flatten, top: *const Ast.ModuleDecl) Error!Design {
        // The top's own declarations go in unrenamed and uncloned: it IS the
        // flat namespace, so an identity rename would rewrite every expression
        // in the device for no change.
        try self.params.appendSlice(self.ctx.arena, top.params);
        try self.aliasparams.appendSlice(self.ctx.arena, top.aliasparams);
        for (top.aliasparams) |al| if (elab_alias.original(self.ctx.file, top.params, top.aliasparams, al)) |target|
            try self.expression_aliases.append(self.ctx.arena, .{ .alias = al.alias, .target = target });

        // A host can set a top-level geometry alias through the model card.
        // Retain that parameter read in every descendant's composition. The
        // mfactor host field has its own automatic scaling convention.
        for (top.aliasparams) |al| {
            const kind = hier_param.Kind.fromName(self.ctx.file.str(al.target)) orelse continue;
            const card = try self.ctx.file.exprs.add(self.ctx.arena, .{
                .tag = .ident,
                .main_tok = top.main_tok,
                .str = al.alias,
            });
            // The card value is the top's own system parameter: Table 9-29
            // constrains it as much as an instance override.
            if (kind.constrained()) try self.system_checks.append(self.ctx.arena, .{
                .kind = kind,
                .value = card,
                .name = self.ctx.file.str(al.alias),
            });
            if (kind == .mfactor or self.unit.hier.get(kind) != .none) continue;
            self.unit.hier.set(kind, card);
        }
        try self.vars.appendSlice(self.ctx.arena, top.vars);
        for (top.ports) |p| try elab_resolve.noteDiscipline(self, p.name, p.discipline);
        try elab_resolve.addNets(self, top.nets);
        try self.branches.appendSlice(self.ctx.arena, top.branches);
        try self.genvars.appendSlice(self.ctx.arena, top.genvars);
        try self.events.appendSlice(self.ctx.arena, top.events);
        try self.functions.appendSlice(self.ctx.arena, top.functions);
        try self.attrs.appendSlice(self.ctx.arena, top.attrs);
        try self.discrete.appendSlice(self.ctx.arena, top.discrete);
        try self.assigns.appendSlice(self.ctx.arena, top.assigns);
        try self.gates.appendSlice(self.ctx.arena, top.gates);
        try self.pulls.appendSlice(self.ctx.arena, top.pulls);

        // Unit 0 is the top itself, and §9.15's example makes a top-level
        // module's instance name its module name ("testbench").
        try self.unit_paths.append(self.ctx.arena, .{
            .module = self.ctx.file.str(top.name),
            .path = "",
            .decl = top,
        });

        var stack: std.ArrayList(Ast.StrId) = .empty;
        try stack.append(self.ctx.arena, top.name);
        try elab_instance.walkInstances(self, top, "", &stack, 0);

        // E.3.2.2 "If there are no continuous disciplines defined on the net
        // segment, then the discipline shall default to electrical": the
        // primitive's own declaration, on a net nothing else resolved.
        for (self.prim_ports.items) |pp| {
            const d = self.disc_of.get(pp.bound) orelse .none;
            if (d == .none or !discipline.isContinuous(self.ctx.file, d))
                try elab_resolve.resolveDiscipline(self, pp.path, pp.port, pp.bound, null);
        }

        // Annex F.2.1 step 4's multi-candidate arm, over the segment sets the
        // walk collected. After the walk because 4.b matches the complete
        // candidate set of a signal against §7.7.2's resolution statements.
        try elab_resolve.resolveMultiCandidates(self);
        try elab_resolve.applyOocInits(self); // §3.6.3.2 hierarchical nodesets
        try elab_insert.checkUnbridged(self); // §7.8.4 E0927, on resolved nets

        // §5.2 analog blocks are concurrent, but §5.4.2.2's flow read is
        // ordered: `I(b)` after a flow contribution to `b` reads the retained
        // value, before one it mints an unknown. A parent reading a child's
        // branch flow through §6.7.1 must see the child's contribution, so the
        // top's own blocks go last, after every inlined child's.
        try self.analog.appendSlice(self.ctx.arena, top.analog);

        try elab_override.reportUnusedDefparams(self); // §6.3.1 E0907

        const out = try self.ctx.arena.create(Ast.ModuleDecl);
        const md = @typeInfo(Ast.ModuleDecl).@"struct";
        inline for (md.field_names, md.field_types, md.field_attrs) |name, F, attrs| @field(out, name) = switch (@field(fate, name)) {
            .top => @field(top, name),
            .merged => @field(self, name).items,
            .consumed => comptime attrs.defaultValue(F).?,
        };

        if (self.had_error) return error.DiagnosticsReported;
        try elab_alias.checkFlat(self.ctx, out, self.expression_aliases.items);
        return .{
            .top = out,
            .names = self.names,
            .implicit_nets = self.implicit_nets.items,
            .unconnected_inputs = self.unconnected_inputs.items,
            .units = self.unit_paths.items,
            .inserts = self.inserts.items,
            .port_concats = self.port_concats.items,
            .port_widths = self.port_widths.items,
            .signal_disciplines = self.signal_disciplines.items,
            .attribute_disciplines = self.attribute_disciplines,
            .local_accesses = self.local_accesses,
            .ps_hidden = self.ps_hidden.items,
            .paramset_defparams = self.paramset_defparams.items,
            .selection_params = self.selection_params.items,
            .system_checks = self.system_checks.items,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parser = @import("frontend").Parser;
const Preprocessor = @import("frontend").Preprocessor;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    file: Ast.SourceFile = .empty,
    bag: diag.Bag = undefined,
    src: []const u8 = "",
    starts: []const u32 = &.{},

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    fn ctx(self: *Fixture) Ctx {
        return .{
            .arena = self.arena.allocator(),
            .file = &self.file,
            .src = self.src,
            .tok_starts = self.starts,
            .bag = &self.bag,
        };
    }
};

fn parse(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.src = text;
    out.bag = diag.Bag.init(arena);
    var toks = try Lexer.Lexer.tokenize(arena, text);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, text, toks.items(.tag), out.starts, &out.bag);
    out.file = try p.parseSourceFile();
}

test "a tree of one elaborates to that one, by pointer" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    var empty: Ast.SourceFile = .empty;
    var c = f.ctx();
    c.file = &empty;
    try std.testing.expectError(error.NoModule, elaborate(c));

    try parse(&f, "module a(p); inout p; electrical p; analog I(p) <+ 0.0; endmodule");
    const design = try elaborate(f.ctx());
    // The identity of the pointer IS the regression claim: nothing was rebuilt.
    try std.testing.expectEqual(&f.file.modules[0], design.top);
}

test "the top is the module nothing instantiates, whatever the source order" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    // The CHILD is declared first, which is the shape
    // tests/fixtures/ch03_data_types/34_implicit_nets.va has.
    try parse(&f,
        \\module kid(a, b); inout a, b; electrical a, b;
        \\  parameter real g = 3.0;
        \\  analog I(a, b) <+ g * V(a, b);
        \\endmodule
        \\module top(p, n); inout p, n; electrical p, n;
        \\  kid #(.g(4.0)) u(p, n);
        \\endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("top", f.file.str(design.top.name));

    // §6.3: the child's parameter is flattened in under its §6.7 path, as a
    // localparam, carrying the override.
    try std.testing.expectEqual(@as(usize, 1), design.top.params.len);
    try std.testing.expectEqualStrings("u.g", f.file.str(design.top.params[0].name));
    try std.testing.expect(design.top.params[0].is_local);
    try std.testing.expect(design.top.params[0].is_override);
    // §6.5 the terminals are still the top's, and the child added no node: both
    // its ports were connected to them.
    try std.testing.expectEqual(@as(usize, 2), design.top.ports.len);
    try std.testing.expectEqual(@as(usize, 0), design.top.nets.len);
    try std.testing.expectEqual(@as(usize, 1), design.top.analog.len);
}

/// Annex E: the prelude is a prefix of `modules` only if the preprocessor ran,
/// so this fixture goes through it and sets `builtin_modules` as `root.zig`
/// stage 3 does.
fn parseWithPrelude(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.bag = diag.Bag.init(arena);
    out.src = (try Preprocessor.process(arena, text, .{ .bag = &out.bag })).text;
    var toks = try Lexer.Lexer.tokenize(arena, out.src);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, out.src, toks.items(.tag), out.starts, &out.bag);
    out.file = try p.parseSourceFile();
    out.file.builtin_modules = Preprocessor.spice_module_count;
}

test "annex E: a shipped primitive is instantiable, is never the top, and yields to a user module of the same name" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parseWithPrelude(&f,
        \\module top(p, n); inout p, n; electrical p, n;
        \\  resistor #(.r(2.0)) r1(p, n);
        \\endmodule
    );
    try std.testing.expect(f.file.builtin_modules > 0);
    const design = try elaborate(f.ctx());
    // §6.2.2: nineteen uninstantiated primitives are nineteen roots, and none of
    // them is the device.
    try std.testing.expectEqualStrings("top", f.file.str(design.top.name));
    // Table E.1's `resistor` row: parameters r, tc1, tc2, flattened under §6.7.
    try std.testing.expectEqual(@as(usize, 3), design.top.params.len);
    try std.testing.expectEqualStrings("r1.r", f.file.str(design.top.params[0].name));
    try std.testing.expect(design.top.params[0].is_override);

    // E.3.3: "a module ... defined in the Verilog-AMS will always be selected in
    // favor of a SPICE primitive ... using exactly the same name". The user's
    // `resistor` has ONE parameter, so the count is the claim.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parseWithPrelude(&g,
        \\module resistor(p, n); inout p, n; electrical p, n;
        \\  parameter real mine = 1.0;
        \\  analog I(p, n) <+ mine * V(p, n);
        \\endmodule
        \\module top(p, n); inout p, n; electrical p, n;
        \\  resistor #(.mine(2.0)) r1(p, n);
        \\endmodule
    );
    const shadowed = try elaborate(g.ctx());
    try std.testing.expectEqualStrings("top", g.file.str(shadowed.top.name));
    try std.testing.expectEqual(@as(usize, 1), shadowed.top.params.len);
    try std.testing.expectEqualStrings("r1.mine", g.file.str(shadowed.top.params[0].name));
}

test "a module instantiating itself is E0905, not a stack overflow" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module loop(p); inout p; electrical p;
        \\  loop u(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0905, f.bag.at(0).code);
}

test "§6.6 an if-generate's instances are elaborated under their arm's scheme; a loop generate's are E0235" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; parameter integer sel = 0;
        \\  generate if (sel) begin leaf a(p); end else begin leaf b(p); end endgenerate
        \\endmodule
        \\module leaf(q); inout q; electrical q; analog I(q) <+ V(q); endmodule
    );
    const d = try elaborate(f.ctx());
    // Both leaves, then the top's own block; each leaf's body under its gate.
    try std.testing.expectEqual(@as(usize, 3), d.top.analog.len);
    for (d.top.analog[0..2]) |blk| try std.testing.expect(f.file.stmt(blk.body) == .if_stmt);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module top(p); inout p; electrical p; genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin leaf a(p); end endgenerate
        \\endmodule
        \\module leaf(q); inout q; electrical q; analog I(q) <+ V(q); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0235, g.bag.at(0).code);
}

test "§6.3.6 a scaled instance's flow contribution is multiplied, its flow probe divided" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parseWithPrelude(&f,
        \\module top(p, n, o); inout p, n, o; electrical p, n, o;
        \\  kid #(.$mfactor(4.0)) u(p, n, o);
        \\endmodule
        \\module kid(a, b, c); inout a, b, c; electrical a, b, c;
        \\  analog I(a, b) <+ V(a, b);
        \\  analog V(c) <+ I(a, b);
        \\endmodule
    );
    const design = try elaborate(f.ctx());
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(usize, 2), design.top.analog.len);

    // Rule 1: the FLOW contribution's value is `V(a,b) * 4.0`. The left-hand
    // side is untouched: it names the branch and is not a read of it.
    const flow = f.file.stmt(design.top.analog[0].body).contribute;
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(flow.lhs));
    try std.testing.expectEqual(Ast.BinaryOp.mul, x.binOp(flow.rhs));
    try std.testing.expectEqual(@as(f64, 4.0), x.realValue(x.rhs(flow.rhs)));

    // Rule 2: the POTENTIAL contribution is not scaled, but the flow probe
    // inside it is divided: one instance of 4 copies carries a quarter each.
    const pot = f.file.stmt(design.top.analog[1].body).contribute;
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(pot.lhs));
    try std.testing.expectEqual(Ast.BinaryOp.div, x.binOp(pot.rhs));
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(x.lhs(pot.rhs)));
    try std.testing.expectEqual(@as(f64, 4.0), x.realValue(x.rhs(pot.rhs)));
}

test "§6.3.1 a defparam beats the instance's own override, and an unmatched one is E0907" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module top(p, n); inout p, n; electrical p, n;
        \\  kid #(.g(2.0)) u(p, n);
        \\  defparam u.g = 5.0;
        \\endmodule
        \\module kid(a, b); inout a, b; electrical a, b;
        \\  parameter real g = 1.0;
        \\  analog I(a, b) <+ g * V(a, b);
        \\endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("u.g", f.file.str(design.top.params[0].name));
    // §6.3: "the parameter in the module shall take the value specified by the
    // defparam": 5.0, not the instance's 2.0, whichever came first in the text.
    const v = design.top.params[0].default;
    try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(v));

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module top(p); inout p; electrical p;
        \\  defparam nowhere.g = 1.0;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0907, g.bag.at(0).code);
}

test "§3.4.7 defparam aliases share binding and reject conflicting spellings across mechanisms" {
    const Case = struct { inline_name: []const u8, defparams: []const u8, conflict: bool };
    const cases = [_]Case{
        .{ .inline_name = "ag", .defparams = "u.ag=5.0", .conflict = false },
        .{ .inline_name = "g", .defparams = "u.ag=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.g=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.bg=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.ag=2.0, u.bg=2.0", .conflict = true },
    };
    for ([_]bool{ false, true }) |paramset| for (cases) |case| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        const declarations = if (paramset)
            \\paramset card kid;
            \\parameter real g=1.0; aliasparam ag=g; aliasparam bg=g; .k=g;
            \\endparamset
            \\module kid(p); inout p; electrical p;
            \\parameter real k=1.0; analog I(p)<+k*V(p); endmodule
        else
            \\module card(p); inout p; electrical p;
            \\parameter real g=1.0; aliasparam ag=g; aliasparam bg=g;
            \\analog I(p)<+g*V(p); endmodule
        ;
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p;
            \\card #(.{s}(2.0)) u(p); defparam {s}; endmodule
            \\{s}
        , .{ case.inline_name, case.defparams, declarations }));
        if (case.conflict) {
            try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
            try std.testing.expectEqual(diag.Code.E0908, f.bag.at(0).code);
        } else {
            const design = try elaborate(f.ctx());
            const target = if (paramset) "u.card.g" else "u.g";
            const p = for (design.top.params) |p| {
                if (std.mem.eql(u8, f.file.str(p.name), target)) break p;
            } else unreachable;
            try std.testing.expect(p.is_override);
            try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(p.default));
        }
    };
}

test "empty named associations retain defaults and do not mark param_given" {
    for ([_][]const u8{ "g", "ag" }) |name| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; kid #( .{s}() ) u(p); endmodule
            \\module kid(p); inout p; electrical p;
            \\parameter real g=3.0; aliasparam ag=g;
            \\analog I(p)<+$param_given(g);
            \\endmodule
        , .{name}));
        const design = try elaborate(f.ctx());
        const p = design.top.params[0];
        try std.testing.expect(!p.is_override);
        try std.testing.expectEqual(@as(f64, 3.0), f.file.exprs.realValue(p.default));
        const contribution = f.file.stmt(design.top.analog[0].body).contribute;
        try std.testing.expectEqual(@as(i64, 0), f.file.exprs.intValue(contribution.rhs));
    }
}

test "empty named associations still validate parameter and localparam names" {
    // Unknown names are forbidden by §6.3.3. The localparam case preserves
    // current implementation behavior only: §3.4.5 forbids modification, but
    // an empty association modifies nothing. Its normative status is open;
    // this regression must not count as conformance rejection evidence.
    for ([_][]const u8{ "absent", "locked" }) |name| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; kid #( .{s}() ) u(p); endmodule
            \\module kid(p); inout p; electrical p;
            \\localparam real locked=3.0; analog I(p)<+V(p);
            \\endmodule
        , .{name}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
        try std.testing.expectEqual(diag.Code.E0907, f.bag.at(0).code);
    }
}

test "empty named associations do not suppress defparam override or given state" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\kid #(.g()) u(p); defparam u.g=5.0; endmodule
        \\module kid(p); inout p; electrical p;
        \\parameter real g=3.0; analog I(p)<+$param_given(g); endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expect(design.top.params[0].is_override);
    try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(design.top.params[0].default));
    const contribution = f.file.stmt(design.top.analog[0].body).contribute;
    try std.testing.expectEqual(@as(i64, 1), f.file.exprs.intValue(contribution.rhs));
}

test "empty named associations leave the inherited mfactor product unchanged" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; mid #(.$mfactor(4.0)) u(p); endmodule
        \\module mid(p); inout p; electrical p; kid #(.$mfactor()) v(p); endmodule
        \\module kid(p); inout p; electrical p; analog V(p)<+$mfactor; endmodule
    );
    const design = try elaborate(f.ctx());
    const contribution = f.file.stmt(design.top.analog[0].body).contribute;
    try std.testing.expectEqual(@as(f64, 4.0), f.file.exprs.realValue(contribution.rhs));
}

test "compile-time selection overrides replace default dependencies in host shape inputs" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\parameter real unrelated=2.0, base=unrelated;
        \\bin #(.w(2.0)) u(p); defparam u.w=base; endmodule
        \\paramset bin kid;
        \\parameter real w=1.0 from [0:4); .g=2.0; endparamset
        \\paramset bin kid;
        \\parameter real w=0.0 from [4:10]; .g=3.0; endparamset
        \\module kid(p); inout p; electrical p;
        \\parameter real g=0.0; analog I(p)<+g*V(p); endmodule
    );
    var ctx = f.ctx();
    ctx.param_overrides = &.{.{ .name = "base", .value = 7.0 }};
    const design = try elaborate(ctx);
    try std.testing.expect(design.selection_params.len != 0);
    for (design.selection_params) |name|
        try std.testing.expectEqualStrings("base", f.file.str(name));
    const gain = for (design.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.g")) break p;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 3.0), f.file.exprs.realValue(gain.default));
}

test "empty named associations use paramset defaults in admission and tie scores" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; bin #(.g()) u(p); endmodule
        \\paramset bin base;
        \\parameter real g=2.0 from [1.0:3.0]; .k=g;
        \\endparamset
        \\paramset bin base;
        \\parameter real g=0.0 from [1.0:3.0]; .k=99.0;
        \\endparamset
        \\module base(p); inout p; electrical p;
        \\parameter real k=1.0; analog I(p)<+k*V(p);
        \\endmodule
    );
    const design = try elaborate(f.ctx());
    const ps_value = for (design.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.bin.g")) break p;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 2.0), f.file.exprs.realValue(ps_value.default));
    try std.testing.expect(!ps_value.is_override);
    const inst = &f.file.modules[0].instances[0];
    const ps = &f.file.paramsets[0];
    try std.testing.expect(!elab_paramset.overridesParam(inst, ps, ps.params[0].name));
}

test "§6.4.2 the paramset whose range admits the override is selected, and a gap is E0911" {
    const src =
        \\module top(p, n); inout p, n; electrical p, n;
        \\  bin #(.l({s})) u(p, n);
        \\endmodule
        \\paramset bin base;
        \\  parameter real l = 1.0 from [1.0:inf);
        \\  .k = 10.0;
        \\endparamset
        \\paramset bin base;
        \\  parameter real l = 0.25 from [0.25:1.0);
        \\  .k = 20.0;
        \\endparamset
        \\module base(a, b); inout a, b; electrical a, b;
        \\  parameter real k = 9.0;
        \\  analog I(a, b) <+ k * V(a, b);
        \\endmodule
    ;
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f, try f.arena.allocator().print(src, .{"0.5"}));
    const design = try elaborate(f.ctx());
    // The SECOND paramset is the admitting one, so a first-match with no range
    // test answers 10.0 here.
    const k = for (design.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.k")) break p.default;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 20.0), f.file.exprs.realValue(k));

    // A value in the gap between the bins belongs to neither.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g, try g.arena.allocator().print(src, .{"0.1"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0911, g.bag.at(0).code);
}

test "Annex F.2 a leaf's discipline reaches the top segment it is bound to" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\discipline annex_f_y; enddiscipline
        \\module top(a); inout a;
        \\  mid m(a);
        \\  annex_f_y m.l.p;
        \\endmodule
        \\module mid(p); inout p;
        \\  leaf l(p);
        \\endmodule
        \\module leaf(p); inout p; electrical p;
        \\endmodule
    );
    const design = try elaborate(f.ctx());
    // The path is INSTANCE names, so it is `m.l.p` and not `m.leaf.p`: §6.7 walks
    // the instance tree. The leaf declares `electrical p`, the declaration above
    // declares it out of context, and
    // §3.10 order 1 wins. Both segments are the top's `a` after the flatten, so
    // the discipline lands on a net declaration for `a` and on nothing else.
    try std.testing.expectEqual(@as(usize, 1), design.top.nets.len);
    try std.testing.expectEqualStrings("a", f.file.str(design.top.nets[0].name));
    try std.testing.expectEqualStrings("annex_f_y", f.file.str(design.top.nets[0].discipline));
}

test "Annex F.2.1 step 4.b: resolveto resolves the multi-candidate net, no rule with a mixed port is E0903, exclude is E0917" {
    // The candidate topology of all three: an undeclared top net bound to two
    // leaves with distinct continuous disciplines. The `{s}` slots vary only
    // the connectrules block and whether the discrete leaf is bound.
    const src =
        \\discipline fa; domain continuous; enddiscipline
        \\discipline fb; domain continuous; enddiscipline
        \\discipline fc; domain continuous; enddiscipline
        \\discipline fd; domain discrete; enddiscipline
        \\{s}
        // `top` first: when the discrete leaf is not bound it is a second
        // root, and pickTop takes the first root in source order.
        \\module top(sig);
        \\  inout sig;
        \\  la ia(sig);
        \\  lb ib(sig);
        \\  {s}
        \\endmodule
        \\module la(p); inout p; fa p; endmodule
        \\module lb(p); inout p; fb p; endmodule
        \\module ld(d); inout d; fd d; endmodule
    ;
    const S = struct {
        fn build(f: *Fixture, rules: []const u8, extra: []const u8) !void {
            try parse(f, try f.arena.allocator().print(src, .{ rules, extra }));
        }
    };

    // Bullet 3: {fa, fb} matches the statement's list (order-free), so the net
    // is fc, which is neither candidate, per §7.7.2.1's "need not be one of
    // the disciplines specified".
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try S.build(&f, "connectrules r; connect fb, fa resolveto fc; endconnectrules", "");
    const design = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), design.top.nets.len);
    try std.testing.expectEqualStrings("fc", f.file.str(design.top.nets[0].discipline));

    // §7.7.2.1: the candidate set {fa,fb} is a subset of {fa,fb,fc}.
    var subset: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer subset.deinit();
    try S.build(&subset, "connectrules r; connect fa, fb, fc resolveto fc; endconnectrules", "");
    const sub = try elaborate(subset.ctx());
    try std.testing.expectEqualStrings("fc", subset.file.str(sub.top.nets[0].discipline));
    try std.testing.expectEqual(0, subset.bag.count());

    // A later exact match wins without warning about the discarded subset.
    var exact: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer exact.deinit();
    try S.build(&exact, "connectrules r; connect fa, fb, fc resolveto fc; connect fa, fb resolveto fb; endconnectrules", "");
    const ex = try elaborate(exact.ctx());
    try std.testing.expectEqualStrings("fb", exact.file.str(ex.top.nets[0].discipline));
    try std.testing.expectEqual(0, exact.bag.count());

    // Duplicate exact and subset rules both warn and retain source order.
    for ([_][]const u8{
        "connectrules r; connect fa, fb resolveto fb; connect fb, fa resolveto fc; endconnectrules",
        "connectrules r; connect fa, fb, fc resolveto fb; connect fc, fb, fa resolveto fc; endconnectrules",
    }) |rules| {
        var ambiguous: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer ambiguous.deinit();
        try S.build(&ambiguous, rules, "");
        const amb = try elaborate(ambiguous.ctx());
        try std.testing.expectEqualStrings("fb", ambiguous.file.str(amb.top.nets[0].discipline));
        try std.testing.expectEqual(1, ambiguous.bag.count());
        try std.testing.expectEqual(diag.Code.W0950, ambiguous.bag.at(0).code);
    }

    // Bullet 4, error half: no statement matches, the discipline is unknown,
    // and the discrete segment is the mixed-port connection.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try S.build(&g, "", "ld id(sig);");
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0903, g.bag.at(0).code);

    // Bullet 4, legal half: same unknown, no discrete segment: the net keeps
    // the first arrival and the design elaborates.
    var h: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try S.build(&h, "", "");
    const legal = try elaborate(h.ctx());
    try std.testing.expectEqualStrings("fa", h.file.str(legal.top.nets[0].discipline));

    // §7.7.2 exclude: the match refuses the net instead of resolving it.
    var k: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer k.deinit();
    try S.build(&k, "connectrules r; connect fa, fb resolveto exclude; endconnectrules", "");
    try std.testing.expectError(error.DiagnosticsReported, elaborate(k.ctx()));
    try std.testing.expectEqual(diag.Code.E0917, k.bag.at(0).code);
}

test "§7.7 connectrules names are judged even for a tree of one (E0915, E0916)" {
    // `top` has no instances, so this exercises the check ahead of the
    // tree-of-one shortcut: an insertion naming an ordinary module and a
    // resolution naming an undeclared discipline are both dead statements.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\discipline fa; domain continuous; enddiscipline
        \\module top(p); inout p; fa p; endmodule
        \\connectrules r;
        \\  connect top;
        \\  connect fa, nowhere resolveto fa;
        \\endconnectrules
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0915, f.bag.at(0).code);
    try std.testing.expectEqual(diag.Code.E0916, f.bag.at(1).code);
}

test "an instance naming no module is E0904" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\  nowhere u(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0904, f.bag.at(0).code);
}

test "a connect module is never the top (§7.6), and a hand-placed one is inlined (§7.1)" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    // Declared FIRST and instantiated by nobody, so "the first module nothing
    // instantiates" would pick it. §7.6 makes it the insertion phase's to place.
    try parse(&f,
        \\connectmodule bridge(a, d); inout a, d; electrical a; endmodule
        \\module top(p); inout p; electrical p; analog I(p) <+ V(p); endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("top", f.file.str(design.top.name));

    // §7.1: connect modules "can be manually inserted (by the user)", so
    // naming one inlines it like any child, its analog block included.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\connectmodule bridge(a, d); inout a, d; electrical a, d; analog I(a, d) <+ V(a, d); endmodule
        \\module top(p); inout p; electrical p; bridge u(p, p); analog I(p) <+ V(p); endmodule
    );
    const inlined = try elaborate(g.ctx());
    try std.testing.expectEqual(@as(usize, 2), inlined.top.analog.len);
}

test "§7.2.2 a flattened discrete half is carried, never dropped" {
    // The top's own `initial` survives having a child, and the child's is
    // renamed into the flat namespace next to it.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module c(p); inout p; electrical p; integer k; initial k = 3; analog I(p) <+ k * V(p); endmodule
        \\module top(p); inout p; electrical p; integer j; initial j = 2; c u(p); analog I(p) <+ j * V(p); endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), design.top.discrete.len);
    const child_init = f.file.stmt(design.top.discrete[1].body).assign;
    try std.testing.expectEqualStrings("u.k", f.file.str(f.file.exprs.strOf(child_init.target)));

    // So is a child's process in a design that needs the event kernel: the
    // mixed runner resolves `u.q` as a §6.7 path (`sim.digital.Run.slotOf`).
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module c(p); inout p; electrical p; reg q; always #5 q = ~q; analog I(p) <+ V(p); endmodule
        \\module top(p); inout p; electrical p; c u(p); endmodule
    );
    const mixed = try elaborate(g.ctx());
    try std.testing.expectEqual(@as(usize, 1), mixed.top.discrete.len);
    const toggle = g.file.stmt(g.file.stmt(mixed.top.discrete[0].body).event_control.body).assign;
    try std.testing.expectEqualStrings("u.q", g.file.str(g.file.exprs.strOf(toggle.target)));
}

test "IEEE 1364 §12.3.3 two variable ports collapsed onto one net declare it once" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module d(o); output o; reg o; initial o = 1'b0; endmodule
        \\module top(p); inout p; electrical p; wire w; d a(w); d b(w); analog I(p) <+ V(p); endmodule
    );
    const design = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), design.top.vars.len);
    try std.testing.expectEqualStrings("w", f.file.str(design.top.vars[0].name));
}

test {
    _ = elab_alias;
    _ = elab_clone;
    _ = elab_insert;
    _ = elab_instance;
    _ = elab_names;
    _ = elab_override;
    _ = elab_paramset;
    _ = elab_resolve;
}
