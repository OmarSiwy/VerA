//! Class 9 — elaboration. LRM §6.2.2 (instantiation), §6.3 (parameter
//! overrides), §6.7 (hierarchical names).
//!
//! ELABORATION FLATTENS, AND THE MIR NEVER LEARNS ABOUT HIERARCHY. That is the
//! design decision this file exists to hold, so it is written down here rather
//! than spread across the consumers:
//!
//!   - VerA emits ONE device. A §6.2.2 module hierarchy is a STRUCTURAL
//!     description that collapses at elaboration by construction: what a
//!     simulator stamps is one residual over terminals plus internal nodes.
//!     There is no runtime hierarchy in the artifact, so a hierarchy in the IR
//!     would be a concept with no consumer.
//!   - Flattening therefore leaves mir.zig, ssa.zig, analysis.zig, proof.zig,
//!     codegen.zig and tb.zig UNCHANGED. A hierarchical MIR makes all six learn
//!     a new concept for the same emitted device.
//!   - §6.7 out-of-module references in Verilog-A are STATIC — a parameter read
//!     or a node reference resolvable at elaboration time — so flattening does
//!     not foreclose them, PROVIDED the flatten records the hierarchical path of
//!     every entity it renames and can resolve a path back to the flat entity.
//!     `Flatten.names` is that table.
//!   - What flattening DOES foreclose is runtime dynamic hierarchical access:
//!     `$simprobe` with a computed path, and the unregistered-VPI family. Both
//!     are independently blocked on there being no VPI host, so the loss is
//!     accepted rather than designed around.
//!
//! HOW IT FLATTENS: AST → AST. The output is one synthesized `Ast.ModuleDecl`
//! holding the top's declarations followed by a renamed COPY of every reachable
//! instance's, and lowering walks it exactly as it walked a hand-written module.
//! The copy is real — expressions and statements are cloned into the same
//! append-only stores, with a StrId→StrId map applied to the names — because the
//! alternative is a per-instance name environment inside lowering, and lowering
//! keys twenty flat tables by name over eight thousand lines. One walk here,
//! versus a scope concept everywhere there.
//!
//! The single-module case never enters the clone at all: `elaborate` returns the
//! parsed `ModuleDecl` by pointer when the top has no instances, so the 1000-odd
//! fixtures with nothing to elaborate go through a pointer copy and cannot
//! change behaviour.
//!
//! WHAT ELSE LANDED HERE, because each is a question about the instance tree and
//! about nothing else: §6.3.1 `defparam` (an override applied on the way down,
//! keyed by the path it names), §6.4 `paramset` instantiation with §6.4.2's
//! range-based selection, and Annex F.2's discipline resolution — which in a
//! flattened design is the port binding itself, since collapsing every segment of
//! one signal into one node IS F.2's parent/child relation. That includes step
//! 4.b's multi-candidate arm: the §7.7.2 `connect ... resolveto` statements of a
//! `connectrules` block (parsed since the AMS turn) resolve a net whose segments
//! declare more than one matching-domain discipline, `resolveto exclude` refuses
//! one (E0917), and an UNKNOWN result with a mixed-port connection is the
//! F.2.1/F.2.2 fourth-bullet error, E0903 (`resolveMultiCandidates`).
//!
//! §7.8 connect-module insertion is here too, per level of the walk
//! (`elaborate/insert.zig`): a port whose two connections are of different
//! domains and that one §7.7.1 statement matches is re-pointed at a segment,
//! and the selected connect module is inlined between the two like any child.
//! The flattened design carries both halves: the analog half lowers into the
//! device, and the digital half runs on the mixed runner, whose engine
//! elaborates the source hierarchy plus the bridges listed in `Design.inserts`.
//!
//! §6.5.7.1's vector-net distribution across an instance array is not here —
//! a port connection has to be a scalar net reference.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const diag = @import("diag");
// §9.13's argument table and the kernels it names — `rewriteParamsetDist` folds
// an in-paramset draw with the SAME code a device embeds, so the two cannot
// disagree on the stream.
const Lower = @import("lower.zig");
const discipline = @import("lower/discipline.zig");
const rng = @import("kernels").rng_kernels;

/// `NoModule`: A.1.2 lets a source_text hold no module_declaration at all
/// (a file of `discipline`/`nature` declarations is legal), but a device needs
/// one. The caller turns this into E1001 — elaboration does not diagnose it,
/// because "no module here" is only an error relative to what was ASKED for.
///
/// `DiagnosticsReported`: something in the instance tree was diagnosed here and
/// the flattened module would be a lie. Same contract as lowering's.
pub const Error = error{ OutOfMemory, NoModule, DiagnosticsReported };

/// §6.7 the separator between levels of a flattened hierarchical name.
///
/// A period, for two reasons. It is the separator §6.7 itself writes
/// (`hierarchical_identifier ::= { identifier [ [ expr ] ] . } identifier`), so
/// a flattened name reads the way the source would have referred to it — and
/// these names land in diagnostics and in the emitted device's identifiers, so
/// readable is a requirement, not a nicety.
///
/// And it does not collide, though NOT for the reason this comment used to give.
/// §2.8 simple identifiers are alphanumeric plus `_`/`$`, but §2.8.1 ends an
/// escaped identifier at white space and admits every printable character before
/// it, so `\x.y ` is the identifier `x.y` and a raw join of it under instance
/// `u` gives `u.x.y` — the same string as net `y` inside instance `x` inside
/// `u`. What buys the property is `parser.internTok`, which substitutes a space
/// for a period in an escaped identifier as it interns it; read its comment for
/// the argument. From here on a period in a name IS a join, which makes the
/// unmangling a `split` and the mangling injective.
pub const sep = '.';

/// §6.2.2 how deep the instance tree may go before the walk gives up.
///
/// A cycle is caught by name before this is reached (E0905 keeps the module
/// stack), so hitting the limit means a genuinely deep but finite design. 64 is
/// far past anything a device model is written as, and the point of the number
/// is that a wrong answer is a diagnostic rather than a stack overflow.
const max_depth = 64;

/// The elaborated design lowering walks: one module with the hierarchy already
/// applied.
pub const Design = struct {
    /// The root of §6.2.2's instance tree, with every reachable child inlined:
    /// the module whose ports are the device's terminals.
    top: *const Ast.ModuleDecl,
    /// §6.7 hierarchical path → the flat name that path denotes. Ruling E point
    /// 3's table, and the piece a naive flatten omits.
    ///
    /// Holds only the rows that are NOT the identity. The mangling IS the path
    /// (`Elaborate.sep`), which is why a §6.7 reference costs lowering a string
    /// join and no tree walk, and why every reader does `get(p) orelse p`. The
    /// rows that make the table necessary: a child port CONNECTED to a parent
    /// net is the same signal as that net, so `u.a` has to resolve to `p` —
    /// there is no node called `u.a` in the flattened design, and §6.7.1 still
    /// lets `V(u.a)` name it.
    ///
    /// Empty for a tree of one: with nothing renamed there is no path but the
    /// module's own names, and those resolve without it.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// §3.6.5's STRUCTURAL implicit nets: "Nets can be used in structural
    /// descriptions without being declared." One entry per instance port actual
    /// naming a net the instantiating module never declared.
    ///
    /// Reported rather than acted on. The flatten's own answer to one of these
    /// is already right — the child's declaration supplies the discipline, which
    /// is what §7.4 resolution would have done — and the only open question is
    /// whether the implicit net is LEGAL, which IEEE 1364 §19.2
    /// `default_nettype decides. That is a text-stream fact positioned by byte
    /// offset, and this pass sees neither the directives nor the offsets, so the
    /// call belongs to the stage that holds both (`Lower.rejectImplicitNet`).
    implicit_nets: []const NameSite = &.{},
    /// §6.2.2 "a blank port connection shall represent the situation where the
    /// port is not to be connected", for an `input` port. One entry per such
    /// port, naming the internal net the flatten gave it.
    ///
    /// Same division of labour: IEEE 1364 §19.10 `unconnected_drive is what
    /// decides whether the port arrives driven or floating, and it is positional
    /// text (`Lower.applyUnconnectedDrive`).
    unconnected_inputs: []const NameSite = &.{},
    /// §9.15 Table 9-28's two hierarchy rows, indexed by `Ast.AnalogBlock.unit`:
    /// "module" is "the name of the module from which $simparam$str is called"
    /// and "instance" is "the hierarchical name of the instance". Flattening
    /// erases both — every block ends up in the top's namespace — but the walk
    /// HAS them, so it publishes them rather than letting §9.15 answer with the
    /// top's name and an empty string. §9.16's sibling scope reads `path` for
    /// the same reason: "look for an instance called inst_name IN THE PARENT OF
    /// THE CURRENT INSTANCE".
    units: []const UnitPath = &.{},
    /// §7.8.4 every port an automatic connect module was inserted on, for the
    /// mixed-signal runner: its digital engine elaborates the SOURCE hierarchy,
    /// in which the bridges do not exist.
    inserts: []const Inserted = &.{},
    /// §6.5.7.1 "a vector port can be connected to a vector net or
    /// concatenated net expression of the matching width". One entry per port
    /// connected to a concatenation: the child's vector, renamed to a flat
    /// name of its own, whose element k (declaration order, msb first — IEEE
    /// 1364 §12.3.9.2 binds the port's MSB to the expression's MSB) IS the
    /// parent net `elems[k]`. Lowering interns no node for it: each element
    /// aliases its net's node (`Lower.lowerModule`).
    port_concats: []const PortConcat = &.{},
};

pub const PortConcat = struct {
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
/// bridge — an instance of `module` — takes that upper connection on
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
/// included and empty at the top, so `path ++ local` is the flat name — the
/// same join `Flatten.join` makes.
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

/// Elaborate `ctx.file` into the design lowering walks. Borrows: every pointer
/// in the result points into the arena, which outlives it.
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

    // The tree of one. Returned BY POINTER, so a module with no children is
    // handed to lowering as the parser built it — same ids, same order, same
    // slices. This is the whole regression argument for putting a pass in front
    // of lowering: the case that does not need it does not touch it.
    //
    // A `defparam` with no instance to override is NOT that case: §6.3.1's path
    // names a parameter "in any module instance throughout the design", so with
    // no instance it names nothing, and E0907 is owed. The flatten is where that
    // is noticed, so the shortcut is declined for it.
    var gen: std.ArrayList(Ast.Instance) = .empty;
    for (top.analog) |blk| try genInstanceList(ctx.file, blk.body, ctx.arena, &gen);
    if (top.instances.len == 0 and top.defparams.len == 0 and gen.items.len == 0) {
        if (f.had_error) return error.DiagnosticsReported;
        return .{ .top = top };
    }

    return f.run(top);
}

/// Which module is the device (§6.2.2).
///
/// "The one nothing instantiates" — a root of the instance graph. With no
/// instantiation anywhere every module is trivially a root and the first
/// declaration wins, which is what a single-module file has always got; the
/// count only starts mattering once a file declares a child, and a child may be
/// declared FIRST (tests/fixtures/ch03_data_types/34_implicit_nets.va does).
///
/// Several roots is not diagnosed. A.1.2 lets a source_text hold unrelated
/// descriptions, `check.vh` fixtures do, and §6.2.1 gives no rule for choosing
/// between them — so the first one in source order is the answer, exactly as it
/// was before there were edges to count.
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

fn pickTop(ctx: Ctx) Error!*const Ast.ModuleDecl {
    const mods = ctx.file.modules;
    // Annex E: a candidate is a module the USER wrote. The shipped Table E.1
    // primitives instantiate nothing, so all nineteen are roots of the instance
    // graph and one of them would win every time. They still count as
    // instantiATORS below — a primitive that grew a child would be an edge like
    // any other — which is why only the outer loop is narrowed.
    for (ctx.file.userModules()) |*m| {
        // §7.6: a connect module is what the INSERTION PHASE puts on a mixed
        // net — "the disciplines of mixed nets are determined prior to the
        // connect module insertion phase" — not a design root. VerA does no
        // insertion, so nothing instantiates one and every connect module in
        // the file looks like a root here; picking one as the device would
        // elaborate a bridge as if the user had asked for it. Skipped in both
        // loops below, which makes a file of nothing but connect modules the
        // `NoModule` it already was when the keyword was a syntax error.
        if (m.is_connect) continue;
        var instantiated = false;
        for (mods) |*other| {
            var gen: std.ArrayList(Ast.Instance) = .empty;
            for (other.analog) |blk| try genInstanceList(ctx.file, blk.body, ctx.arena, &gen);
            for (other.instances) |inst| try gen.append(ctx.arena, inst);
            for (gen.items) |inst| {
                if (inst.module == m.name) instantiated = true;
                // §6.4 an instance that names a PARAMSET is an instance of the
                // module the paramset specializes, so it is an incoming edge on
                // that module. Without this the specialized module looks like a
                // root and a file whose paramset comes first elaborates the wrong
                // one — which is the whole of `pickTop`'s job.
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
    /// Applied by the walk and gone after it — nothing downstream reads it.
    consumed,
};

/// EVERY field of `Ast.ModuleDecl`, classified. `EnumFieldStruct` with no
/// default makes each entry required, so a field added to `ModuleDecl` is a
/// compile error here until someone decides what a CHILD's copy of it becomes.
/// That is the point: a child's `initial` blocks used to vanish because the
/// synthesized module simply never named `discrete`, and nothing noticed.
/// `run` builds its output from this table, so the table cannot drift from
/// what is published.
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
    .attrs = .merged,
    // `pickTop` never picks a connect module, so this is always the top's
    // `false`; a hand-placed one (§7.1) is a child like any other.
    .is_connect = .top,
    .main_tok = .top,
};

pub const Flatten = struct {
    ctx: Ctx,
    had_error: bool = false,

    /// Last `Ast.AnalogBlock.unit` handed out. 0 is the top, so the first
    /// inlined instance is 1. See that field for what it is for.
    last_unit: u32 = 0,
    /// §9.15/§9.16 one entry per unit id, in issue order (so index == unit id).
    unit_paths: std.ArrayList(UnitPath) = .empty,

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

    /// The discipline every flat net has been DECLARED with, keyed by the flat
    /// name — §3.10's precedence orders 1 and 2 after they have been decided.
    /// This used to scan `self.nets`, which grows with every inlined instance port, so
    /// resolving the N-th instance's bindings cost a walk over everything
    /// already flattened. Four sites append a net and all four go through
    /// `addNet`, which is what makes this table and `self.nets` agree by
    /// construction rather than by care.
    ///
    /// The top's ports are seeded FIRST (`run`), because the scan this replaces
    /// read them first: §6.5 the device's terminals are the top's, and a
    /// discipline resolved up the hierarchy lands on one of them.
    ///
    /// ONE discipline per net — the answer every consumer reads — and Annex
    /// F.2.1 step 4.b is why a second slot was never added here: 4.b needs the
    /// SET of candidates FILTERED BY DOMAIN ("more than one candidate whose
    /// domain matches"), and the mixed-port bullet under it needs a segment
    /// from the OTHER domain, so an arrival-ordered pair decides
    /// `annex_f_resolution/unknown_discipline_mixed_port.va`'s
    /// {continuous, continuous, discrete} correctly only if the source happens
    /// to write its two continuous instances first. The shape that decides it
    /// is the full per-net segment list, and that is `segs` — a SIDE table,
    /// so this map keeps being the one-slot answer and no reader learns a
    /// second concept.
    disc_of: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,

    /// Annex F.2.1 step 4.b's input, per flat net: EVERY discipline a child
    /// segment declared onto it, in arrival order, with the token of the first
    /// segment for the diagnostic. Fed by `resolveDiscipline` — the one place
    /// a port binding contributes a declared discipline to a parent net — and
    /// consumed once, after the walk, by `resolveMultiCandidates`. An ARRAY
    /// hash map so the post-pass visits nets in first-binding order and a
    /// design with two errors reports them deterministically.
    segs: std.AutoArrayHashMapUnmanaged(Ast.StrId, Segs) = .empty,

    /// The flat nets whose discipline came from a BOUND PORT rather than from a
    /// declaration — §3.6.5's implicit nets, which is exactly the set §7.4.4.1's
    /// continuous-wins rule is about. Without it that rule cannot be applied
    /// without also being able to overrule a real declaration.
    port_resolved: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,

    /// E.3.2's LAST source, deferred: every bound port of an analog primitive,
    /// whose own `electrical` is only "the default analog primitive" and so
    /// binds its net after the walk, and only if nothing else did (E.3.2.2 "If
    /// there are no continuous disciplines defined on the net segment").
    prim_ports: std.ArrayList(struct { path: []const u8, port: Ast.Port, bound: Ast.StrId }) = .empty,

    /// `Design.implicit_nets` / `Design.unconnected_inputs`, collected on the
    /// way through and published unchanged. Both are pure observations — see
    /// their doc comments for why the judging happens a stage later.
    implicit_nets: std.ArrayList(NameSite) = .empty,
    unconnected_inputs: std.ArrayList(NameSite) = .empty,
    port_concats: std.ArrayList(PortConcat) = .empty,

    /// §6.3.1 every `defparam` seen so far, keyed by the ABSOLUTE flat name of
    /// the parameter it overrides — the declaring module's own path joined with
    /// the path the source wrote, which is the same string the flattened
    /// parameter will be called. Collected on the way DOWN (`walkInstances`),
    /// which is before any instance below it is inlined, so a defparam is always
    /// in the map before the parameter it names is created.
    defparams: std.StringHashMapUnmanaged(Defparam) = .empty,

    /// Annex F.2.1 step 3 / §3.10 precedence order 1: every OUT-OF-CONTEXT
    /// discipline declaration, keyed by the absolute flat name of the net segment
    /// it declares — the same key shape as `defparams`, and for the same reason.
    /// "Apply all out-of-context node and signal declarations. For example,
    /// electrical top.middle.bottom.sig; overrides any discipline which may be
    /// declared for sig in the module where sig was declared."
    ooc: std.StringHashMapUnmanaged(Ast.NetDecl) = .empty,

    /// The rename map in force while cloning the CURRENT unit's body, plus the
    /// per-instance rewrites §9.19 and §9.18 need. Swapped by `inlineInstance`
    /// around the recursive call, so it is a stack discipline, not a field that
    /// outlives its unit.
    unit: Unit = .{},

    /// True while `paramsetOverrides` clones text written INSIDE a §6.4
    /// paramset body — the one scope §9.13.1/§9.13.2 admit a distribution
    /// call's `type_string` in. Set and cleared with the `unit` swap there;
    /// read by `cloneExpr`'s sys_call arm (`rewriteParamsetDist`).
    in_paramset: bool = false,

    /// True while cloning the branch a `<+` or an indirect assignment DRIVES.
    /// §6.3.6's second automatic rule divides "the value returned by any branch
    /// flow PROBE" by $mfactor, and a contribution's left-hand side is not a
    /// probe of the branch — it is the branch. Read by `cloneExpr`'s
    /// branch_access arm, which cannot otherwise tell the two apart.
    contrib_target: bool = false,

    /// One `segs` row: the disciplines a net's child segments declared, and
    /// where the first one was declared (the diagnostic anchor — the same
    /// "the DECLARATION's token" convention `resolveDiscipline`'s addNet
    /// states).
    const Segs = struct {
        discs: std.ArrayList(Ast.StrId) = .empty,
        tok: u32,
    };

    pub const Unit = struct {
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
        /// Annex E — is the unit being cloned a SHIPPED Table E.1 primitive.
        /// The one thing that is true of the prelude's bodies and of no user
        /// module: their `V`/`I` is Table E.1's nature-neutral spelling of the
        /// port pair's potential and flow, not a request for those two access
        /// functions. See `primitiveAccess`.
        primitive: bool = false,
        /// §9.18 the value `$mfactor` has in this unit, as an EXPRESSION in the
        /// flat namespace. `.none` at the top, where codegen answers Table
        /// 9-29's 1.0; below it the running product, which is why no constant
        /// folding is needed to get §9.18's "times the parent's value, and so
        /// on, until the top level is reached" right.
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
    /// lowers each child's analog blocks under its gate — the same runtime
    /// diamond `checkGenScheme` gives the analog items of an arm, so a model
    /// card overriding the scheme's parameter selects the arm it names.
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
        // segment, then the discipline shall default to electrical" — the
        // primitive's own declaration, on a net nothing else resolved.
        for (self.prim_ports.items) |pp| {
            const d = self.disc_of.get(pp.bound) orelse .none;
            if (d == .none or !discipline.isContinuous(self.ctx.file, d))
                try elab_resolve.resolveDiscipline(self, pp.path, pp.port, pp.bound, null);
        }

        // Annex F.2.1 step 4's multi-candidate arm, over the segment sets the
        // walk collected — after the walk because 4.b matches the COMPLETE
        // candidate set of a signal against §7.7.2's resolution statements.
        try elab_resolve.resolveMultiCandidates(self);

        // §5.2 analog blocks are CONCURRENT, so the order they land in carries no
        // meaning of its own — except through one rule that is stated in program
        // order: §5.4.2.2's flow read, where `I(b)` after a flow contribution to
        // `b` is the retained value and before one mints an unknown (lower.zig).
        // A child's equations are not statements of the parent's body, so a
        // parent reading the flow of a child's branch — E.3's Behavior column
        // read through §6.7.1, which is how Table E.1 is observable at all — must
        // see the child's contribution however the two blocks were written. The
        // top's own blocks therefore go in LAST, after every inlined child's.
        try self.analog.appendSlice(self.ctx.arena, top.analog);

        // §6.3.1 a defparam names "the parameter ... in any module instance
        // throughout the design" — so one that matched nothing named nothing.
        // Reported after the whole walk and not at the declaration, because that
        // is the first moment it is known: the instance a path names may be
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
        // §6.3.1 before the children, because a defparam applies DOWNWARD: its
        // path starts at an instance of this module and the values it overrides
        // are created as those instances are inlined below.
        for (module.defparams) |dp| {
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(dp.path) });
            try self.defparams.put(self.ctx.arena, key, .{
                .value = try elab_clone.cloneExpr(self, dp.value),
                .tok = dp.main_tok,
            });
        }

        // Annex F.2.1 step 3, same reason — an out-of-context declaration names a
        // segment BELOW this module, so it has to be in hand before the walk
        // reaches it. Its own error half is here too: "more than one conflicting
        // out-of-context discipline declaration for the same hierarchical segment
        // of a signal is an error", and §3.10 adds that two declarations at one
        // level of precedence are illegal whether or not the disciplines are
        // compatible — so this is a duplicate-KEY test and not a compatibility
        // test.
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
        // primitive", bound for every primitive of this level BEFORE any is
        // inlined — so E.3.2.2's scan, which gives an unattributed primitive
        // "the same discipline" as the others on its segment, finds the
        // segment resolved whatever order the source wrote the instances in.
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
            // declared is an implicit net. Collected HERE and not in
            // `inlineInstance`, which is the only other place a connection list
            // is read, because the question is "did THIS module declare it" and
            // this is the only loop that still has `module` in hand — one level
            // down the names have been flattened and the answer is unrecoverable.
            //
            // Not an error and not a declaration: see `Design.implicit_nets`.
            // The source's own connections, not `plan`'s segments, which are.
            if (!auto) for ((if (idx < module.instances.len) module.instances[idx] else inst).ports) |c| {
                const n = elab_names.netRefName(self, c.expr) orelse continue;
                if (declares(module, n)) continue;
                try self.implicit_nets.append(self.ctx.arena, .{
                    .name = self.ctx.file.str(n),
                    .main_tok = c.main_tok,
                });
            };

            // A.4.1 `module_instantiation ::= module_or_paramset_identifier ...`
            // — one production, two things it can name, and §6.4 says a paramset
            // "can be instantiated exactly like a module". A module first: §6.4.2
            // selection only runs when there is nothing else the name could be.
            //
            // A.5.4 `udp_instantiation` arrives here too: a NAMED udp_instance
            // is one token from a module_instance and the parser leaves it one
            // (`parseUdpInst`), so its `#( … )` reads as a
            // parameter_value_assignment. It is A.2.2.3's `delay2` — at most
            // two values, positional — and, like the unnamed form, the
            // instance reaches no analog device (W0252).
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
                try self.err(inst.main_tok, .E0905, "the instance tree is more than {d} levels deep at `{s}{s}`", .{
                    max_depth, path, self.ctx.file.str(inst.name),
                });
                return;
            }

            // §6.2.2 `name_of_module_instance ::= module_instance_identifier
            // [ range ]` — one instance per element, each separately addressable
            // per §6.7's `adder1[5].sum`.
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
                // The port IS the parent's net. No new node, no new
                // declaration: that identity is what makes the flatten a
                // topology join rather than a copy.
                // ponytail: the parent map already owns this lookup and fallback.
                const bound = parent.rename.get(n) orelse n;
                try unit.rename.put(self.ctx.arena, p.name, bound);
                // §6.7.1 the port still HAS a hierarchical name, and probing it
                // is legal — so the path has to resolve to the net it was joined
                // to. These are the only rows `Design.names` holds.
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
                    try elab_resolve.resolveDiscipline(self, path, p, bound, conn.?.main_tok);
                    const local = (try elab_resolve.oocDiscipline(self, path, p.name)) orelse p.discipline;
                    if (local != .none) try unit.port_disc.put(self.ctx.arena, p.name, local);
                }
            } else {
                // §6.2.2 "a blank port connection shall represent the situation
                // where the port is not to be connected", and an omitted named
                // port is the same thing. Unconnected still needs a node — the
                // child's equations reference it — so it becomes an internal net
                // of the device, carrying the port's own discipline.
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
                // IEEE 1364 §19.10's subject, exactly: an UNCONNECTED INPUT
                // port. `p.main_tok` is the port's own declaration, inside the
                // child's module definition, which is the position the directive
                // is looked up at — §19.10 pulls the unconnected inputs of the
                // modules DECLARED between the pair, not of the instances.
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
            // §3.10 precedence order 1, on an INTERNAL net of the child. This
            // is the clause's own printed example read literally: "electrical
            // top.middle.bottom.sig; overrides any discipline which may be
            // DECLARED FOR sig IN THE MODULE WHERE sig WAS DECLARED" — so the
            // thing it overrides is a local declaration, and a local
            // declaration of a net that is not a port is this loop.
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

    /// §6.2.2 which connection binds `port` (the i'th declared port), or null
    /// for "not in the list at all".
    // ponytail: binding needs only the connection list and port, not flattening state.
    pub fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) return if (i < inst.ports.len) inst.ports[i] else null;
        for (inst.ports) |c| if (c.name == port.name) return c;
        return null;
    }

    /// Did `module` declare a net called `name`? §3.6.5's test, and the whole of
    /// it: a net reference resolves to a §6.5 port of this module or to a §3.6.3
    /// net declaration in its body, and anything else the name could be — a
    /// parameter, a variable, a genvar — is not a net, so an actual that names
    /// one is a different error (E0906) and not an implicit net.
    ///
    /// ponytail: a linear scan per connection, so quadratic in a module's own
    /// declaration count. The bound is one module's source text and the constant
    /// is an integer compare; a hash set here would be built and thrown away for
    /// every instance. Build one per module the day a generated netlist puts
    /// thousands of nets and thousands of instances in one file.
    pub fn declares(module: *const Ast.ModuleDecl, name: Ast.StrId) bool {
        for (module.ports) |p| if (p.name == name) return true;
        for (module.nets) |n| if (n.name == name) return true;
        return false;
    }

    /// The ways a connection list can be malformed: longer than the port list,
    /// naming a port that does not exist, mixing the two spellings, or naming
    /// one port twice. §6.2.2 permits it to be SHORTER — that is the
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
            // A `.name(...)` later in an ordered list used to bind by POSITION
            // with the name silently ignored — the one shape of §6.2's mix the
            // named loop below cannot see, because the whole list was ordered.
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
            // 1364-2005 §12.3.6 (the base standard §6.2.2 builds on): a port is
            // connected at most once — `connectionFor`'s first-match-wins made a
            // second `.a(...)` vanish without a trace.
            for (inst.ports[0..i]) |prev| if (prev.name == c.name) {
                try self.err(c.main_tok, .E0906, "`{s}` is connected twice", .{self.ctx.file.str(c.name)});
                break;
            };
        }
    }

    /// §6.3 bind `#(...)` to the child's parameters, and §9.18's `.$mfactor`.
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
        // $mfactor_hier`. Carried as an EXPRESSION and not a number: the top's
        // own `$mfactor` is a value the host supplies (codegen answers Table
        // 9-29's 1.0), so the product is exact without folding anything, and a
        // specified factor may be any constant expression over the parent's
        // parameters.
        var mfactor = parent.mfactor;

        const named = inst.params.len != 0 and inst.params[0].name != .none;
        // §3.4.5: local parameters "cannot directly be modified with the
        // defparam statement or by the ordered or named parameter value
        // assignment" — so §6.3's "in the order of their declaration" is an
        // order over the OVERRIDABLE parameters only, and an ordered value
        // steps past every `is_local` entry instead of landing on it. The
        // named arm refuses a localparam by name below, for the same clause.
        var ord: usize = 0;
        for (inst.params) |o| {
            // The value is the PARENT's expression, so it is cloned under the
            // parent's map, not the child's.
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
                mfactor = if (mfactor == .none)
                    value
                else
                    try self.ctx.file.exprs.add(self.ctx.arena, .{
                        .tag = .binary,
                        .main_tok = o.main_tok,
                        .lhs = mfactor,
                        .rhs = value,
                        .extra = @intFromEnum(Ast.BinaryOp.mul),
                    });
                continue;
            }
            // §3.4.7 an aliasparam is a second NAME for one parameter, so an
            // override through it lands on the target.
            var target = o.name;
            for (child.aliasparams) |al| if (al.alias == o.name) {
                target = al.target;
                break;
            };
            const decl = for (child.params) |*p| {
                if (p.name == target) break p;
            } else {
                try self.err(o.main_tok, .E0907, "`{s}` is not a parameter of `{s}`", .{
                    self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                });
                continue;
            };
            // §3.4.5 a localparam is not overridable.
            if (decl.is_local) {
                try self.err(o.main_tok, .E0907, "`{s}` is a localparam of `{s}`", .{
                    self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                });
                continue;
            }
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

        // §6.3.1 LAST, and that order is the rule: "If a defparam assignment
        // conflicts with a module instance parameter, the parameter in the
        // module shall take the value specified by the defparam." So it
        // overwrites whatever `#(...)` put there, whichever came first in the
        // text. §3.4.5 is still honoured — a localparam was refused above and a
        // defparam onto one would be refused here for the same reason, which is
        // why the lookup is over the child's OVERRIDABLE parameters.
        for (child.params) |p| {
            if (p.is_local) continue;
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(p.name) });
            const dp = self.defparams.getPtr(key) orelse continue;
            dp.used = true;
            try over.put(self.ctx.arena, p.name, dp.value);
        }

        // §9.19 `$param_given` — decided here, once, for every parameter of the
        // child. It is a question about the INSTANTIATION, so it has one answer
        // per flattened parameter and the clone can substitute a literal.
        for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
        for (child.aliasparams) |al| if (over.contains(al.target))
            try unit.given.put(self.ctx.arena, al.alias, true);
    }

    // §6.4 paramsets: choosing and applying a paramset for an instance — elaborate/paramset.zig
    const elab_paramset = @import("elaborate/paramset.zig");
    pub const overridesParam = elab_paramset.overridesParam;

    // Annex F.2 discipline resolution across the hierarchy — elaborate/resolve.zig
    const elab_resolve = @import("elaborate/resolve.zig");
    pub const checkConnectRules = elab_resolve.checkConnectRules;
    pub const checkNetDisciplines = elab_resolve.checkNetDisciplines;

    // §7.8 automatic insertion of connect modules — elaborate/insert.zig
    const elab_insert = @import("elaborate/insert.zig");

    // Hierarchical names: instance paths and the flat names they produce — elaborate/names.zig
    const elab_names = @import("elaborate/names.zig");

    // The clone: copying a child module's AST into the flat design — elaborate/clone.zig
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

/// Annex E — the prelude is only a prefix of `modules` if the PREPROCESSOR ran,
/// so this is the one fixture that goes through it. `builtin_modules` is set the
/// way every non-test caller sets it (see `root.zig` stage 3); getting that wiring
/// wrong makes a Table E.1 primitive the top of every design, which is exactly
/// what this test would catch.
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
    // side is untouched — it names the branch, it is not a read of it.
    const flow = f.file.stmt(design.top.analog[0].body).contribute;
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(flow.lhs));
    try std.testing.expectEqual(Ast.BinaryOp.mul, x.binOp(flow.rhs));
    try std.testing.expectEqual(@as(f64, 4.0), x.realValue(x.rhs(flow.rhs)));

    // Rule 2: the POTENTIAL contribution is not scaled, but the flow probe
    // inside it is divided — one instance of 4 copies carries a quarter each.
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
    // defparam" — 5.0, not the instance's 2.0, whichever came first in the text.
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
    // is fc — which is neither candidate, per §7.7.2.1's "need not be one of
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

    // Bullet 4, legal half: same unknown, no discrete segment — the net keeps
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
    // naming one inlines it like any child — its analog block included.
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
