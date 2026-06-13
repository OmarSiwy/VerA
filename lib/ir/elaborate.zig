//! Elaboration: a parsed `Ast.SourceFile` → one flattened `Design` whose top
//! module holds a renamed copy of every reachable instance, so nothing after
//! this stage sees hierarchy. LRM §6.2.2 instantiation, §6.3 parameter
//! overrides and §6.3.1 defparam, §6.4 paramsets, §6.6 if-generate, §6.7
//! hierarchical names (`Design.names`), §7.8 connect-module insertion, and
//! Annex F.2 discipline resolution.

const std = @import("std");
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
const max_depth = 64;

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
    /// Judged later for the same reason: IEEE 1364 §19.10 `unconnected_drive`
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
    /// §6.4.3 "If a paramset variable without a description has the same name
    /// as a module output variable, the module output variable shall not be
    /// available for instances using the paramset." The flat names of those
    /// variables, for §9.16's `$simprobe` to treat as unresolvable.
    ps_hidden: []const []const u8 = &.{},
};

/// One `Design.port_widths` row: a port bound to a flat net, for the §6.5.7.1
/// size check.
pub const PortWidth = struct {
    net: []const u8,
    /// Cloned into the flat namespace, as `PortConcat.range` is.
    range: ?Ast.Dim,
    main_tok: u32,
};

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
};

/// Elaborates `ctx.file` into the design lowering walks. Every pointer in the
/// result points into `ctx.arena`. A top with no instances, defparams or
/// generate instances is returned by pointer, exactly as parsed. §6.5.7.1's
/// distribution of a vector net across an instance array is not supported.
pub fn elaborate(ctx: Ctx) Error!Design {
    if (ctx.file.userModules().len == 0) return error.NoModule;
    const top = try pickTop(ctx);

    var f: Flatten = .{ .ctx = ctx };
    // §7.7's names are judged whether or not the design has a hierarchy to
    // resolve: a `connectrules` block is a description of the COMPILATION
    // (A.1.2), not of the top module, so the tree-of-one shortcut below must
    // not skip a misspelled connect module or discipline in one.
    try f.checkConnectRules();
    try f.checkNetDisciplines(); // A.2.1.3, every module: see there
    // §7.4.2 "the real-value nets shall obey the rules imposed by 3.7": the
    // same structural check the digital runner makes (E0918/E0919).
    try @import("frontend").wreal.check(ctx.file, ctx.tok_starts, ctx.bag);
    if (ctx.bag.failed()) f.had_error = true;

    // A tree of one goes to lowering by pointer, untouched. A `defparam` with
    // no instance still takes the flatten: §6.3.1's path then names nothing,
    // and the flatten is where that E0907 is reported.
    var gen: std.ArrayList(Ast.Instance) = .empty;
    for (top.analog) |blk| try genInstanceList(ctx.file, blk.body, ctx.arena, &gen);
    if (top.instances.len == 0 and top.defparams.len == 0 and gen.items.len == 0) {
        if (f.had_error) return error.DiagnosticsReported;
        return .{ .top = top };
    }

    return f.run(top);
}

/// §6.6 every module instance in a generate block under `id`, schemes aside.
fn genInstanceList(file: *const Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, out: *std.ArrayList(Ast.Instance)) Error!void {
    if (id == .none) return;
    switch (file.stmt(id)) {
        .block => |b| {
            try out.appendSlice(arena, b.instances);
            for (b.body) |s| try genInstanceList(file, s, arena, out);
        },
        .if_stmt => |s| {
            try genInstanceList(file, s.then_s, arena, out);
            try genInstanceList(file, s.else_s, arena, out);
        },
        .for_stmt => |s| try genInstanceList(file, s.body, arena, out),
        .case_stmt => |s| for (s.arms) |a| try genInstanceList(file, a.body, arena, out),
        else => {}, // else: no other statement holds a generate block
    }
}

/// Which module is the device (§6.2.2): the first user module, in source
/// order, that nothing instantiates. A child may be declared before its
/// parent. Several roots are not diagnosed: A.1.2 lets a source_text hold
/// unrelated descriptions and §6.2.1 gives no rule for choosing between them.
fn pickTop(ctx: Ctx) Error!*const Ast.ModuleDecl {
    const mods = ctx.file.modules;
    // Annex E: a candidate is a module the USER wrote. The shipped Table E.1
    // primitives instantiate nothing, so all nineteen are roots of the instance
    // graph and one of them would win every time. They still count as
    // instantiators, so only the outer loop is narrowed.
    for (ctx.file.userModules()) |*m| {
        // §7.6: a connect module is placed by the insertion phase, not a
        // design root. Insertion runs later, during the walk, so here every
        // connect module looks like a root. Skipped in both loops, so a file
        // of only connect modules is `NoModule`.
        if (m.is_connect) continue;
        var instantiated = false;
        for (mods) |*other| {
            var gen: std.ArrayList(Ast.Instance) = .empty;
            for (other.analog) |blk| try genInstanceList(ctx.file, blk.body, ctx.arena, &gen);
            for (other.instances) |inst| try gen.append(ctx.arena, inst);
            for (gen.items) |inst| {
                if (inst.module == m.name) instantiated = true;
                // §6.4 an instance that names a paramset is an incoming edge on
                // the module the paramset specializes.
                for (ctx.file.paramsets) |ps| {
                    if (ps.name != inst.module) continue;
                    // §6.4 "A chain of paramsets may be defined, but the last
                    // paramset in the chain shall reference a module": follow
                    // the second identifier while it keeps naming a paramset.
                    // Bounded by the paramset count, so a cycle terminates.
                    var target = ps.target;
                    for (0..ctx.file.paramsets.len) |_| {
                        target = for (ctx.file.paramsets) |p2| {
                            if (p2.name == target) break p2.target;
                        } else break;
                    }
                    if (target == m.name) instantiated = true;
                }
            }
        }
        if (!instantiated) return m;
    }
    // Every module is instantiated by some module, so the graph is all cycles.
    // Start at the first and let E0905 name the one that closes.
    for (ctx.file.userModules()) |*m| if (!m.is_connect) return m;
    return error.NoModule;
}

// ---------------------------------------------------------------------------
// The flatten
// ---------------------------------------------------------------------------

/// One name binding in the flattened namespace: what a child's local name is
/// called after the join. §6.7's path table, in the direction the clone needs.
const Rename = std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId);

/// One collected §6.3.1 override, in `Flatten.defparams`.
const Defparam = struct {
    /// Already cloned, in the DECLARING module's namespace (§6.3.1: "a constant
    /// expression involving ... parameters declared in the same module as the
    /// defparam statement").
    value: Ast.ExprId,
    tok: u32,
    /// §6.3.1 a path that named no parameter of the elaborated design is E0907,
    /// and this is how that is noticed: nothing ever claimed it.
    used: bool = false,
};

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
    .event_toks = .consumed, // the digital engine's, read from the parsed module
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
/// allocation is in `ctx.arena`.
pub const Flatten = struct {
    ctx: Ctx,
    had_error: bool = false,

    /// Last `Ast.AnalogBlock.unit` handed out. 0 is the top, so the first
    /// inlined instance is 1. See that field for what it is for.
    last_unit: u32 = 0,
    /// §9.15/§9.16 one entry per unit id, in issue order (so index == unit id).
    unit_paths: std.ArrayList(UnitPath) = .empty,
    /// `Design.ps_hidden`, as the walk finds them.
    ps_hidden: std.ArrayList([]const u8) = .empty,

    // The synthesized module's declarations, in append order.
    params: std.ArrayList(Ast.ParamDecl) = .empty,
    aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
    vars: std.ArrayList(Ast.VarDecl) = .empty,
    nets: std.ArrayList(Ast.NetDecl) = .empty,
    branches: std.ArrayList(Ast.BranchDecl) = .empty,
    genvars: std.ArrayList(Ast.StrId) = .empty,
    events: std.ArrayList(Ast.StrId) = .empty,
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

    /// §6.3.1 every `defparam` seen so far, keyed by the absolute flat name of
    /// the parameter it overrides: the declaring module's path joined with the
    /// path the source wrote. Collected on the way down (`walkInstances`),
    /// which is before any instance below it is inlined, so a defparam is always
    /// in the map before the parameter it names is created.
    defparams: std.StringHashMapUnmanaged(Defparam) = .empty,

    /// Annex F.2.1 step 3 / §3.10 precedence order 1: every OUT-OF-CONTEXT
    /// discipline declaration, keyed by the absolute flat name of the net segment
    /// it declares, the same key shape as `defparams`.
    /// "Apply all out-of-context node and signal declarations. For example,
    /// electrical top.middle.bottom.sig; overrides any discipline which may be
    /// declared for sig in the module where sig was declared."
    ooc: std.StringHashMapUnmanaged(Ast.NetDecl) = .empty,

    /// The rename map in force while cloning the current unit's body, plus the
    /// per-instance rewrites §9.19 and §9.18 need. `inlineInstance` saves and
    /// restores it around the recursive call.
    unit: Unit = .{},

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
        tok: u32,
    };

    /// Per-instance clone state: the rename map and the §9.18/§9.19 answers
    /// that differ from one instance of a module to the next.
    pub const Unit = struct {
        /// Local name → flat name for this unit's declarations and ports.
        rename: Rename = .empty,
        /// §9.19 `$port_connected`: the child's local port name → was it given
        /// an expression in the connection list. Empty for the top, whose ports
        /// the host binds.
        connected: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
        /// §9.19 `$param_given`: local parameter name → was it overridden.
        given: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
        /// §4.4 the discipline a BOUND port was declared with in this unit,
        /// local port name → discipline. The port is the parent's net after
        /// the join, whose discipline may be another one; `localAccess` checks
        /// this unit's access names against this, not against that.
        port_disc: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,
        /// Annex E: the unit is a shipped Table E.1 primitive, whose `V`/`I`
        /// is a nature-neutral spelling of the port pair's potential and flow,
        /// not those two access functions. See `primitiveAccess`.
        primitive: bool = false,
        /// §9.18 the value `$mfactor` has in this unit, as an EXPRESSION in the
        /// flat namespace. `.none` at the top, where codegen answers Table
        /// 9-29's 1.0; below it the running product of §9.18's "times the
        /// parent's value", so no constant folding is needed.
        mfactor: Ast.ExprId = .none,
        /// §6.6 the conjunction of if-generate schemes that brings this unit
        /// into existence, in the flat namespace; `.none` when nothing does.
        /// Every analog block of the unit is lowered under it.
        gate: Ast.ExprId = .none,
    };

    /// One §6.6 generate-block instance and the scheme it exists under.
    const Gated = struct { inst: Ast.Instance, gate: Ast.ExprId };

    /// §6.6 a generate block's module instances, each with the scheme that
    /// brings it into existence, cloned into this unit's flat namespace.
    /// "At most one generate block instantiated from a set of alternatives":
    /// an if-generate's arms are gated `c` and `!c`, and `inlineInstance`
    /// lowers each child's analog blocks under its gate, as `checkGenScheme`
    /// does for an arm's analog items, so a model card overriding the
    /// scheme's parameter selects the arm it names.
    /// ponytail: if-generate only. A loop or case generate's instance is
    /// E0235 (`refuseGen`): the loop needs one renamed instance per
    /// iteration, the case an equality chain per arm.
    fn genInstances(self: *Flatten, id: Ast.StmtId, gate: Ast.ExprId, out: *std.ArrayList(Gated)) Error!void {
        if (id == .none) return;
        switch (self.ctx.file.stmt(id)) {
            .block => |b| {
                for (b.instances) |inst| try out.append(self.ctx.arena, .{ .inst = inst, .gate = gate });
                for (b.body) |s| try self.genInstances(s, gate, out);
            },
            .if_stmt => |s| if (s.is_generate) {
                const c = try elab_clone.cloneExpr(self, s.cond);
                try self.genInstances(s.then_s, try self.conj(gate, c, false), out);
                try self.genInstances(s.else_s, try self.conj(gate, c, true), out);
            },
            .for_stmt => |s| try self.refuseGen(s.body),
            .case_stmt => |s| for (s.arms) |a| try self.refuseGen(a.body),
            else => {}, // else: no other statement holds a generate block
        }
    }

    fn refuseGen(self: *Flatten, id: Ast.StmtId) Error!void {
        var all: std.ArrayList(Ast.Instance) = .empty;
        try genInstanceList(self.ctx.file, id, self.ctx.arena, &all);
        for (all.items) |inst| try self.err(inst.main_tok, .E0235, "a module instance in a loop or case generate", .{});
    }

    /// `a && c` (or `a && !c`), `a` = `.none` meaning true.
    fn conj(self: *Flatten, a: Ast.ExprId, c: Ast.ExprId, negate: bool) Error!Ast.ExprId {
        const ex = &self.ctx.file.exprs;
        const tok = ex.mainTok(c);
        const t = if (!negate) c else try ex.add(self.ctx.arena, .{
            .tag = .unary,
            .main_tok = tok,
            .lhs = c,
            .extra = @intFromEnum(Ast.UnaryOp.logical_not),
        });
        if (a == .none) return t;
        return ex.add(self.ctx.arena, .{
            .tag = .binary,
            .main_tok = tok,
            .lhs = a,
            .rhs = t,
            .extra = @intFromEnum(Ast.BinaryOp.logical_and),
        });
    }

    /// Reports `code` at `tok` and marks the flatten failed, so `elaborate`
    /// returns `error.DiagnosticsReported` once the walk ends.
    pub fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
        self.had_error = true;
        return self.ctx.bag.add(.lower, code, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), fmt, args);
    }

    fn run(self: *Flatten, top: *const Ast.ModuleDecl) Error!Design {
        // The top's own declarations go in unrenamed and uncloned: it IS the
        // flat namespace, so an identity rename would rewrite every expression
        // in the device for no change.
        try self.params.appendSlice(self.ctx.arena, top.params);
        try self.aliasparams.appendSlice(self.ctx.arena, top.aliasparams);
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
        try self.walkInstances(top, "", &stack, 0);

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

        // §5.2 analog blocks are concurrent, but §5.4.2.2's flow read is
        // ordered: `I(b)` after a flow contribution to `b` reads the retained
        // value, before one it mints an unknown. A parent reading a child's
        // branch flow through §6.7.1 must see the child's contribution, so the
        // top's own blocks go last, after every inlined child's.
        try self.analog.appendSlice(self.ctx.arena, top.analog);

        // §6.3.1 a defparam names "the parameter ... in any module instance
        // throughout the design", so one that matched nothing named nothing.
        // Reported after the walk because the instance a path names may be
        // several levels below the module the defparam is written in.
        var it = self.defparams.iterator();
        while (it.next()) |dp| if (!dp.value_ptr.used) try self.err(
            dp.value_ptr.tok,
            .E0907,
            "`{s}` names no parameter of the elaborated design",
            .{dp.key_ptr.*},
        );

        const out = try self.ctx.arena.create(Ast.ModuleDecl);
        inline for (@typeInfo(Ast.ModuleDecl).@"struct".fields) |fld| @field(out, fld.name) = switch (@field(fate, fld.name)) {
            .top => @field(top, fld.name),
            .merged => @field(self, fld.name).items,
            .consumed => comptime fld.defaultValue().?,
        };

        if (self.had_error) return error.DiagnosticsReported;
        return .{
            .top = out,
            .names = self.names,
            .implicit_nets = self.implicit_nets.items,
            .unconnected_inputs = self.unconnected_inputs.items,
            .units = self.unit_paths.items,
            .inserts = self.inserts.items,
            .port_concats = self.port_concats.items,
            .port_widths = self.port_widths.items,
            .ps_hidden = self.ps_hidden.items,
        };
    }

    /// §6.2.2 every instance of one unit, in source order, depth first. `path`
    /// is the unit's own hierarchical prefix ("" at the top).
    fn walkInstances(
        self: *Flatten,
        module: *const Ast.ModuleDecl,
        path: []const u8,
        stack: *std.ArrayList(Ast.StrId),
        depth: u32,
    ) Error!void {
        // §6.3.1 before the children: a defparam applies downward, and the
        // parameters it overrides are created as those instances are inlined.
        for (module.defparams) |dp| {
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(dp.path) });
            try self.defparams.put(self.ctx.arena, key, .{
                .value = try elab_clone.cloneExpr(self, dp.value),
                .tok = dp.main_tok,
            });
        }

        // Annex F.2.1 step 3, for the same reason: an out-of-context
        // declaration names a segment below this module. "More than one
        // conflicting out-of-context discipline declaration for the same
        // hierarchical segment of a signal is an error", and §3.10 makes two
        // declarations at one precedence level illegal even when compatible,
        // so this is a duplicate-key test, not a compatibility test.
        for (module.nets) |n| {
            if (!elab_resolve.isOoc(self.ctx.file.str(n.name))) continue;
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(n.name) });
            if (self.ooc.get(key)) |first| {
                try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                    key, self.ctx.file.str(first.discipline),
                });
                continue;
            }
            try self.ooc.put(self.ctx.arena, key, n);
        }

        // §7.8.4 connect modules are inserted "in the context of the ports
        // upper connection", which is this module: `plan` re-points each mixed
        // port at a digital segment and appends the bridges, which then inline
        // like any child. Indices past `module.instances.len` are those.
        const insts = try elab_insert.plan(self, module, path);

        // E.3.2's first source, "A port_discipline attribute on the analog
        // primitive", bound for every primitive of this level before any is
        // inlined, so E.3.2.2's "the same discipline" scan for an unattributed
        // primitive finds the segment resolved in any source order.
        // ponytail: a primitive reached through a paramset keeps only the
        // default; `selectParamset` diagnoses, so it is not run twice.
        for (module.instances) |*inst| {
            const child = elab_names.findModule(self, inst.module) orelse continue;
            if (!elab_names.isPrimitive(self, child)) continue;
            for (child.ports, 0..) |p, i| {
                const conn = connectionFor(inst, p, i) orelse continue;
                const n = elab_names.netRefName(self, conn.expr) orelse continue;
                var q = p;
                q.discipline = elab_names.portDisciplineAttr(self, module, inst, conn) orelse continue;
                const child_path = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}{c}", .{ path, self.ctx.file.str(inst.name), sep });
                try elab_resolve.resolveDiscipline(self, child_path, q, self.unit.rename.get(n) orelse n, conn.main_tok);
            }
        }

        var gated: std.ArrayList(Gated) = .empty;
        for (module.analog) |blk| try self.genInstances(blk.body, .none, &gated);
        const all = try self.ctx.arena.alloc(Ast.Instance, insts.len + gated.items.len);
        @memcpy(all[0..insts.len], insts);
        for (gated.items, all[insts.len..]) |g, *o| o.* = g.inst;
        for (all, 0..) |inst, idx| {
            const auto = idx >= module.instances.len and idx < insts.len;
            const gate: Ast.ExprId = if (idx < insts.len) .none else gated.items[idx - insts.len].gate;
            // §3.6.5, the structural half: an actual that names nothing `module`
            // declared is an implicit net (see `Design.implicit_nets`).
            // Collected here, not in `inlineInstance`, because only this loop
            // still has `module` in hand; one level down the names are flat.
            // Reads the source's own connections, not `plan`'s segments.
            if (!auto and idx < module.instances.len) try self.checkVariableActuals(module, &module.instances[idx]);
            if (!auto) for ((if (idx < module.instances.len) module.instances[idx] else inst).ports) |c| {
                const n = elab_names.netRefName(self, c.expr) orelse continue;
                if (declares(module, n)) continue;
                try self.implicit_nets.append(self.ctx.arena, .{
                    .name = self.ctx.file.str(n),
                    .main_tok = c.main_tok,
                });
            };

            // A.4.1 `module_instantiation ::= module_or_paramset_identifier ...`:
            // §6.4 says a paramset "can be instantiated exactly like a module".
            // A module wins; §6.4.2 selection runs only when nothing else matches.
            //
            // A.5.4: a named udp_instance parses as a module instance
            // (`parseUdpInst`), so its `#( … )` arrives as a
            // parameter_value_assignment. It is A.2.2.3's `delay2` (at most two
            // positional values), and the instance reaches no analog device (W0252).
            if (for (self.ctx.file.udps) |u| {
                if (u.name == inst.module) break true;
            } else false) {
                if (inst.params.len > 2 or (inst.params.len != 0 and inst.params[0].name != .none))
                    try self.err(inst.main_tok, .E0239, "`{s} #(…) {s}`: {d} value(s)", .{ self.ctx.file.str(inst.module), self.ctx.file.str(inst.name), inst.params.len })
                else
                    try self.ctx.bag.add(.lower, .W0252, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, inst.main_tok), "`{s}` primitive", .{self.ctx.file.str(inst.module)});
                continue;
            }
            var ps: ?*const Ast.ParamsetDecl = null;
            const child = elab_names.findModule(self, inst.module) orelse blk: {
                ps = try elab_paramset.selectParamset(self, &inst) orelse continue;
                break :blk try elab_names.chainEnd(self, ps.?) orelse continue;
            };
            if (elab_names.isPrimitive(self, child)) try elab_names.checkPortDiscipline(self, module, &inst);
            // §7.1: connect modules "can be manually inserted (by the user) or
            // automatically inserted (by the simulator)", so one named here is
            // inlined like any child: its digital half runs on the mixed
            // runner, which elaborates the same hierarchy.
            for (stack.items) |on_stack| if (on_stack == child.name) {
                try self.err(inst.main_tok, .E0905, "`{s}` is already being elaborated at `{s}{s}`", .{
                    self.ctx.file.str(child.name), path, self.ctx.file.str(inst.name),
                });
                return;
            };
            if (depth >= max_depth) {
                try self.err(inst.main_tok, .E1018, "at `{s}{s}`", .{
                    path, self.ctx.file.str(inst.name),
                });
                return;
            }

            // §6.2.2 `name_of_module_instance ::= module_instance_identifier
            // [ range ]`: one instance per element, each addressable as §6.7's
            // `adder1[5].sum`.
            var lo: i64 = 0;
            var hi: i64 = 0;
            var is_array = false;
            if (inst.range) |r| {
                const msb = elab_names.constInt(self, r.msb) orelse {
                    try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
                    continue;
                };
                const lsb = elab_names.constInt(self, r.lsb) orelse {
                    try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
                    continue;
                };
                lo = @min(msb, lsb);
                hi = @max(msb, lsb);
                is_array = true;
            }

            var k = lo;
            while (k <= hi) : (k += 1) {
                const leaf = if (is_array)
                    try std.fmt.allocPrint(self.ctx.arena, "{s}[{d}]", .{ self.ctx.file.str(inst.name), k })
                else
                    self.ctx.file.str(inst.name);
                const child_path = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}{c}", .{ path, leaf, sep });
                try self.inlineInstance(&inst, child, ps, child_path, stack, depth, gate);
            }
        }
    }

    /// Inline ONE instance: bind its ports, apply its §6.3 overrides, rename its
    /// declarations into the flat namespace, clone its body, then recurse.
    ///
    /// `path` already ends in `sep`, so a flat name is `path ++ local`.
    fn inlineInstance(
        self: *Flatten,
        inst: *const Ast.Instance,
        child: *const Ast.ModuleDecl,
        /// §6.4 non-null when the instance named a PARAMSET: `child` is then the
        /// module the paramset specializes and the instance's own `#(...)`
        /// overrides belong to the paramset, not to `child`.
        ps: ?*const Ast.ParamsetDecl,
        path: []const u8,
        stack: *std.ArrayList(Ast.StrId),
        depth: u32,
        /// §6.6 the scheme of the generate block `inst` sits in (`genInstances`).
        gate: Ast.ExprId,
    ) Error!void {
        const parent = self.unit; // restored below; the rename map is a stack
        var unit: Unit = .{
            .primitive = elab_names.isPrimitive(self, child),
            .gate = if (gate == .none) parent.gate else try self.conj(parent.gate, gate, false),
        };

        // ---- §6.2.2 port connections ---------------------------------------
        // Resolved in the PARENT's namespace, which means through the parent's
        // rename map: an actual naming a net of a mid-level module has already
        // been flattened to `u.n`.
        var concats: std.ArrayList(struct { port: Ast.Port, elems: []const []const u8, tok: u32 }) = .empty;
        var widths: std.ArrayList(struct { port: Ast.Port, net: Ast.StrId, tok: u32 }) = .empty;
        for (child.ports, 0..) |p, i| {
            const conn = connectionFor(inst, p, i);
            try unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
            // §6.5.7.1 a concatenated net expression: each operand a net of the
            // parent, bound element by element once the child's range is known.
            if (conn) |c| if (c.expr != .none and self.ctx.file.exprs.tag(c.expr) == .concat) {
                const ops = self.ctx.file.exprs.args(c.expr);
                const elems = try self.ctx.arena.alloc([]const u8, ops.len);
                for (ops, elems) |o, *el| {
                    const n = elab_names.netRefName(self, o) orelse {
                        try self.err(c.main_tok, .E0906, "a concatenation in a port connection must list scalar net references", .{});
                        break;
                    };
                    el.* = self.ctx.file.str(parent.rename.get(n) orelse n);
                } else {
                    if (p.range == null and p.type_range == null) {
                        try self.err(c.main_tok, .E0906, "a concatenation connects only a vector port, and `{s}` is scalar", .{self.ctx.file.str(p.name)});
                        continue;
                    }
                    try unit.rename.put(self.ctx.arena, p.name, try elab_names.join(self, path, p.name));
                    try concats.append(self.ctx.arena, .{ .port = p, .elems = elems, .tok = c.main_tok });
                }
                continue;
            };
            const actual: ?Ast.StrId = if (conn) |c| elab_names.netRefName(self, c.expr) else null;
            if (actual) |n| {
                // The port is the parent's net: no new node, no new declaration.
                // ponytail: the parent map already owns this lookup and fallback.
                const bound = parent.rename.get(n) orelse n;
                try unit.rename.put(self.ctx.arena, p.name, bound);
                // §6.7.1 the port still has a hierarchical name that may be
                // probed, so the path resolves to the net it was joined to.
                // These are the only rows `Design.names` holds.
                try self.names.put(
                    self.ctx.arena,
                    try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(p.name) }),
                    self.ctx.file.str(bound),
                );
                // E.3.2: a primitive's attribute was bound by `walkInstances`,
                // and its declared `electrical` is the default, bound last.
                // §4.4 otherwise the child's own declaration names its accesses.
                if (unit.primitive) {
                    try self.prim_ports.append(self.ctx.arena, .{ .path = path, .port = p, .bound = bound });
                } else {
                    try widths.append(self.ctx.arena, .{ .port = p, .net = bound, .tok = conn.?.main_tok });
                    try elab_resolve.resolveDiscipline(self, path, p, bound, conn.?.main_tok);
                    const local = (try elab_resolve.oocDiscipline(self, path, p.name)) orelse p.discipline;
                    if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
                }
            } else {
                // §6.2.2 "a blank port connection shall represent the situation
                // where the port is not to be connected", and an omitted named
                // port is the same thing. The child's equations still reference
                // it, so it becomes an internal net carrying the port's discipline.
                const internal = try elab_names.join(self, path, p.name);
                try unit.rename.put(self.ctx.arena, p.name, internal);
                try elab_resolve.addNet(self, .{
                    .name = internal,
                    // §3.10 order 1 still beats the local declaration on a port
                    // nobody connected: the segment exists, it is just the only
                    // segment of its signal.
                    .discipline = (try elab_resolve.oocDiscipline(self, path, p.name)) orelse p.discipline,
                    .main_tok = p.main_tok,
                });
                // IEEE 1364 §19.10 applies to unconnected input ports of the
                // modules declared between the directive pair, so the site is
                // the port's declaration in the child (`p.main_tok`), not the
                // instance.
                if (p.direction == .input) try self.unconnected_inputs.append(self.ctx.arena, .{
                    .name = self.ctx.file.str(internal),
                    .main_tok = p.main_tok,
                });
            }
            if (conn) |c| if (c.expr != .none and actual == null)
                try self.err(c.main_tok, .E0906, "a port connection must be a net reference", .{});
        }
        try self.checkConnectionShape(inst, child);

        // ---- §6.3 parameter overrides --------------------------------------
        // Built before any name is renamed, because an override's VALUE is an
        // expression in the parent (`#(.gain(scale*2))`) and its NAME is a
        // parameter of the child.
        var over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
        if (ps) |p|
            try elab_paramset.paramsetOverrides(self, inst, p, child, &parent, &over, &unit, path)
        else
            try self.collectOverrides(inst, child, &parent, &over, &unit, path);
        // §6.4.3 an undescribed paramset variable hides the module's variable of
        // the same name from this instance's reporting. Only the selected
        // paramset's own declarations; a chain's earlier links are not read.
        if (ps) |p| for (p.vars) |v| if (!v.desc) for (child.vars) |mv| if (mv.name == v.name)
            try self.ps_hidden.append(self.ctx.arena, try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(v.name) }));

        // ---- names: every local declaration gets its flat spelling ----------
        for (child.params) |p| try elab_names.bind(self, &unit, path, p.name);
        for (child.aliasparams) |al| try elab_names.bind(self, &unit, path, al.alias);
        for (child.nets) |n| try elab_names.bind(self, &unit, path, n.name);
        for (child.vars) |v| try elab_names.bind(self, &unit, path, v.name);
        for (child.branches) |b| try elab_names.bind(self, &unit, path, b.name);
        for (child.genvars) |g| try elab_names.bind(self, &unit, path, g);
        for (child.events) |e| try elab_names.bind(self, &unit, path, e);
        for (child.functions) |fd| try elab_names.bind(self, &unit, path, fd.name);
        for (child.instances) |sub| try elab_names.bind(self, &unit, path, sub.name);
        var subs: std.ArrayList(Ast.Instance) = .empty;
        for (child.analog) |blk| try genInstanceList(self.ctx.file, blk.body, self.ctx.arena, &subs);
        for (subs.items) |sub| try elab_names.bind(self, &unit, path, sub.name);

        self.unit = unit;
        for (concats.items) |cc| try self.port_concats.append(self.ctx.arena, .{
            .name = self.ctx.file.str(unit.rename.get(cc.port.name).?),
            .range = (try elab_clone.cloneDim(self, cc.port.range orelse cc.port.type_range)).?,
            .elems = cc.elems,
            .main_tok = cc.tok,
        });
        for (widths.items) |pw| try self.port_widths.append(self.ctx.arena, .{
            .net = self.ctx.file.str(pw.net),
            .range = try elab_clone.cloneDim(self, pw.port.range orelse pw.port.type_range),
            .main_tok = pw.tok,
        });

        // ---- the declarations themselves -----------------------------------
        try elab_clone.cloneParams(self, child.params, child.aliasparams, &over);
        for (child.nets) |n| {
            // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
            // already collected by `walkInstances`. It declares no net HERE.
            if (elab_resolve.isOoc(self.ctx.file.str(n.name))) continue;
            var out = n;
            out.name = elab_names.flat(self, n.name);
            out.range = try elab_clone.cloneDim(self, n.range);
            out.init = try elab_clone.cloneExpr(self, n.init);
            // §3.10 precedence order 1 on an internal net of the child: an
            // out-of-context declaration "overrides any discipline which may
            // be declared for sig in the module where sig was declared".
            if (try elab_resolve.oocDiscipline(self, path, n.name)) |d| out.discipline = d;
            try elab_resolve.addNet(self, out);
        }
        for (child.vars) |v| {
            const out = try elab_clone.cloneVar(self, v);
            // IEEE 1364-2005 §12.3.3 an output port "declared as a variable"
            // is renamed with its port onto the parent's net, so two such
            // ports on one net (§9.22's two drivers) are one flat name. One
            // declaration serves both: the digital half resolves the net.
            const port = for (child.ports) |p| {
                if (p.name == v.name) break true;
            } else false;
            const again = port and for (self.vars.items) |seen| {
                if (seen.name == out.name) break true;
            } else false;
            if (!again) try self.vars.append(self.ctx.arena, out);
        }
        for (child.branches) |b| {
            var out = b;
            out.name = elab_names.flat(self, b.name);
            out.hi = try elab_clone.cloneExpr(self, b.hi);
            out.lo = try elab_clone.cloneExpr(self, b.lo);
            out.range = try elab_clone.cloneDim(self, b.range);
            try self.branches.append(self.ctx.arena, out);
        }
        for (child.genvars) |g| try self.genvars.append(self.ctx.arena, elab_names.flat(self, g));
        for (child.events) |e| try self.events.append(self.ctx.arena, elab_names.flat(self, e));
        for (child.functions) |fd| try self.functions.append(self.ctx.arena, try elab_clone.cloneFunc(self, fd));
        for (child.attrs) |at| try self.attrs.append(self.ctx.arena, .{
            .name = at.name,
            .value = try elab_clone.cloneExpr(self, at.value),
            .main_tok = at.main_tok,
        });
        // One id per INSTANCE, not per module: two instances of the same child
        // are two devices, and §5.6.1.3 must not let one discard the other's.
        self.last_unit += 1;
        const unit_id = self.last_unit;
        // Appended in issue order, so `Design.units[unit_id]` is this instance.
        try self.unit_paths.append(self.ctx.arena, .{
            .module = self.ctx.file.str(child.name),
            .path = path,
            .decl = child,
        });
        for (child.analog) |blk| {
            var body = try elab_clone.cloneStmt(self, blk.body);
            // §6.6 an instance a generate scheme brings into existence behaves
            // only while the scheme holds.
            if (unit.gate != .none) body = try self.ctx.file.addStmt(self.ctx.arena, .{ .if_stmt = .{
                .cond = unit.gate,
                .then_s = body,
                .else_s = .none,
                .is_generate = false,
            } }, blk.main_tok);
            try self.analog.append(self.ctx.arena, .{
                .is_initial = blk.is_initial,
                .body = body,
                .main_tok = blk.main_tok,
                .unit = unit_id,
            });
        }
        // ponytail: a gated child's discrete half has no scheme to run under.
        if (unit.gate != .none and child.discrete.len + child.assigns.len + child.gates.len + child.pulls.len + child.switches.len != 0)
            try self.err(inst.main_tok, .E0235, "a module instance with discrete behavior", .{});
        for (child.discrete) |blk| try self.discrete.append(self.ctx.arena, .{
            .is_always = blk.is_always,
            .body = try elab_clone.cloneStmt(self, blk.body),
            .main_tok = blk.main_tok,
        });
        for (child.assigns) |a| {
            var o = a;
            o.target = try elab_clone.cloneExpr(self, a.target);
            o.value = try elab_clone.cloneExpr(self, a.value);
            o.delay = try elab_clone.cloneDelay(self, a.delay);
            try self.assigns.append(self.ctx.arena, o);
        }
        for (child.gates) |g| {
            var o = g;
            o.out = try elab_clone.cloneExpr(self, g.out);
            const ins = try self.ctx.arena.alloc(Ast.ExprId, g.ins.len);
            for (g.ins, ins) |src, *d| d.* = try elab_clone.cloneExpr(self, src);
            o.ins = ins;
            o.delay = try elab_clone.cloneDelay(self, g.delay);
            try self.gates.append(self.ctx.arena, o);
        }
        for (child.pulls) |p| {
            var o = p;
            o.out = try elab_clone.cloneExpr(self, p.out);
            try self.pulls.append(self.ctx.arena, o);
        }
        for (child.switches) |sw| {
            var o = sw;
            const terms = try self.ctx.arena.alloc(Ast.ExprId, sw.terms.len);
            for (sw.terms, terms) |src, *d| d.* = try elab_clone.cloneExpr(self, src);
            o.terms = terms;
            o.delay = try elab_clone.cloneDelay(self, sw.delay);
            try self.switches.append(self.ctx.arena, o);
        }
        // ---- recurse, with this unit's map in force ------------------------
        try stack.append(self.ctx.arena, child.name);
        try self.walkInstances(child, path, stack, depth + 1);
        _ = stack.pop();

        self.unit = parent;
    }

    // ponytail: binding needs only the connection list and port, not flattening state.
    /// Returns the connection that binds `port`, the i'th declared port, or
    /// null when the list does not mention it (§6.2.2). The first entry decides
    /// between named and ordered binding; a named list takes the first match.
    pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) return if (i < inst.ports.len) inst.ports[i] else null;
        for (inst.ports) |c| if (c.name == port.name) return c;
        return null;
    }

    // ponytail: a linear scan per connection, quadratic in one module's
    // declaration count. Build a per-module set if a generated netlist puts
    // thousands of nets and instances in one module.
    /// Returns whether `module` declares a net `name`, as a §6.5 port or a
    /// §3.6.3 net declaration (§3.6.5's test). A parameter, variable or genvar
    /// is not a net, so an actual naming one is E0906, not an implicit net.
    pub fn declares(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
        for (module.ports) |p| if (p.name == name) return true;
        for (module.nets) |n| if (n.name == name) return true;
        return false;
    }

    /// §6.5 "Ports provide a means of interconnecting instances of modules. If a
    /// module A instantiates module B, the ports of module B are associated with
    /// either the ports or the internal nets of module A." A VARIABLE of A is
    /// neither, so it cannot stand as the actual of B's continuous port: there is
    /// no node for the port to join (§6.5.1 lists the port expressions, every one
    /// of them a net), and it is not an implicit net either (`declares`).
    ///
    /// Only a port of CONTINUOUS discipline: a real variable driving a discrete
    /// or `wreal` input is a real EXPRESSION, which §3.7 and IEEE 1364's input
    /// port rules allow, and the mixed-signal kernel decides those.
    fn checkVariableActuals(self: *Flatten, module: *const Ast.ModuleDecl, inst: *const Ast.Instance) Error!void {
        const child = elab_names.findModule(self, inst.module) orelse return;
        for (child.ports, 0..) |p, i| {
            const c = connectionFor(inst, p, i) orelse continue;
            const n = elab_names.netRefName(self, c.expr) orelse continue;
            if (declares(module, n)) continue;
            const is_var = for (module.vars) |v| {
                if (v.name == n) break true;
            } else false;
            if (!is_var or p.discipline == .none or !discipline.isContinuous(self.ctx.file, p.discipline)) continue;
            try self.err(c.main_tok, .E0906, "`{s}` is a variable, and port `{s}` of `{s}` has the continuous discipline `{s}`: it joins only a net", .{
                self.ctx.file.str(n), self.ctx.file.str(p.name), self.ctx.file.str(child.name), self.ctx.file.str(p.discipline),
            });
        }
    }

    /// The ways a connection list can be malformed: longer than the port list,
    /// naming a port that does not exist, mixing the two spellings, or naming
    /// one port twice. §6.2.2 permits it to be shorter: that is the
    /// omitted-port spelling of "not to be connected".
    ///
    /// The list's FIRST entry decides which spelling it is (`connectionFor`
    /// binds by the same test), so a mix is diagnosed relative to that. §6.5.5:
    /// "The two types of module port connections can not be mixed; connections
    /// to the ports of a particular module instance shall be all by order or
    /// all by name."
    fn checkConnectionShape(self: *Flatten, inst: *const Ast.Instance, child: *const Ast.ModuleDecl) Error!void {
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) {
            if (inst.ports.len > child.ports.len) try self.err(
                inst.ports[child.ports.len].main_tok,
                .E0906,
                "`{s}` declares {d} port{s}, and this instance connects {d}",
                .{ self.ctx.file.str(child.name), child.ports.len, if (child.ports.len == 1) "" else "s", inst.ports.len },
            );
            // An ordered list binds by position, so a `.name(...)` inside one
            // would be ignored silently; the named loop below cannot see it.
            for (inst.ports) |c| if (c.name != .none) try self.err(
                c.main_tok,
                .E0906,
                "a named connection in a list of ordered connections",
                .{},
            );
            return;
        }
        for (inst.ports, 0..) |c, i| {
            if (c.name == .none) {
                try self.err(c.main_tok, .E0906, "an ordered connection in a list of named connections", .{});
                continue;
            }
            const found = for (child.ports) |p| {
                if (p.name == c.name) break true;
            } else false;
            if (!found) {
                try self.err(c.main_tok, .E0906, "`{s}` is not a port of `{s}`", .{
                    self.ctx.file.str(c.name), self.ctx.file.str(child.name),
                });
                continue;
            }
            // IEEE 1364 §12.3.6: a port is connected at most once.
            // `connectionFor` takes the first match, so a second `.a(...)`
            // would otherwise be dropped silently.
            for (inst.ports[0..i]) |prev| if (prev.name == c.name) {
                try self.err(c.main_tok, .E0906, "`{s}` is connected twice", .{self.ctx.file.str(c.name)});
                break;
            };
        }
    }

    /// Binds an instance's `#(...)` to `child`'s parameters into `over` (§6.3),
    /// applies matching defparams last (§6.3.1), and sets `unit`'s §9.18
    /// `$mfactor` product and §9.19 `$param_given` answers. Reports E0907 and
    /// E0908 on bad overrides.
    pub fn collectOverrides(
        self: *Flatten,
        inst: *const Ast.Instance,
        child: *const Ast.ModuleDecl,
        parent: *const Unit,
        over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
        unit: *Unit,
        path: []const u8,
    ) Error!void {
        // §9.18/Table 9-29: `$mfactor_resolved = $mfactor_specified *
        // $mfactor_hier`, carried as an expression: the top's `$mfactor` is
        // host-supplied, and a specified factor may be any constant
        // expression over the parent's parameters.
        var mfactor = parent.mfactor;

        const named = inst.params.len != 0 and inst.params[0].name != .none;
        // §3.4.5: local parameters "cannot directly be modified with the
        // defparam statement or by the ordered or named parameter value
        // assignment", so §6.3's declaration order counts overridable
        // parameters only and an ordered value skips every `is_local` entry.
        // The named arm refuses a localparam by name below.
        var ord: usize = 0;
        for (inst.params) |o| {
            // The value is the parent's expression, cloned under the parent's map.
            const saved = self.unit;
            self.unit = parent.*;
            const value = elab_clone.cloneExpr(self, o.value) catch |e| {
                self.unit = saved;
                return e;
            };
            self.unit = saved;

            if (!named) {
                // §6.3 "in the order of their declaration".
                while (ord < child.params.len and child.params[ord].is_local) ord += 1;
                if (ord >= child.params.len) {
                    const n = elab_paramset.overridableCount(child.params);
                    try self.err(o.main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this instance overrides {d}", .{
                        self.ctx.file.str(child.name), n,
                        if (n == 1) "" else "s",       inst.params.len,
                    });
                    continue;
                }
                try over.put(self.ctx.arena, child.params[ord].name, value);
                ord += 1;
                continue;
            }
            if (self.ctx.file.strings.eql(o.name, "$mfactor")) {
                // §6.3.3 an empty named association supplies no value. For
                // §9.18 that leaves the inherited product unchanged (times 1).
                if (o.value == .none) continue;
                if (try elab_paramset.checkMfactor(self, o.main_tok, o.value)) continue;
                mfactor = try elab_paramset.mulMfactor(self, mfactor, value, o.main_tok);
                continue;
            }
            // §3.4.7 an aliasparam is a second NAME for one parameter, so an
            // override through it lands on the target.
            var target = o.name;
            for (child.aliasparams) |al| if (al.alias == o.name) {
                target = al.target;
                break;
            };
            if (!try elab_paramset.checkOverridable(self, child, target, o.name, o.main_tok)) continue;
            // §6.3.3 / IEEE 12.2.2.2: .name() documents the parameter but
            // leaves its default, dependencies and $param_given unchanged.
            // Validate the name/localparam above even when no value is given.
            if (o.value == .none) continue;
            // §3.4.7: "It shall be an error to specify a value for both the
            // original parameter and its alias in the same module instantiation".
            if (over.contains(target)) {
                try self.err(o.main_tok, .E0908, "`{s}` and its alias are both given a value", .{self.ctx.file.str(target)});
                continue;
            }
            try over.put(self.ctx.arena, target, value);
        }

        // §9.18: an instance with no `.$mfactor` still PROPAGATES the parent's
        // ("times 1.0, if no override was specified"), which is why `mfactor`
        // starts at the parent's value rather than at `.none`.
        unit.mfactor = mfactor;

        // §6.3.1 last: "If a defparam assignment conflicts with a module
        // instance parameter, the parameter in the module shall take the value
        // specified by the defparam." It overwrites `#(...)` whatever the text
        // order. §3.4.5 still holds: only overridable parameters are looked up.
        for (child.params) |p| {
            if (p.is_local) continue;
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(p.name) });
            const dp = self.defparams.getPtr(key) orelse continue;
            dp.used = true;
            try over.put(self.ctx.arena, p.name, dp.value);
        }

        try elab_paramset.markGiven(self, child, over, unit);
    }

    const elab_paramset = @import("elaborate/paramset.zig");
    /// Returns whether a named instance override lands on paramset parameter
    /// `name`, directly or through a §3.4.7 alias.
    pub const overridesParam = elab_paramset.overridesParam;

    const elab_resolve = @import("elaborate/resolve.zig");
    /// Checks the names every §7.7 `connectrules` statement uses, once per
    /// compilation.
    pub const checkConnectRules = elab_resolve.checkConnectRules;
    /// Checks that every net declaration in every user module names a declared
    /// discipline (A.2.1.3, E0371).
    pub const checkNetDisciplines = elab_resolve.checkNetDisciplines;

    const elab_insert = @import("elaborate/insert.zig");
    const elab_names = @import("elaborate/names.zig");
    const elab_clone = @import("elaborate/clone.zig");
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

test "empty named associations retain defaults and do not mark param_given" {
    for ([_][]const u8{ "g", "ag" }) |name| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try parse(&f, try std.fmt.allocPrint(f.arena.allocator(),
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
        try parse(&f, try std.fmt.allocPrint(f.arena.allocator(),
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
    try std.testing.expect(!Flatten.overridesParam(inst, ps, ps.params[0].name));
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
    try parse(&f, try std.fmt.allocPrint(f.arena.allocator(), src, .{"0.5"}));
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
    try parse(&g, try std.fmt.allocPrint(g.arena.allocator(), src, .{"0.1"}));
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
            try parse(f, try std.fmt.allocPrint(f.arena.allocator(), src, .{ rules, extra }));
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
    _ = Flatten.elab_paramset;
    _ = Flatten.elab_resolve;
    _ = Flatten.elab_names;
    _ = Flatten.elab_clone;
}
