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
//! §6.5.7.1's vector-net distribution across an instance array is not here —
//! a port connection has to be a scalar net reference. The
//! §7.8 connect-module INSERTION phase is also not here, deliberately and
//! without a fixture owed: VerA emits ONE analog device, §7.6 puts insertion
//! after the resolution this file performs, and a bridge needs the digital
//! kernel the artifact does not contain — so §7.7.1 insertion statements are
//! validated (E0915) and then configure nothing.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const diag = @import("diag");
// §9.13's argument table and the kernels it names — `rewriteParamsetDist` folds
// an in-paramset draw with the SAME code a device embeds, so the two cannot
// disagree on the stream.
const Lower = @import("lower.zig");
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
    /// Mostly the identity, because the mangling IS the path (`Elaborate.sep`) —
    /// which is why a §6.7 reference costs lowering a string join and no tree
    /// walk. The entries that are NOT the identity are the ones that make the
    /// table necessary: a child port CONNECTED to a parent net is the same
    /// signal as that net, so `u.a` has to resolve to `p` — there is no node
    /// called `u.a` in the flattened design, and §6.7.1 still lets `V(u.a)` name
    /// it.
    ///
    /// Empty for a tree of one: with nothing renamed there is no path but the
    /// module's own names, and those resolve without it.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
};

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

    // The tree of one. Returned BY POINTER, so a module with no children is
    // handed to lowering as the parser built it — same ids, same order, same
    // slices. This is the whole regression argument for putting a pass in front
    // of lowering: the case that does not need it does not touch it.
    //
    // A `defparam` with no instance to override is NOT that case: §6.3.1's path
    // names a parameter "in any module instance throughout the design", so with
    // no instance it names nothing, and E0907 is owed. The flatten is where that
    // is noticed, so the shortcut is declined for it.
    if (top.instances.len == 0 and top.defparams.len == 0) {
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
            for (other.instances) |inst| {
                if (inst.module == m.name) instantiated = true;
                // §6.4 an instance that names a PARAMSET is an instance of the
                // module the paramset specializes, so it is an incoming edge on
                // that module. Without this the specialized module looks like a
                // root and a file whose paramset comes first elaborates the wrong
                // one — which is the whole of `pickTop`'s job.
                for (ctx.file.paramsets) |ps| {
                    if (ps.name == inst.module and ps.target == m.name) instantiated = true;
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

const Flatten = struct {
    ctx: Ctx,
    had_error: bool = false,

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
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,

    /// §6.7 path → flat name. See `Design.names`.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,

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

    /// One `segs` row: the disciplines a net's child segments declared, and
    /// where the first one was declared (the diagnostic anchor — the same
    /// "the DECLARATION's token" convention `resolveDiscipline`'s addNet
    /// states).
    const Segs = struct {
        discs: std.ArrayList(Ast.StrId) = .empty,
        tok: u32,
    };

    const Unit = struct {
        rename: Rename = .empty,
        /// §9.19 `$port_connected`: the child's local port name → was it given
        /// an expression in the connection list. Empty for the top, whose ports
        /// the host binds.
        connected: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
        /// §9.19 `$param_given`: local parameter name → was it overridden.
        given: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
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
    };

    fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
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
        for (top.ports) |p| try self.noteDiscipline(p.name, p.discipline);
        try self.addNets(top.nets);
        try self.branches.appendSlice(self.ctx.arena, top.branches);
        try self.genvars.appendSlice(self.ctx.arena, top.genvars);
        try self.events.appendSlice(self.ctx.arena, top.events);
        try self.functions.appendSlice(self.ctx.arena, top.functions);
        try self.attrs.appendSlice(self.ctx.arena, top.attrs);

        var stack: std.ArrayList(Ast.StrId) = .empty;
        try stack.append(self.ctx.arena, top.name);
        try self.walkInstances(top, "", &stack, 0);

        // Annex F.2.1 step 4's multi-candidate arm, over the segment sets the
        // walk collected — after the walk because 4.b matches the COMPLETE
        // candidate set of a signal against §7.7.2's resolution statements.
        try self.resolveMultiCandidates();

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

        if (self.had_error) return error.DiagnosticsReported;

        const out = try self.ctx.arena.create(Ast.ModuleDecl);
        out.* = .{
            .name = top.name,
            .main_tok = top.main_tok,
            .ports = top.ports, // §6.5 the device's terminals are the top's
            .params = self.params.items,
            .aliasparams = self.aliasparams.items,
            .vars = self.vars.items,
            .nets = self.nets.items,
            .branches = self.branches.items,
            .genvars = self.genvars.items,
            .events = self.events.items,
            .functions = self.functions.items,
            .analog = self.analog.items,
            .attrs = self.attrs.items,
            // Flattened away. Nothing after this pass reads it, and leaving the
            // children in would make lowering elaborate them a second time.
            .instances = &.{},
        };
        return .{ .top = out, .names = self.names };
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
                .value = try self.cloneExpr(dp.value),
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
            if (!isOoc(self.ctx.file.str(n.name))) continue;
            const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(n.name) });
            if (self.ooc.get(key)) |first| {
                try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                    key, self.ctx.file.str(first.discipline),
                });
                continue;
            }
            try self.ooc.put(self.ctx.arena, key, n);
        }

        for (module.instances) |inst| {
            // A.4.1 `module_instantiation ::= module_or_paramset_identifier ...`
            // — one production, two things it can name, and §6.4 says a paramset
            // "can be instantiated exactly like a module". A module first: §6.4.2
            // selection only runs when there is nothing else the name could be.
            var ps: ?*const Ast.ParamsetDecl = null;
            const child = self.findModule(inst.module) orelse blk: {
                ps = try self.selectParamset(&inst) orelse continue;
                break :blk self.findModule(ps.?.target) orelse {
                    try self.err(ps.?.main_tok, .E0904, "`{s}`, the module this paramset specializes", .{
                        self.ctx.file.str(ps.?.target),
                    });
                    continue;
                };
            };
            // §7.6/§7.7: a connect module is placed by the connect module
            // INSERTION PHASE, selected by a `connect` specification statement —
            // "the designer can choose and specialize those in the design via the
            // connect specification statements". It is not a child a module names.
            // Refused rather than inlined because inlining one would be silently
            // WRONG in a way the reader cannot see: the flatten carries analog
            // blocks and drops `discrete` ones, so a bridge's continuous half
            // would be stamped into the device with its digital half missing.
            if (child.is_connect) {
                try self.err(inst.main_tok, .E0913, "`{s}` is declared with `connectmodule`, and §7.6 has the insertion phase place it on a mixed net", .{
                    self.ctx.file.str(child.name),
                });
                continue;
            }
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
                const msb = self.constInt(r.msb) orelse {
                    try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
                    continue;
                };
                const lsb = self.constInt(r.lsb) orelse {
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
                try self.inlineInstance(&inst, child, ps, child_path, stack, depth);
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
    ) Error!void {
        const parent = self.unit; // restored below; the rename map is a stack
        var unit: Unit = .{ .primitive = self.isPrimitive(child) };

        // ---- §6.2.2 port connections ---------------------------------------
        // Resolved in the PARENT's namespace, which means through the parent's
        // rename map: an actual naming a net of a mid-level module has already
        // been flattened to `u.n`.
        for (child.ports, 0..) |p, i| {
            const conn = connectionFor(inst, p, i);
            try unit.connected.put(self.ctx.arena, p.name, conn != null and conn.?.expr != .none);
            const actual: ?Ast.StrId = if (conn) |c| self.netRefName(c.expr) else null;
            if (actual) |n| {
                // The port IS the parent's net. No new node, no new
                // declaration: that identity is what makes the flatten a
                // topology join rather than a copy.
                // ponytail: the parent map already owns this lookup and fallback.
                const bound = parent.rename.get(n) orelse n;
                try unit.rename.put(self.ctx.arena, p.name, bound);
                // §6.7.1 the port still HAS a hierarchical name, and probing it
                // is legal — so the path has to resolve to the net it was joined
                // to. This is the entry that makes `Design.names` more than an
                // identity map.
                try self.names.put(
                    self.ctx.arena,
                    try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(p.name) }),
                    self.ctx.file.str(bound),
                );
                try self.resolveDiscipline(path, p, bound);
            } else {
                // §6.2.2 "a blank port connection shall represent the situation
                // where the port is not to be connected", and an omitted named
                // port is the same thing. Unconnected still needs a node — the
                // child's equations reference it — so it becomes an internal net
                // of the device, carrying the port's own discipline.
                const internal = try self.join(path, p.name);
                try unit.rename.put(self.ctx.arena, p.name, internal);
                try self.addNet(.{
                    .name = internal,
                    // §3.10 order 1 still beats the local declaration on a port
                    // nobody connected: the segment exists, it is just the only
                    // segment of its signal.
                    .discipline = (try self.oocDiscipline(path, p.name)) orelse p.discipline,
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
            try self.paramsetOverrides(inst, p, child, &parent, &over, &unit, path)
        else
            try self.collectOverrides(inst, child, &parent, &over, &unit, path);

        // ---- names: every local declaration gets its flat spelling ----------
        for (child.params) |p| try self.bind(&unit, path, p.name);
        for (child.aliasparams) |al| try self.bind(&unit, path, al.alias);
        for (child.nets) |n| try self.bind(&unit, path, n.name);
        for (child.vars) |v| try self.bind(&unit, path, v.name);
        for (child.branches) |b| try self.bind(&unit, path, b.name);
        for (child.genvars) |g| try self.bind(&unit, path, g);
        for (child.events) |e| try self.bind(&unit, path, e);
        for (child.functions) |fd| try self.bind(&unit, path, fd.name);
        for (child.instances) |sub| try self.bind(&unit, path, sub.name);

        self.unit = unit;

        // ---- the declarations themselves -----------------------------------
        try self.cloneParams(child.params, child.aliasparams, &over);
        for (child.nets) |n| {
            // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
            // already collected by `walkInstances`. It declares no net HERE.
            if (isOoc(self.ctx.file.str(n.name))) continue;
            var out = n;
            out.name = self.flat(n.name);
            out.range = try self.cloneDim(n.range);
            out.init = try self.cloneExpr(n.init);
            // §3.10 precedence order 1, on an INTERNAL net of the child. This
            // is the clause's own printed example read literally: "electrical
            // top.middle.bottom.sig; overrides any discipline which may be
            // DECLARED FOR sig IN THE MODULE WHERE sig WAS DECLARED" — so the
            // thing it overrides is a local declaration, and a local
            // declaration of a net that is not a port is this loop.
            if (try self.oocDiscipline(path, n.name)) |d| out.discipline = d;
            try self.addNet(out);
        }
        for (child.vars) |v| try self.vars.append(self.ctx.arena, try self.cloneVar(v));
        for (child.branches) |b| {
            var out = b;
            out.name = self.flat(b.name);
            out.hi = try self.cloneExpr(b.hi);
            out.lo = try self.cloneExpr(b.lo);
            out.range = try self.cloneDim(b.range);
            try self.branches.append(self.ctx.arena, out);
        }
        for (child.genvars) |g| try self.genvars.append(self.ctx.arena, self.flat(g));
        for (child.events) |e| try self.events.append(self.ctx.arena, self.flat(e));
        for (child.functions) |fd| try self.functions.append(self.ctx.arena, try self.cloneFunc(fd));
        for (child.attrs) |at| try self.attrs.append(self.ctx.arena, .{
            .name = at.name,
            .value = try self.cloneExpr(at.value),
            .main_tok = at.main_tok,
        });
        for (child.analog) |blk| try self.analog.append(self.ctx.arena, .{
            .is_initial = blk.is_initial,
            .body = try self.cloneStmt(blk.body),
            .main_tok = blk.main_tok,
        });

        // ---- recurse, with this unit's map in force ------------------------
        try stack.append(self.ctx.arena, child.name);
        try self.walkInstances(child, path, stack, depth + 1);
        _ = stack.pop();

        self.unit = parent;
    }

    /// §6.2.2 which connection binds `port` (the i'th declared port), or null
    /// for "not in the list at all".
    // ponytail: binding needs only the connection list and port, not flattening state.
    fn connectionFor(inst: *const Ast.Instance, port: Ast.Port, i: usize) ?Ast.PortConn {
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) return if (i < inst.ports.len) inst.ports[i] else null;
        for (inst.ports) |c| if (c.name == port.name) return c;
        return null;
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
    fn collectOverrides(
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
            const value = self.cloneExpr(o.value) catch |e| {
                self.unit = saved;
                return e;
            };
            self.unit = saved;

            if (!named) {
                // §6.3 "in the order of their declaration".
                while (ord < child.params.len and child.params[ord].is_local) ord += 1;
                if (ord >= child.params.len) {
                    const n = overridableCount(child.params);
                    try self.err(o.main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this instance overrides {d}", .{
                        self.ctx.file.str(child.name), n,
                        if (n == 1) "" else "s", inst.params.len,
                    });
                    continue;
                }
                try over.put(self.ctx.arena, child.params[ord].name, value);
                ord += 1;
                continue;
            }
            if (self.ctx.file.strings.eql(o.name, "$mfactor")) {
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

    // ---- §6.4 paramsets ---------------------------------------------------

    /// §6.4.2 which paramset of an overload set this instance uses.
    ///
    /// "Paramset identifiers need not be unique: multiple paramsets can be
    /// declared using the same paramset_identifier ... During elaboration, the
    /// simulator shall choose an appropriate paramset from the set that shares a
    /// given name for every instance that references that name."
    ///
    /// Two phases, straight from the clause. The selection rules — "the
    /// following rules shall be enforced" — cut the overload set down to the
    /// applicable paramsets (`paramsetAdmits`). Then: "The rules above may not
    /// be sufficient for the simulator to pick a unique paramset, in which case
    /// the following rules shall be applied in order until a unique paramset
    /// has been selected:"
    ///
    ///   1. "The paramset with the fewest number of un-overridden parameters
    ///      shall be selected." — §6.4.2's own m3 example: the default paramset
    ///      (l, w, both overridden) beats the long-channel one (ad, as left at
    ///      their defaults);
    ///   2. "The paramset with the greatest number of local parameters with
    ///      specified ranges shall be selected."
    ///   3. "The paramset with the fewest ports not connected in the instance
    ///      line shall be selected." — over the TARGET module's port list,
    ///      since same-named paramsets "may refer to different modules".
    ///
    /// "It shall be an error if there are still more than one applicable
    /// paramset for an instance after application of these rules" — E0914. A
    /// set where NOTHING survives selection is E0911, because that instance has
    /// no paramset and the LRM's own binning examples rely on exactly one
    /// surviving.
    fn selectParamset(self: *Flatten, inst: *const Ast.Instance) Error!?*const Ast.ParamsetDecl {
        var candidates: usize = 0;
        var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
        for (self.ctx.file.paramsets) |*ps| {
            if (ps.name != inst.module) continue;
            candidates += 1;
            if (self.paramsetAdmits(inst, ps)) try live.append(self.ctx.arena, ps);
        }
        if (live.items.len == 0) {
            if (candidates == 0) {
                try self.err(inst.main_tok, .E0904, "`{s}`", .{self.ctx.file.str(inst.module)});
            } else {
                try self.err(inst.main_tok, .E0911, "`{s}`: no paramset named `{s}` admits these parameter values", .{
                    self.ctx.file.str(inst.name), self.ctx.file.str(inst.module),
                });
            }
            return null;
        }
        // "applied in order until a unique paramset has been selected".
        if (live.items.len > 1) try self.tieBreak(inst, &live, .un_overridden);
        if (live.items.len > 1) try self.tieBreak(inst, &live, .ranged_locals);
        if (live.items.len > 1) try self.tieBreak(inst, &live, .unconnected_ports);
        if (live.items.len > 1) {
            try self.err(inst.main_tok, .E0914, "`{s}`: {d} paramsets named `{s}` are still applicable after §6.4.2's tie-breaking rules", .{
                self.ctx.file.str(inst.name), live.items.len, self.ctx.file.str(inst.module),
            });
            return null;
        }
        return live.items[0];
    }

    /// The three §6.4.2 tie-breaking rules, in the clause's order.
    const TieRule = enum { un_overridden, ranged_locals, unconnected_ports };

    /// Apply ONE tie-breaking rule: score every surviving candidate and keep
    /// the minimum (a "greatest" rule negates its count, so one comparison
    /// direction serves all three).
    fn tieBreak(
        self: *Flatten,
        inst: *const Ast.Instance,
        live: *std.ArrayList(*const Ast.ParamsetDecl),
        rule: TieRule,
    ) Error!void {
        const scores = try self.ctx.arena.alloc(i64, live.items.len);
        for (live.items, scores) |ps, *s| s.* = switch (rule) {
            // "the fewest number of un-overridden parameters": the paramset's
            // overridable parameters the instance left at their defaults. A
            // localparam is not counted — it is not overridable at all (§3.4.5),
            // so it says nothing about how specifically this instance names
            // this bin, and §6.4.2's neighbouring rules treat "parameters" and
            // "local parameters" as disjoint counts.
            .un_overridden => blk: {
                const overridable: i64 = @intCast(overridableCount(ps.params));
                const named = inst.params.len != 0 and inst.params[0].name != .none;
                if (!named) {
                    // §6.3 ordered values land on the first inst.params.len
                    // overridable parameters, so the remainder is the count.
                    break :blk @max(0, overridable - @as(i64, @intCast(inst.params.len)));
                }
                var n: i64 = 0;
                for (ps.params) |p| {
                    if (p.is_local) continue;
                    n += @intFromBool(!overridesParam(inst, ps, p.name));
                }
                break :blk n;
            },
            // "the greatest number of local parameters with specified ranges" —
            // negated, see above.
            .ranged_locals => blk: {
                var n: i64 = 0;
                for (ps.params) |p| n += @intFromBool(p.is_local and p.ranges.len != 0);
                break :blk -n;
            },
            // "the fewest ports not connected in the instance line". A target
            // module the file never declares scores worst; if such a candidate
            // is selected anyway, E0904 names it at the use site.
            .unconnected_ports => blk: {
                const child = self.findModule(ps.target) orelse break :blk std.math.maxInt(i64);
                var n: i64 = 0;
                for (child.ports, 0..) |p, i| {
                    const conn = connectionFor(inst, p, i);
                    n += @intFromBool(conn == null or conn.?.expr == .none);
                }
                break :blk n;
            },
        };
        var best = scores[0];
        for (scores[1..]) |s| best = @min(best, s);
        var w: usize = 0;
        for (live.items, scores) |ps, s| if (s == best) {
            live.items[w] = ps;
            w += 1;
        };
        live.shrinkRetainingCapacity(w);
    }

    /// §3.4.5 the parameters an override CAN land on: the non-`is_local` ones.
    fn overridableCount(params: []const Ast.ParamDecl) usize {
        var n: usize = 0;
        for (params) |p| n += @intFromBool(!p.is_local);
        return n;
    }

    /// Does a NAMED instance override land on paramset parameter `name`,
    /// directly or through a §3.4.7 alias?
    fn overridesParam(inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl, name: Ast.StrId) bool {
        for (inst.params) |o| {
            if (o.name == name) return true;
            for (ps.aliasparams) |al| if (al.alias == o.name and al.target == name) return true;
        }
        return false;
    }

    /// §6.4.2's SELECTION rules — "When choosing an appropriate paramset, the
    /// following rules shall be enforced" — as far as each is decidable here:
    ///
    ///   1. "All parameters overridden on the instance shall be parameters of
    ///      the paramset" — and §3.4.5 keeps a localparam out of an override's
    ///      reach, so a paramset whose only `x` is local does not admit an
    ///      override of `x`, in either spelling;
    ///   2. "The parameters of the paramset, with overrides and defaults, shall
    ///      be all within the allowed ranges specified in the paramset
    ///      parameter declaration" — which is what makes a BINNED set (§6.4.2's
    ///      short- and long-channel pair, annex E's `spice_binning`) select on
    ///      geometry;
    ///   3. "The local parameters of the paramset, computed from parameters,
    ///      shall be within the allowed ranges specified in the paramset" —
    ///      their defaults ride the same loop, and `constReal` folds only
    ///      literals, so a computed value is judged exactly as far as it can be
    ///      folded (see `inRanges` for why unfoldable admits);
    ///   4. "The underlying module shall have a port declared for each port
    ///      connected in the instance line." A target module the file never
    ///      declares cannot fail it — that absence is E0904's, at the use site.
    fn paramsetAdmits(self: *Flatten, inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl) bool {
        const named = inst.params.len != 0 and inst.params[0].name != .none;
        if (!named and inst.params.len > overridableCount(ps.params)) return false;
        var ord: usize = 0;
        for (ps.params) |p| {
            // §6.4.2 "with overrides and defaults": the value this paramset would
            // give the parameter, whichever supplied it. An `is_local` entry
            // takes no override in either spelling (§3.4.5), so its default is
            // the value judged — criterion 3.
            var value = p.default;
            if (p.is_local) {
                // keep the default
            } else if (named) {
                for (inst.params) |o| {
                    if (o.name == p.name) value = o.value;
                }
            } else {
                if (ord < inst.params.len) value = inst.params[ord].value;
                ord += 1;
            }
            if (!self.inRanges(value, p.ranges)) return false;
        }
        if (named) for (inst.params) |o| {
            // §9.18's system parameters are not the paramset's to declare.
            if (self.ctx.file.strings.eql(o.name, "$mfactor")) continue;
            const found = for (ps.params) |p| {
                if (!p.is_local and p.name == o.name) break true;
            } else for (ps.aliasparams) |al| {
                if (al.alias == o.name) break true;
            } else false;
            if (!found) return false;
        };
        // Criterion 4, both connection spellings. A mixed or malformed list is
        // not judged here — that is E0906's, after selection
        // (`checkConnectionShape`).
        if (self.findModule(ps.target)) |child| {
            const conns_named = inst.ports.len != 0 and inst.ports[0].name != .none;
            if (conns_named) {
                for (inst.ports) |c| {
                    if (c.name == .none) continue;
                    const found = for (child.ports) |p| {
                        if (p.name == c.name) break true;
                    } else false;
                    if (!found) return false;
                }
            } else if (inst.ports.len > child.ports.len) return false;
        }
        return true;
    }

    /// §3.4.2 does this value satisfy the declared `from`/`exclude` ranges?
    ///
    /// ponytail: a value or a bound this cannot FOLD counts as admissible. The
    /// alternative is to reject a paramset for being written over an expression
    /// the elaborator declines to evaluate, which would turn a missing folder
    /// into a selection error; `Lower` still judges the value it ends up with
    /// (E0361), so nothing is lost, only deferred.
    fn inRanges(self: *Flatten, value: Ast.ExprId, ranges: []const Ast.ValueRange) bool {
        if (ranges.len == 0) return true;
        const v = self.constReal(value) orelse return true;
        var has_from = false;
        var in_from = false;
        for (ranges) |r| {
            const lo = self.constReal(r.lo) orelse return true;
            const hi = if (r.hi == .none) lo else self.constReal(r.hi) orelse return true;
            const above = if (r.lo_inclusive) v >= lo else v > lo;
            const below = if (r.hi_inclusive) v <= hi else v < hi;
            switch (r.kind) {
                .from => {
                    has_from = true;
                    if (above and below) in_from = true;
                },
                .exclude => if (above and below) return false,
            }
        }
        return !has_from or in_from;
    }

    /// A constant this pass can fold: §2.6 literals, the A.2.5 infinities, and
    /// the arithmetic over them. NOT parameter reads — the parameter table is
    /// lowering's, and §6.4.2's ranges in every printed example are literals.
    fn constReal(self: *Flatten, e: Ast.ExprId) ?f64 {
        if (e == .none) return null;
        const x = &self.ctx.file.exprs;
        return switch (x.tag(e)) {
            .int_literal => @floatFromInt(x.intValue(e)),
            .real_literal => x.realValue(e),
            .pos_inf => std.math.inf(f64),
            .neg_inf => -std.math.inf(f64),
            .unary => blk: {
                const v = self.constReal(x.lhs(e)) orelse break :blk null;
                break :blk switch (x.unOp(e)) {
                    .plus => v,
                    .minus => -v,
                    else => null,
                };
            },
            .binary => blk: {
                const l = self.constReal(x.lhs(e)) orelse break :blk null;
                const r = self.constReal(x.rhs(e)) orelse break :blk null;
                break :blk switch (x.binOp(e)) {
                    .add => l + r,
                    .sub => l - r,
                    .mul => l * r,
                    .div => l / r,
                    else => null,
                };
            },
            else => null,
        };
    }

    /// §6.4 the parameter values a paramset instance gives the module.
    ///
    /// Two levels, and the order between them is the whole clause: the INSTANCE
    /// overrides the paramset's own parameters, and the paramset's statements
    /// then compute the MODULE's from those. `.k = 2.0 * gain;` with the instance
    /// saying `#(.gain(3.0))` means the module's `k` is 6.0 — not 3.0 (which is
    /// passing the override straight through) and not 2.0 (which is ignoring the
    /// instance).
    ///
    /// The paramset's own parameters become localparams of the flat design under
    /// `path ++ paramset_name ++ sep`, one level below the instance's own path.
    /// They need to be somewhere — a statement's value reads them — and they are
    /// not the module's, so they cannot share the module's level: `u.gain` is the
    /// module's parameter if the module declares one, and `u.ch6_ps.gain` is the
    /// paramset's. Deterministic, readable, and injective for the same reason
    /// every other flat name is (`sep`).
    fn paramsetOverrides(
        self: *Flatten,
        inst: *const Ast.Instance,
        ps: *const Ast.ParamsetDecl,
        child: *const Ast.ModuleDecl,
        parent: *const Unit,
        over: *std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
        unit: *Unit,
        path: []const u8,
    ) Error!void {
        const ps_path = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}{c}", .{ path, self.ctx.file.str(ps.name), sep });

        // ---- level 1: the paramset's own parameters, overridden by the instance
        var ps_unit: Unit = .{ .mfactor = parent.mfactor };
        var ps_over: std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId) = .empty;
        // A synthesized instance of the paramset-as-unit: same overrides, no
        // ports. `collectOverrides` already implements §6.3's ordered/named
        // arms, §3.4.7's alias handling and §9.18's `.$mfactor`, and a paramset's
        // parameter list is a §3.4 parameter list — so this is that code, not a
        // second copy of it.
        const as_module: Ast.ModuleDecl = .{
            .name = ps.name,
            .ports = &.{},
            .params = ps.params,
            .aliasparams = ps.aliasparams,
            .main_tok = ps.main_tok,
        };
        try self.collectOverrides(inst, &as_module, parent, &ps_over, &ps_unit, ps_path);
        for (ps.params) |p| try self.bind(&ps_unit, ps_path, p.name);
        for (ps.aliasparams) |al| try self.bind(&ps_unit, ps_path, al.alias);

        const saved = self.unit;
        self.unit = ps_unit;
        // Everything cloned from here to the restore is paramset-body text —
        // the instance's own override values (`ps_over`) were already cloned
        // by `collectOverrides` above, in the parent's scope.
        self.in_paramset = true;
        try self.cloneParams(ps.params, ps.aliasparams, &ps_over);

        // ---- level 2: the module's parameters, from the paramset's statements
        for (ps.overrides) |o| {
            switch (o.kind) {
                .module_param => {
                    const decl = for (child.params) |*p| {
                        if (p.name == o.name) break p;
                    } else {
                        try self.err(o.main_tok, .E0907, "`{s}` is not a parameter of `{s}`", .{
                            self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                        });
                        continue;
                    };
                    if (decl.is_local) {
                        try self.err(o.main_tok, .E0907, "`{s}` is a localparam of `{s}`", .{
                            self.ctx.file.str(o.name), self.ctx.file.str(child.name),
                        });
                        continue;
                    }
                    try over.put(self.ctx.arena, o.name, try self.cloneExpr(o.value));
                },
                // §9.18 `.$mfactor = expr;` in a paramset is the same override the
                // instance's `.$mfactor(expr)` is, so it multiplies the same way.
                .system_param => {
                    if (!self.ctx.file.strings.eql(o.name, "$mfactor")) {
                        try self.err(o.main_tok, .E0907, "`{s}` is not a system parameter this paramset can set", .{
                            self.ctx.file.str(o.name),
                        });
                        continue;
                    }
                    const v = try self.cloneExpr(o.value);
                    ps_unit.mfactor = if (ps_unit.mfactor == .none) v else try self.ctx.file.exprs.add(self.ctx.arena, .{
                        .tag = .binary,
                        .main_tok = o.main_tok,
                        .lhs = ps_unit.mfactor,
                        .rhs = v,
                        .extra = @intFromEnum(Ast.BinaryOp.mul),
                    });
                },
                .output_var => {}, // §6.4.3, dropped in the parser — see there
            }
        }
        self.in_paramset = false;
        self.unit = saved;

        unit.mfactor = ps_unit.mfactor;
        // §9.19 as for a module instance: decided here, once, per parameter.
        for (child.params) |p| try unit.given.put(self.ctx.arena, p.name, over.contains(p.name));
        for (child.aliasparams) |al| if (over.contains(al.target))
            try unit.given.put(self.ctx.arena, al.alias, true);
    }

    // ---- Annex F.2 discipline resolution ----------------------------------

    /// Is this declared name an out-of-context one? A period can only have come
    /// from a hierarchical path (see `sep`), so the test is the presence of one.
    fn isOoc(name: []const u8) bool {
        return std.mem.indexOfScalar(u8, name, sep) != null;
    }

    /// A net declaration that is not a declaration of THIS module's net: it is
    /// dropped from the flattened module, because its whole content is the
    /// discipline it contributes to a segment somewhere below (`ooc`), and a net
    /// under a dotted name would otherwise reach lowering as a node nothing
    /// connects.
    fn addNets(self: *Flatten, nets: []const Ast.NetDecl) Error!void {
        for (nets) |n| {
            if (isOoc(self.ctx.file.str(n.name))) continue;
            try self.addNet(n);
        }
    }

    /// THE insertion point for a net of the flattened module. Nothing appends to
    /// `self.nets` directly: `disc_of` is only as complete as this is exclusive.
    fn addNet(self: *Flatten, n: Ast.NetDecl) Error!void {
        try self.nets.append(self.ctx.arena, n);
        try self.noteDiscipline(n.name, n.discipline);
    }

    /// Record a declared discipline for a flat net. FIRST wins, which is what
    /// the scan this replaces did — see `disc_of` for why there is no second
    /// slot, and `resolveDiscipline` for what first-wins still costs.
    fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) Error!void {
        if (disc == .none) return;
        const gop = try self.disc_of.getOrPut(self.ctx.arena, name);
        if (!gop.found_existing) gop.value_ptr.* = disc;
    }

    /// §3.6.2.2: is this discipline continuous?
    ///
    /// `domain` is `.unspecified` unless the source wrote one, and the clause
    /// makes binding a nature the deciding property — a discipline with a
    /// potential or a flow is continuous whether or not it says so. Nothing in
    /// this file asked what domain a discipline was in before §7.4.4.1 needed
    /// it; `primitiveAccess` is the other site that resolves a name to a
    /// `DisciplineDecl`, and it scans the same way.
    fn isContinuous(self: *Flatten, disc: Ast.StrId) bool {
        if (disc == .none) return false;
        const d = for (self.ctx.file.disciplines) |*x| {
            if (x.name == disc) break x;
        } else return false;
        return switch (d.domain) {
            .continuous => true,
            .discrete => false,
            .unspecified => d.potential != .none or d.flow != .none,
        };
    }

    /// §3.10 precedence order 1: the out-of-context discipline for one segment,
    /// if a declaration named it.
    ///
    /// Consulted at all three places a segment gets its discipline: a bound port
    /// (`resolveDiscipline`), an unconnected one, and — since wave 13 — the
    /// child-net loop, which is a child's own INTERNAL net. The clause's printed
    /// example decides that last one: "electrical top.middle.bottom.sig;
    /// overrides any discipline which may be declared for sig IN THE MODULE
    /// WHERE SIG WAS DECLARED", and the module where a name was declared is the
    /// module holding its declaration, port or not.
    /// `annex_f_resolution/out_of_context_internal_net.va` is the fixture; it
    /// FAILs on the one-line removal of that call.
    ///
    /// ponytail: an out-of-context declaration that matched NOTHING is not
    /// diagnosed, the way an unmatched `defparam` is (E0907). A `defparam` names
    /// a parameter and nothing else can absorb it; a net declaration under a
    /// dotted name is indistinguishable from here from a legal form this pass
    /// simply does not reach, so reporting it would report correct programs. The
    /// upgrade is a `used` flag on `ooc`, exactly like `Defparam.used`, once
    /// every consumer of the table is in.
    fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) Error!?Ast.StrId {
        // The same allocPrint join every sibling key builds (`defparams`,
        // `walkInstances`). This was a fixed 256-byte bufPrint whose overflow
        // was `catch return null` — a path longer than the buffer silently lost
        // its out-of-context declaration, which is a wrong DISCIPLINE, not a
        // wrong diagnostic.
        const key = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(local) });
        const n = self.ooc.get(key) orelse return null;
        return if (n.discipline == .none) null else n.discipline;
    }

    /// Annex F.2 / §7.4, for the one shape a FLATTENED design has of it.
    ///
    /// F.2: "A net segment of a signal on the upper connection of a port shall be
    /// considered as the parent to a net segment on the lower connection of the
    /// port ... the continuous domain is passed up the hierarchy from lower levels
    /// to the top level." Flattening has already collapsed every segment of one
    /// signal into a single node (Ruling E) — the join in the branch above IS
    /// F.2's parent/child relation — so what is left of the traversal is: a
    /// segment that declares a discipline gives it to the signal, and an
    /// undeclared parent segment inherits it. That is exactly steps 4.a and 4.b's
    /// single-discipline case, and the depth-first walk supplies the ORDER for
    /// free, since a child is inlined after its parent's own declarations are in.
    ///
    /// DURING the walk, first declaration wins (plus §7.4.4.1's
    /// continuous-over-discrete upgrade below) — which is 4.b decided
    /// correctly wherever the matching-domain candidate set has AT MOST ONE
    /// member, i.e. every design without a `connect ... resolveto` question to
    /// ask. The multi-candidate arm cannot run here: 4.b wants the candidates
    /// partitioned by domain and matched as a SET against §7.7.2's resolution
    /// statements, and the set is not complete until every segment of the
    /// signal has been walked. So this function also FEEDS `segs`, and
    /// `resolveMultiCandidates` re-decides, after the walk, exactly the nets
    /// where more than one matching-domain candidate arrived — everywhere
    /// else the post-pass is a no-op and first-wins IS the answer, which is
    /// what keeps every pre-`connectrules` fixture's behaviour bit-identical.
    ///
    /// TWO declared segments of one signal are still not JUDGED here: that is
    /// §3.11's Signal Connection Rule (compatible disciplines) and lowering
    /// owns it (E0902 for one net, two declarations). What the post-pass adds
    /// is only what F.2.1 4.b states over the multi-candidate list — resolve
    /// by statement, or unknown, or E0903.
    fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId) Error!void {
        const disc = (try self.oocDiscipline(path, p.name)) orelse p.discipline;
        if (disc == .none) return;
        // F.2 step 4.b's raw material: this port's lower connection is a child
        // segment of `bound`, and it declares `disc`. Recorded UNCONDITIONALLY
        // — whether the net resolves here, later, or was declared outright —
        // because the post-pass, not this arrival, is what knows which nets
        // have a question left (`port_resolved` gates it there).
        {
            const gop = try self.segs.getOrPut(self.ctx.arena, bound);
            if (!gop.found_existing) gop.value_ptr.* = .{ .tok = p.main_tok };
            try gop.value_ptr.discs.append(self.ctx.arena, disc);
        }
        const declared = self.disc_of.get(bound) orelse .none;
        if (declared != .none) {
            // §7.4.4.1, and it is the whole of the basic mode's rule: "At each
            // level of the hierarchy where continuous and discrete meet for an
            // undeclared net that net segment is declared continuous." The
            // clause's own worked example says it twice — "NetC resolves to
            // electrical based on continuous (electrical) winning over discrete
            // (cmos2)".
            //
            // Only for a net THIS function resolved. A net the source declared
            // is not an undeclared interconnect, and §3.10's precedence already
            // decided it; upgrading one here would silently overrule a
            // declaration. `port_resolved` is what draws that line — first-wins
            // still holds everywhere else, which is what `noteDiscipline` says.
            if (!self.port_resolved.contains(bound)) return;
            if (self.isContinuous(declared)) return;
            if (!self.isContinuous(disc)) return;
            self.disc_of.putAssumeCapacity(bound, disc);
            for (self.nets.items) |*n| {
                if (n.name == bound) n.discipline = disc;
            }
            return;
        }
        try self.port_resolved.put(self.ctx.arena, bound, {});
        try self.addNet(.{
            .name = bound,
            .discipline = disc,
            // The DECLARATION's token, not the connection's: if this discipline
            // turns out to be wrong for the net, the source the reader has to fix
            // is the one that named it.
            .main_tok = p.main_tok,
        });
    }

    /// Annex F.2.1 step 4 (its 4.a/4.b are printed verbatim in F.2.2 step 4;
    /// F.2.2's own step 5 re-runs the same bullets top-down and is not a
    /// separate implementation here, because a flattened signal has one node
    /// and both traversals see the same segment set). Runs ONCE, after the
    /// walk, over every net that got its discipline from a bound port rather
    /// than a declaration — F.2's "net ... which still has not been assigned a
    /// discipline" — and acts only where the walk's first-wins answer was not
    /// already 4.b's: more than one distinct candidate in the net's domain.
    ///
    ///  4.a  domain: "Any net whose child nets are all digital shall be
    ///       considered digital (discrete domain), any others shall be
    ///       considered analog (continuous domain)." The clause's other
    ///       sentence — a net "used in digital behavioral code" is digital —
    ///       has no input in VerA: §7.2.2 discrete blocks are recorded and
    ///       never executed, so no net is used in one. §7.4.4.1's basic mode
    ///       says the same thing as a precedence ("continuous winning over
    ///       discrete"), which is why the walk's upgrade path and this
    ///       classification cannot disagree.
    ///  4.b  candidates: the DISTINCT segment disciplines whose domain matches
    ///       the net's. Zero or one → the walk already answered (bullet 2, or
    ///       bullet 1's `default_discipline which lowering applies from the
    ///       net's own declaration side). More than one → bullet 3: a §7.7.2
    ///       resolution statement whose list matches the set resolves the net
    ///       (`resolveto exclude` refuses it instead, E0917); no statement →
    ///       bullet 4: UNKNOWN, "legal provided the net has no mixed-port
    ///       connections (i.e., it does not connect through a port to a
    ///       segment of a different domain). Otherwise this is an error" —
    ///       E0903.
    ///
    /// A legally-unknown net KEEPS the walk's first arrival. F.2 leaves an
    /// unknown discipline unknown; VerA's downstream needs a spelling for the
    /// net's access functions, the candidates are §3.11-compatible or lowering
    /// will say otherwise, and the first arrival is the answer this pass's
    /// absence always gave — so unknown-and-legal is exactly the old behaviour,
    /// stated instead of implied.
    ///
    /// ponytail: set equality is the whole matching rule, per F.2.1 4.b's "the
    /// contents of the list match the discipline list of a resolution connect
    /// statement". §7.7.2.1's tie-break (two exact matches → warn, take the
    /// first) is first-match without the warning, and its SUBSET fallback
    /// ("when there is no exact fit ... based on the subset of the rules
    /// specified") is not implemented — add it in `matchResolution` if a
    /// design ever needs partial matches, the annex arm itself only states
    /// exact matching.
    fn resolveMultiCandidates(self: *Flatten) Error!void {
        var it = self.segs.iterator();
        while (it.next()) |entry| {
            const net = entry.key_ptr.*;
            // A net the source declared was decided by §3.10 precedence
            // (steps 2/3); step 4 is only for undeclared interconnect.
            if (!self.port_resolved.contains(net)) continue;
            const discs = entry.value_ptr.discs.items;

            // 4.a — all children digital → discrete, any others → continuous.
            var net_continuous = false;
            for (discs) |d| {
                if (self.isContinuous(d)) net_continuous = true;
            }

            // 4.b's list: distinct matching-domain candidates, arrival order;
            // and the fourth bullet's predicate on the way — a segment of the
            // other domain IS a mixed-port connection, since every entry in
            // `segs` arrived through a port's lower connection.
            var cands: std.ArrayList(Ast.StrId) = .empty;
            var mixed_port = false;
            for (discs) |d| {
                if (self.isContinuous(d) != net_continuous) {
                    mixed_port = true;
                    continue;
                }
                // ponytail: linear membership for short lists; use a set if this scan dominates.
                if (std.mem.indexOfScalar(Ast.StrId, cands.items, d) == null)
                    try cands.append(self.ctx.arena, d);
            }
            if (cands.items.len <= 1) continue; // the walk's answer stands

            if (self.matchResolution(cands.items)) |r| {
                if (r.exclude) {
                    // §7.7.2: "deemed to be incompatible and an error is
                    // indicated if they are found on the same net."
                    try self.err(entry.value_ptr.tok, .E0917, "the disciplines of `{s}` match `connect ... resolveto exclude`", .{
                        self.ctx.file.str(net),
                    });
                    continue;
                }
                // Bullet 3: "the net is of the resolved discipline given by
                // the statement" — which "need not be one of the disciplines
                // specified in the discipline list" (§7.7.2.1). Same two
                // writes as §7.4.4.1's upgrade above.
                self.disc_of.putAssumeCapacity(net, r.resolved);
                for (self.nets.items) |*n| {
                    if (n.name == net) n.discipline = r.resolved;
                }
                continue;
            }

            // Bullet 4. Unknown-and-legal keeps the first arrival (doc above);
            // unknown with a segment of the other domain is the error.
            if (mixed_port) try self.err(
                entry.value_ptr.tok,
                .E0903,
                "`{s}` has candidate disciplines {{`{s}`, `{s}`{s}}} and no matching `resolveto`",
                .{
                    self.ctx.file.str(net),
                    self.ctx.file.str(cands.items[0]),
                    self.ctx.file.str(cands.items[1]),
                    if (cands.items.len > 2) ", ..." else "",
                },
            );
        }
    }

    /// §7.7.2 the first resolution statement whose discipline list matches
    /// `cands` as a SET (order-free, duplicate-free on both sides — 4.b's
    /// "the contents of the list match"). First match across every
    /// `connectrules` block in source order, which is §7.7.2.1's tie-break.
    fn matchResolution(self: *Flatten, cands: []const Ast.StrId) ?*const Ast.ConnectResolution {
        // ponytail: stdlib membership keeps exact-set matching; index sets if lists grow large.
        for (self.ctx.file.connectrules) |*cr| {
            rule: for (cr.resolutions) |*r| {
                for (r.disciplines) |d| {
                    if (std.mem.indexOfScalar(Ast.StrId, cands, d) == null) continue :rule;
                }
                for (cands) |c| {
                    if (std.mem.indexOfScalar(Ast.StrId, r.disciplines, c) == null) continue :rule;
                }
                return r;
            }
        }
        return null;
    }

    /// §7.7 the names a `connectrules` block spends, judged once per
    /// compilation (before the tree-of-one shortcut — see `elaborate`).
    /// A.1.2 puts no order on descriptions, so this is elaboration's and not
    /// the parser's: the connect module or discipline may be declared after
    /// the block.
    fn checkConnectRules(self: *Flatten) Error!void {
        for (self.ctx.file.connectrules) |cr| {
            for (cr.insertions) |ins| {
                // §7.7.1 "connect connectmodule_identifier": the name must be
                // a §7.6 connect module — an ordinary module bridges nothing
                // (E0913 is the same fact from the instantiation side).
                const m = self.findModule(ins.module) orelse {
                    try self.err(ins.main_tok, .E0915, "nothing declares `{s}`", .{self.ctx.file.str(ins.module)});
                    continue;
                };
                if (!m.is_connect) try self.err(ins.main_tok, .E0915, "`{s}` is not declared with `connectmodule`", .{
                    self.ctx.file.str(ins.module),
                });
                // ponytail: the §7.7.1 discipline/direction overrides and the
                // §7.7.3 parameter names are NOT judged against the connect
                // module's declarations — they configure the §7.8 insertion
                // phase VerA does not have, so a check would be validating
                // arguments to a call that is never made. Validate them
                // alongside the insertion phase, when there is one.
            }
            for (cr.resolutions) |r| {
                // §7.7.2 every identifier in a resolution statement is a
                // discipline_identifier; one that names no discipline can
                // never match a candidate list, and would silently turn a
                // resolving design into an E0903 one.
                for (r.disciplines) |d| if (!self.disciplineExists(d))
                    try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(d)});
                if (!r.exclude and !self.disciplineExists(r.resolved))
                    try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(r.resolved)});
            }
        }
    }

    /// Is `name` a declared discipline? Same linear scan as `isContinuous` and
    /// `primitiveAccess` — the discipline list is annex D's ~10 plus the
    /// user's few, and elaboration asks a handful of times.
    fn disciplineExists(self: *Flatten, name: Ast.StrId) bool {
        for (self.ctx.file.disciplines) |*d| {
            if (d.name == name) return true;
        }
        return false;
    }

    // ---- names ------------------------------------------------------------

    /// `path ++ local`, interned, and recorded in the §6.7 path table.
    fn join(self: *Flatten, path: []const u8, local: Ast.StrId) Error!Ast.StrId {
        const s = try std.fmt.allocPrint(self.ctx.arena, "{s}{s}", .{ path, self.ctx.file.str(local) });
        const id = try self.ctx.file.intern(self.ctx.arena, s);
        try self.names.put(self.ctx.arena, s, s);
        return id;
    }

    fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) Error!void {
        // A port already bound to the parent's net keeps that binding: `inout p;
        // electrical p;` leaves a NetDecl behind for the same name, and rewriting
        // it here would disconnect the port.
        if (unit.rename.contains(local)) return;
        try unit.rename.put(self.ctx.arena, local, try self.join(path, local));
    }

    /// The flat spelling of a name in the unit being cloned. A name with no
    /// entry is not the unit's — a block-local, a function formal, or an
    /// undeclared net §3.6.5 makes implicit — and keeps its own spelling.
    fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId {
        return self.unit.rename.get(local) orelse local;
    }

    /// The net a port connection names. §6.2.2 allows an expression; VerA takes
    /// a scalar net reference, which is what a topology join can be expressed as
    /// without introducing a node and an equation for the expression's value.
    fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
        if (e == .none) return null;
        if (self.ctx.file.exprs.tag(e) != .ident) return null;
        return self.ctx.file.exprs.strOf(e);
    }

    /// E.3.3 name scoping: "in the resolution hierarchy of names during
    /// elaboration a module or paramset defined in the Verilog-AMS will always be
    /// selected in favor of a SPICE primitive, model, or subcircuit using exactly
    /// the same name". So the user's declarations first, the shipped Annex E
    /// prelude second — which is the whole of the rule, because the prelude is a
    /// prefix of `modules` (see `Ast.SourceFile.builtin_modules`).
    ///
    /// E.3.3's "may issue a warning stating that the Verilog-AMS module ... is
    /// used instead of the SPICE primitive" is declined: `may`, and a warning on
    /// every use of a common word like `resistor` is noise.
    ///
    /// THE THIRD ARM IS E.2.1's SECOND SENTENCE: "if no exact match is found, the
    /// mixed-case name shall match the same name defined within SPICE regardless
    /// of the case." Scoped to the netlist-derived tail of the prelude
    /// (`Ast.SourceFile.netlistModules`) and reached only after both exact passes
    /// fail, which is exactly what the clause says: the case-sensitive arm is
    /// "from within Verilog-AMS HDL, a mixed-case name matches the same name with
    /// an identical case", and E.3.3 adds that a differing-case match "does not
    /// interfere" with the SPICE object. Names arrive from the netlist already
    /// lower-cased (`spice_cards`), so one `eqlIgnoreCase` is the whole rule.
    ///
    /// A netlist `.MODEL resistor` and Table E.1's `resistor` are ordered
    /// primitive-first here, by the exact-match pass. Annex E does not say which
    /// wins — E.3.3 only orders a Verilog-AMS module against a SPICE object, not
    /// two SPICE objects — and no fixture pins it; primitive-first is chosen
    /// because Table E.1 is the part the LRM standardises.
    fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl {
        for (self.ctx.file.userModules()) |*m| if (m.name == name) return m;
        for (self.ctx.file.modules[0..self.ctx.file.builtin_modules]) |*m| {
            if (m.name == name) return m;
        }
        const want = self.ctx.file.str(name);
        for (self.ctx.file.netlistModules()) |*m| {
            if (std.ascii.eqlIgnoreCase(self.ctx.file.str(m.name), want)) return m;
        }
        return null;
    }

    /// Annex E — is `m` one of the shipped Table E.1 primitives? Identity, not
    /// name: a user module called `resistor` shadows the primitive (E.3.3, see
    /// `findModule`) and must NOT get E.3.2's treatment, because E.3.2.1 says the
    /// port_discipline machinery "shall only apply to analog primitives ... for
    /// other modules as well as the ports of all other modules it shall be
    /// ignored".
    ///
    /// Table E.1's own rows only: a module synthesized from a netlist `.MODEL`
    /// card is a wrapper AROUND a primitive, not a primitive, and its body is one
    /// instantiation with no access function of its own to substitute.
    fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool {
        for (self.ctx.file.tablePrimitives()) |*p| {
            if (p == m) return true;
        }
        return false;
    }

    /// E.3.2 the access function a shipped primitive's `V` or `I` means on the
    /// net its port was connected to.
    ///
    /// Table E.1's Behavior column is written in V and I for every row, including
    /// rows whose ports need not be electrical: E.3.2 exists precisely so a
    /// primitive can "be used in any design, including mixed disciplines", and
    /// E.3.2.1's own example is a `vcvs` whose output pair is electrical and whose
    /// control pair is `rotational_omega` — one instance, two natures, one
    /// equation `V(p,n) = gain*V(ps,ns)`. So the table's V is "the potential of
    /// this port pair" and its I is "the flow", and the concrete spelling is the
    /// access function (§3.6.1.4) of whatever discipline the port resolved to.
    ///
    /// The discipline itself is NOT read from the `port_discipline` attribute.
    /// E.3.2 orders the three sources — the attribute, "the resolution of the
    /// discipline", then electrical — and after the flatten a connected port IS
    /// the parent's net (Ruling E), so the resolution has already happened and its
    /// answer is that net's declared discipline. An attribute asking for a
    /// discipline the connected net does not have would be a §3.11 error either
    /// way, which is why every E.3.2.1 example declares the two together. The
    /// ceiling: an UNCONNECTED port of a primitive carrying the attribute keeps
    /// the prelude's `electrical`, since nothing resolved it and the attribute is
    /// the only remaining source.
    ///
    /// Applies to the prelude's bodies only (`Unit.primitive`). A user module's
    /// `V` is a request for V, and getting Theta instead would be a compiler
    /// rewriting the source.
    fn primitiveAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId) Ast.StrId {
        const which: Ast.PotentialOrFlow = blk: {
            const a_ = self.ctx.file.str(access);
            if (std.mem.eql(u8, a_, "V")) break :blk .potential;
            if (std.mem.eql(u8, a_, "I")) break :blk .flow;
            return access; // not one of the table's two spellings
        };
        const name = self.netRefName(net) orelse return access;
        const disc = self.disc_of.get(name) orelse .none;
        if (disc == .none) return access; // §3.6.5 implicit, or resolved later
        const d = for (self.ctx.file.disciplines) |*x| {
            if (x.name == disc) break x;
        } else return access;
        const nature = switch (which) {
            .potential => d.potential,
            .flow => d.flow,
        };
        if (nature == .none) return access;
        const v = self.ctx.file.natureAttrExpr(nature, "access") orelse return access;
        if (self.ctx.file.exprs.tag(v) != .ident) return access;
        return self.ctx.file.exprs.strOf(v);
    }

    /// §6.2.2 an instance array bound. Integer literals and the arithmetic over
    /// them, which is what a range is written as; a bound reading a parameter is
    /// E0909, because the parameter table does not exist until lowering.
    fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
        if (e == .none) return null;
        const x = &self.ctx.file.exprs;
        return switch (x.tag(e)) {
            .int_literal => x.intValue(e),
            .unary => blk: {
                const v = self.constInt(x.lhs(e)) orelse break :blk null;
                break :blk switch (x.unOp(e)) {
                    .plus => v,
                    .minus => -v,
                    else => null,
                };
            },
            .binary => blk: {
                const l = self.constInt(x.lhs(e)) orelse break :blk null;
                const r = self.constInt(x.rhs(e)) orelse break :blk null;
                break :blk switch (x.binOp(e)) {
                    .add => l + r,
                    .sub => l - r,
                    .mul => l * r,
                    .div => if (r == 0) null else @divTrunc(l, r),
                    else => null,
                };
            },
            else => null,
        };
    }

    // ---- the clone --------------------------------------------------------

    /// §6.3: a flattened child's parameter is not the DEVICE's parameter.
    /// The device is the top module, and its model card is the top's
    /// parameter list; a child's value was fixed here, at elaboration, so
    /// exposing it as overridable would offer the host a knob that can no
    /// longer move anything.
    inline fn cloneParams(
        self: *Flatten,
        params: []const Ast.ParamDecl,
        aliases: []const Ast.AliasParam,
        over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
    ) Error!void {
        for (params) |p| {
            var out = p;
            out.name = self.flat(p.name);
            out.ranges = try self.cloneRanges(p.ranges);
            out.dims = try self.cloneDims(p.dims);
            if (over.get(p.name)) |v| {
                out.default = v; // already in the parent's flat namespace
                out.is_override = true;
            } else {
                out.default = try self.cloneExpr(p.default);
            }
            out.is_local = true;
            try self.params.append(self.ctx.arena, out);
        }
        for (aliases) |al| try self.aliasparams.append(self.ctx.arena, .{
            .alias = self.flat(al.alias),
            .target = self.flat(al.target),
        });
    }

    fn cloneDim(self: *Flatten, d: ?Ast.Dim) Error!?Ast.Dim {
        const dim = d orelse return null;
        return .{ .msb = try self.cloneExpr(dim.msb), .lsb = try self.cloneExpr(dim.lsb) };
    }

    fn cloneDims(self: *Flatten, dims: []const Ast.Dim) Error![]const Ast.Dim {
        if (dims.len == 0) return &.{};
        const out = try self.ctx.arena.alloc(Ast.Dim, dims.len);
        for (dims, out) |d, *o| o.* = (try self.cloneDim(d)).?;
        return out;
    }

    fn cloneRanges(self: *Flatten, rs: []const Ast.ValueRange) Error![]const Ast.ValueRange {
        if (rs.len == 0) return &.{};
        const out = try self.ctx.arena.alloc(Ast.ValueRange, rs.len);
        for (rs, out) |r, *o| {
            o.* = r;
            o.lo = try self.cloneExpr(r.lo);
            o.hi = try self.cloneExpr(r.hi);
        }
        return out;
    }

    fn cloneVar(self: *Flatten, v: Ast.VarDecl) Error!Ast.VarDecl {
        var out = v;
        out.name = self.flat(v.name);
        out.dims = try self.cloneDims(v.dims);
        out.init = try self.cloneExpr(v.init);
        return out;
    }

    /// §4.7.1 a user function. Its formals and locals are NOT in the unit's
    /// rename map — they are the function's own scope — so they are hidden for
    /// the duration of the body, or a formal sharing a module-level name would
    /// be rewritten to the module's.
    fn cloneFunc(self: *Flatten, fd: Ast.FuncDecl) Error!Ast.FuncDecl {
        var out = fd;
        out.name = self.flat(fd.name);
        var hidden: std.ArrayList(HiddenName) = .empty;
        for (fd.args) |arg| try self.hide(&hidden, arg.name);
        for (fd.params) |p| try self.hide(&hidden, p.name);
        for (fd.vars) |v| try self.hide(&hidden, v.name);
        out.params = try self.cloneLocalParams(fd.params);
        out.vars = try self.cloneLocalVars(fd.vars);
        out.body = try self.cloneStmt(fd.body);
        self.unhide(hidden.items);
        return out;
    }

    const HiddenName = struct { name: Ast.StrId, was: ?Ast.StrId };

    fn hide(self: *Flatten, list: *std.ArrayList(HiddenName), name: Ast.StrId) Error!void {
        try list.append(self.ctx.arena, .{ .name = name, .was = self.unit.rename.get(name) });
        _ = self.unit.rename.remove(name);
    }

    fn unhide(self: *Flatten, list: []const HiddenName) void {
        // Reverse, so a name hidden twice (a formal and a body local) comes back
        // to the outermost saved binding.
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (list[i].was) |w| {
                self.unit.rename.putAssumeCapacity(list[i].name, w);
            } else {
                _ = self.unit.rename.remove(list[i].name);
            }
        }
    }

    /// A block's or function's own declarations: cloned for their initializers
    /// and ranges, but NOT renamed — they are locals of a scope lowering already
    /// pushes and pops.
    fn cloneLocalParams(self: *Flatten, ps: []const Ast.ParamDecl) Error![]const Ast.ParamDecl {
        if (ps.len == 0) return &.{};
        const out = try self.ctx.arena.alloc(Ast.ParamDecl, ps.len);
        for (ps, out) |p, *o| {
            o.* = p;
            o.default = try self.cloneExpr(p.default);
            o.dims = try self.cloneDims(p.dims);
            o.ranges = try self.cloneRanges(p.ranges);
        }
        return out;
    }

    fn cloneLocalVars(self: *Flatten, vs: []const Ast.VarDecl) Error![]const Ast.VarDecl {
        if (vs.len == 0) return &.{};
        const out = try self.ctx.arena.alloc(Ast.VarDecl, vs.len);
        for (vs, out) |v, *o| {
            o.* = v;
            o.dims = try self.cloneDims(v.dims);
            o.init = try self.cloneExpr(v.init);
        }
        return out;
    }

    /// Copy one expression subtree into the store, renaming the names that
    /// belong to the unit being inlined. Every row is appended, never mutated:
    /// the child's own ids stay valid because a second instance of the same
    /// module clones the same source rows again, under its own map.
    fn cloneExpr(self: *Flatten, e: Ast.ExprId) Error!Ast.ExprId {
        if (e == .none) return .none;
        const x = &self.ctx.file.exprs;
        var n = x.get(e);
        switch (n.tag) {
            // Literals and the two infinities carry no reference; the side-table
            // index in `extra` is shared, which is safe because `reals`/`ints`
            // are append-only too.
            .int_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => {},
            .ident => n.str = self.flat(n.str),
            .hier_ident => {
                // §6.7 a dotted name. Only the FIRST part can be a local of this
                // unit — an instance of it, usually — and the rest are inside
                // whatever that names, so renaming part 0 is what turns `u.gain`
                // written inside a child into the flat `mid.u.gain`. §6.2.1's
                // "priority to the local scope" is exactly this rename; the
                // `$root` prefix that opts out of it is not a name of any unit, so
                // it passes through here and is stripped by `Lower.flatName`.
                const parts = x.nameParts(e);
                const out = try self.ctx.arena.alloc(Ast.StrId, parts.len);
                for (parts, out, 0..) |p, *o, i| o.* = if (i == 0) self.flat(p) else p;
                n.extra = try self.ctx.file.exprs.addStrList(self.ctx.arena, out);
            },
            .unary => n.lhs = try self.cloneExpr(x.lhs(e)),
            .binary, .index, .range, .event_or, .multi_concat => {
                n.lhs = try self.cloneExpr(x.lhs(e));
                n.rhs = try self.cloneExpr(x.rhs(e));
            },
            .ternary => {
                const third = x.ternaryElse(e);
                n.lhs = try self.cloneExpr(x.lhs(e));
                n.rhs = try self.cloneExpr(x.rhs(e));
                n.extra = @intFromEnum(try self.cloneExpr(third));
            },
            // A.6.5 `driver_update expression` sits with the digital edges: one
            // signal operand. Unreachable in practice — it only occurs in a
            // connect module, which is never instantiated (`pickTop`) and so
            // never cloned — but the shape is the shape.
            .event_posedge, .event_negedge, .event_driver_update => n.lhs = try self.cloneExpr(x.lhs(e)),
            .event_initial_step, .event_final_step => {}, // §5.10.2 analysis NAMES
            .branch_access, .port_access => {
                // §4.4 `str` is the ACCESS function (`V`, `I`), not a name in
                // this unit; the terminals are `lhs`/`rhs`.
                n.lhs = try self.cloneExpr(x.lhs(e));
                n.rhs = try self.cloneExpr(x.rhs(e));
                if (self.unit.primitive) n.str = self.primitiveAccess(n.str, n.lhs);
            },
            .call => {
                // §4.7 a user function was renamed with the declarations.
                n.str = self.flat(n.str);
                n.extra = try self.cloneArgs(x.args(e));
            },
            .sys_call => {
                if (try self.rewriteSysCall(e)) |lit| return lit;
                if (self.in_paramset) if (try self.rewriteParamsetDist(e)) |out| return out;
                n.extra = try self.cloneArgs(x.args(e));
            },
            .builtin_call, .filter_call, .noise_call, .event_function, .concat, .assign_pattern => {
                n.extra = try self.cloneArgs(x.args(e));
            },
        }
        return self.ctx.file.exprs.add(self.ctx.arena, n);
    }

    inline fn cloneArgs(self: *Flatten, src: []const Ast.ExprId) Error!u32 {
        const out = try self.ctx.arena.alloc(Ast.ExprId, src.len);
        for (src, out) |s, *o| o.* = try self.cloneExpr(s);
        return self.ctx.file.exprs.addExprList(self.ctx.arena, out);
    }

    /// The three ch9 functions whose answer is a property of the INSTANTIATION
    /// and therefore known here, once, rather than at run time.
    ///
    /// §9.19 `$port_connected` and `$param_given` both ask "what did the
    /// instantiation say?", which is a compile-time fact about a flattened unit
    /// — and it has to be answered here, because after the flatten a connected
    /// port IS the parent's net and nothing downstream can tell it from one.
    /// §9.18 `$mfactor` is the running product `collectOverrides` built.
    fn rewriteSysCall(self: *Flatten, e: Ast.ExprId) Error!?Ast.ExprId {
        const x = &self.ctx.file.exprs;
        const name = x.strOf(e);
        const tok = x.mainTok(e);
        if (self.ctx.file.strings.eql(name, "$mfactor")) {
            if (self.unit.mfactor == .none) return null; // the top: Table 9-29's 1.0
            return self.unit.mfactor;
        }
        const is_pc = self.ctx.file.strings.eql(name, "$port_connected");
        const is_pg = self.ctx.file.strings.eql(name, "$param_given");
        if (!is_pc and !is_pg) return null;
        const args = x.args(e);
        if (args.len != 1 or args[0] == .none or x.tag(args[0]) != .ident) return null;
        const local = x.strOf(args[0]);
        const table = if (is_pc) &self.unit.connected else &self.unit.given;
        const answer = table.get(local) orelse return null;
        return try self.ctx.file.exprs.addInt(self.ctx.arena, tok, @intFromBool(answer));
    }

    /// §9.13.1/§9.13.2 a distribution call written INSIDE a §6.4 paramset body
    /// — the one scope whose calls may carry the optional trailing
    /// `type_string`, and a compile-time fact about the paramset, so it sits
    /// with `rewriteSysCall`'s other elaboration-time answers. Two jobs:
    ///
    ///   1. The `type_string`. Syntax 9-8/9-9 admit it and §9.13.2 fences it:
    ///      "The type_string provides support for Monte-Carlo analysis and
    ///      shall only be used in calls to a distribution function from within
    ///      a paramset." The grammar lists exactly two spellings —
    ///      `type_string ::= "global" | "instance"` — so anything else is an
    ///      error (E0816). Monte-Carlo trials are the HOST's loop ("one value
    ///      is generated for each Monte-Carlo trial"); VerA compiles one
    ///      trial, in which "global" and "instance" select the same single
    ///      draw — so a valid string is validated and DROPPED, leaving the
    ///      call behaving exactly as without it.
    ///   2. The value. A paramset statement computes a module parameter at
    ///      elaboration (§6.4), and §9.13.2 makes the draw a pure function of
    ///      its seed ("shall always return the same value given the same
    ///      seed") — so a call whose seed and parameters are literals is one
    ///      kernel evaluation performed NOW, with the very functions every
    ///      device embeds (`rng_kernels.zig`). The call becomes the literal it
    ///      draws, which is what lets the value ride the ordinary §6.3
    ///      override machinery into the model card.
    ///
    /// Returns null when the callee is not one of Table 9-10's names (or is
    /// `$random`, whose Syntax 9-8 production has no `type_string`). A call
    /// whose arguments do not fold is returned with the string stripped and
    /// left to lowering, which owns the remaining argument rules — in a
    /// parameter position that path still ends in E0363, the same verdict the
    /// call had without a `type_string`.
    ///
    /// ponytail: the fold takes a literal seed only. Syntax 9-9 also admits an
    /// integer parameter identifier, and a paramset's own parameters are fixed
    /// by the time this runs — folding through them needs the parameter values
    /// threaded in here; add when a model actually writes one.
    fn rewriteParamsetDist(self: *Flatten, e: Ast.ExprId) Error!?Ast.ExprId {
        const x = &self.ctx.file.exprs;
        const name = self.ctx.file.str(x.strOf(e));
        const d = Lower.distOf(name) orelse return null;
        if (std.mem.eql(u8, name, "$random")) return null;
        const tok = x.mainTok(e);
        const args = x.args(e);

        var eff = args;
        var stripped = false;
        var bad = false;
        if (eff.len > 0 and eff[eff.len - 1] != .none and x.tag(eff[eff.len - 1]) == .str_literal) {
            const last = eff[eff.len - 1];
            const ts = self.ctx.file.str(x.strOf(last));
            if (!std.mem.eql(u8, ts, "global") and !std.mem.eql(u8, ts, "instance")) {
                try self.err(x.mainTok(last), .E0816, "`{s}`'s `type_string` shall be \"global\" or \"instance\", got \"{s}\"", .{ name, ts });
                bad = true;
            }
            eff = eff[0 .. eff.len - 1];
            stripped = true;
        }

        // The fold: the seed plus §9.13.2's parameters, all literal, judged by
        // the same domain rules `lowerRandom` applies on the runtime path.
        fold: {
            if (bad or eff.len != @as(usize, d.nparam) + 1) break :fold;
            const seed = constIntLit(x, eff[0]) orelse break :fold;
            var p = [2]f64{ 0, 0 };
            for (eff[1..], 0..) |arg, i| {
                p[i] = self.constReal(arg) orelse break :fold;
                if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and p[i] <= 0) {
                    try self.err(x.mainTok(arg), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{ name, Lower.distParamName(d, i), p[i] });
                    bad = true;
                }
            }
            if (d.ordered and p[0] >= p[1]) {
                try self.err(x.mainTok(eff[1]), .E0816, "the start value shall be smaller than the end value, got {d} and {d}", .{ p[0], p[1] });
                bad = true;
            }
            if (bad) break :fold; // report; nothing sound to draw
            const v: f64 = if (std.mem.eql(u8, d.kernel, "$rng$rand"))
                rng.zRngRand(seed)
            else if (std.mem.eql(u8, d.kernel, "$rng$i_uniform"))
                rng.zRngIUniform(seed, p[0], p[1])
            else if (std.mem.eql(u8, d.kernel, "$rng$uniform"))
                rng.zRngUniform(seed, p[0], p[1])
            else if (std.mem.eql(u8, d.kernel, "$rng$normal"))
                rng.zRngNormal(seed, p[0], p[1])
            else if (std.mem.eql(u8, d.kernel, "$rng$exponential"))
                rng.zRngExponential(seed, p[0])
            else if (std.mem.eql(u8, d.kernel, "$rng$poisson"))
                rng.zRngPoisson(seed, p[0])
            else if (std.mem.eql(u8, d.kernel, "$rng$chi_square"))
                rng.zRngChiSquare(seed, p[0])
            else if (std.mem.eql(u8, d.kernel, "$rng$t"))
                rng.zRngT(seed, p[0])
            else if (std.mem.eql(u8, d.kernel, "$rng$erlang"))
                rng.zRngErlang(seed, p[0], p[1])
            else
                break :fold;
            // §9.13.2 "$dist_ ... return integer values" — §4.2.1.1's rounding,
            // the same conversion the runtime path's `toInt` performs.
            return if (d.ty == .integer)
                try x.addInt(self.ctx.arena, tok, @intFromFloat(@round(v)))
            else
                try x.addReal(self.ctx.arena, tok, v);
        }

        if (!stripped) return null; // the ordinary clone will do
        // Unfoldable, but a `type_string` shall not survive to lowering, where
        // it would read as the out-of-paramset scope error: rebuild the call
        // over the remaining arguments, cloned as `cloneArgs` would have.
        var n = x.get(e);
        n.extra = try self.cloneArgs(eff);
        return try self.ctx.file.exprs.add(self.ctx.arena, n);
    }

    /// §9.13.1 Syntax 9-8's literal seed form, `[ sign ] decimal_number`. A
    /// real is deliberately NOT one — "the seed argument shall be an integer"
    /// is lowering's E0816 to report, so a real seed just declines the fold.
    fn constIntLit(x: *const Ast.ExprStore, e: Ast.ExprId) ?i64 {
        if (e == .none) return null;
        return switch (x.tag(e)) {
            .int_literal => x.intValue(e),
            .unary => switch (x.unOp(e)) {
                .plus => constIntLit(x, x.lhs(e)),
                .minus => if (constIntLit(x, x.lhs(e))) |v| -v else null,
                else => null,
            },
            else => null,
        };
    }

    /// Copy one statement (and everything under it) into the pool.
    fn cloneStmt(self: *Flatten, id: Ast.StmtId) Error!Ast.StmtId {
        if (id == .none) return .none;
        const file = self.ctx.file;
        const tok = file.stmtTok(id);
        const s = file.stmt(id);
        const out: Ast.Stmt = switch (s) {
            .empty => .empty,
            .block => |b| blk: {
                // §5.3.2 a named block's declarations are LOCALS. Hidden for the
                // body, for the same reason a function's formals are.
                var hidden: std.ArrayList(HiddenName) = .empty;
                for (b.params) |p| try self.hide(&hidden, p.name);
                for (b.vars) |v| try self.hide(&hidden, v.name);
                const params = try self.cloneLocalParams(b.params);
                const vars = try self.cloneLocalVars(b.vars);
                const body = try self.ctx.arena.alloc(Ast.StmtId, b.body.len);
                for (b.body, body) |src, *o| o.* = try self.cloneStmt(src);
                self.unhide(hidden.items);
                break :blk .{ .block = .{
                    // §6.7 a block label is a scope name. Renamed with the rest,
                    // so `disable` inside the child still finds it and two
                    // instances do not declare one name twice.
                    .name = if (b.name == .none) .none else try self.joinLocal(b.name),
                    .params = params,
                    .vars = vars,
                    .body = body,
                } };
            },
            .assign => |v| .{ .assign = .{
                .target = try self.cloneExpr(v.target),
                .value = try self.cloneExpr(v.value),
            } },
            .contribute => |v| .{ .contribute = .{
                .lhs = try self.cloneExpr(v.lhs),
                .rhs = try self.cloneExpr(v.rhs),
            } },
            .indirect => |v| .{ .indirect = .{
                .lhs = try self.cloneExpr(v.lhs),
                .probe = try self.cloneExpr(v.probe),
                .eqn = try self.cloneExpr(v.eqn),
            } },
            .if_stmt => |v| .{ .if_stmt = .{
                .cond = try self.cloneExpr(v.cond),
                .then_s = try self.cloneStmt(v.then_s),
                .else_s = try self.cloneStmt(v.else_s),
                .is_generate = v.is_generate,
            } },
            .case_stmt => |v| blk: {
                const arms = try self.ctx.arena.alloc(Ast.CaseArm, v.arms.len);
                for (v.arms, arms) |src, *o| {
                    const labels = try self.ctx.arena.alloc(Ast.ExprId, src.labels.len);
                    for (src.labels, labels) |l, *ol| ol.* = try self.cloneExpr(l);
                    o.* = .{ .labels = labels, .body = try self.cloneStmt(src.body) };
                }
                break :blk .{ .case_stmt = .{
                    .kind = v.kind,
                    .scrutinee = try self.cloneExpr(v.scrutinee),
                    .arms = arms,
                    .is_generate = v.is_generate,
                } };
            },
            .for_stmt => |v| .{ .for_stmt = .{
                .init = try self.cloneStmt(v.init),
                .cond = try self.cloneExpr(v.cond),
                .step = try self.cloneStmt(v.step),
                .body = try self.cloneStmt(v.body),
            } },
            .while_stmt => |v| .{ .while_stmt = .{
                .cond = try self.cloneExpr(v.cond),
                .body = try self.cloneStmt(v.body),
            } },
            .repeat_stmt => |v| .{ .repeat_stmt = .{
                .count = try self.cloneExpr(v.count),
                .body = try self.cloneStmt(v.body),
            } },
            .event_control => |v| .{ .event_control = .{
                .event = try self.cloneExpr(v.event),
                .body = try self.cloneStmt(v.body),
            } },
            .event_trigger => |v| .{ .event_trigger = .{ .name = self.flat(v.name) } },
            .disable => |v| .{ .disable = .{ .name = self.flat(v.name) } },
            .sys_task => |v| blk: {
                // `name` is `$strobe`/`$discontinuity`/… — never a name of this
                // unit.
                const args = try self.ctx.arena.alloc(Ast.ExprId, v.args.len);
                for (v.args, args) |src, *o| o.* = try self.cloneExpr(src);
                break :blk .{ .sys_task = .{ .name = v.name, .args = args } };
            },
            .jump => |v| .{ .jump = .{ .kind = v.kind, .value = try self.cloneExpr(v.value) } },
        };
        return file.addStmt(self.ctx.arena, out, tok);
    }

    /// A name the unit declares but that `bind` never saw, because it is not a
    /// module-level declaration: a §5.3.2 block label. Joined against the unit's
    /// path on demand, which the rename map already carries for every other
    /// name of the unit.
    fn joinLocal(self: *Flatten, name: Ast.StrId) Error!Ast.StrId {
        if (self.unit.rename.get(name)) |flat_id| return flat_id;
        // Derive the path from any binding the unit has; a unit with no
        // declarations at all has nothing to collide with, so the label stands.
        var it = self.unit.rename.iterator();
        const sample = it.next() orelse return name;
        const s = self.ctx.file.str(sample.value_ptr.*);
        const cut = std.mem.lastIndexOfScalar(u8, s, sep) orelse return name;
        return self.join(s[0 .. cut + 1], name);
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

/// Annex E — the prelude is only a prefix of `modules` if the PREPROCESSOR ran,
/// so this is the one fixture that goes through it. `builtin_modules` is set the
/// way every non-test caller sets it (see `root.zig` stage 3); getting that wiring
/// wrong makes a Table E.1 primitive the top of every design, which is exactly
/// what this test would catch.
fn parseWithPrelude(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.bag = diag.Bag.init(arena);
    out.src = try Preprocessor.process(arena, text, .{ .bag = &out.bag });
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

test "a connect module is neither the top nor a child (§7.6)" {
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

    // And naming one in an instantiation is E0913 rather than a silent inline:
    // the flatten carries analog blocks and drops `discrete` ones, so inlining a
    // bridge would stamp its continuous half with its digital half missing.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\connectmodule bridge(a, d); inout a, d; electrical a, d; endmodule
        \\module top(p); inout p; electrical p; bridge u(p, p); analog I(p) <+ V(p); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0913, g.bag.at(0).code);
}
