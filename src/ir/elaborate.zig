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
//! one signal into one node IS F.2's parent/child relation.
//!
//! WHAT IS NOT HERE, and each is a fixture's `//! xfail` rather than a silent
//! gap: annex E's SPICE primitive definitions (nothing to look up, so an
//! instance naming one is E0904), F.2.1 step 4.b's `connect`/`resolveto` arm and
//! the mixed-port error over it (E0903 — it needs a design element VerA has no
//! parser for), and §6.5.7.1's vector-net distribution across an instance array
//! — a port connection has to be a scalar net reference.

const std = @import("std");
const Ast = @import("../frontend/ast.zig");
const Lexer = @import("../frontend/lexer.zig");
const diag = @import("../diag.zig");

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

    // The tree of one. Returned BY POINTER, so a module with no children is
    // handed to lowering as the parser built it — same ids, same order, same
    // slices. This is the whole regression argument for putting a pass in front
    // of lowering: the case that does not need it does not touch it.
    //
    // A `defparam` with no instance to override is NOT that case: §6.3.1's path
    // names a parameter "in any module instance throughout the design", so with
    // no instance it names nothing, and E0907 is owed. The flatten is where that
    // is noticed, so the shortcut is declined for it.
    if (top.instances.len == 0 and top.defparams.len == 0) return .{ .top = top };

    var f: Flatten = .{ .ctx = ctx };
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
    /// The device. Read for the one question that is about the ROOT rather than
    /// about the unit being inlined: which names are the terminals, since Annex
    /// F.2's top segments are the top's ports and a discipline resolved up the
    /// hierarchy lands on one of them.
    top: *const Ast.ModuleDecl = undefined,

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

    fn a(self: *Flatten) std.mem.Allocator {
        return self.ctx.arena;
    }
    fn ex(self: *Flatten) *Ast.ExprStore {
        return &self.ctx.file.exprs;
    }
    fn str(self: *Flatten, id: Ast.StrId) []const u8 {
        return self.ctx.file.str(id);
    }

    fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
        self.had_error = true;
        return self.ctx.bag.add(.lower, code, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), fmt, args);
    }

    fn run(self: *Flatten, top: *const Ast.ModuleDecl) Error!Design {
        self.top = top;
        // The top's own declarations go in unrenamed and uncloned: it IS the
        // flat namespace, so an identity rename would rewrite every expression
        // in the device for no change. `unit.rename` is empty here, and
        // `cloneStmt` short-circuits on an empty map only in the sense that it
        // still copies — see `needsClone`.
        try self.params.appendSlice(self.a(), top.params);
        try self.aliasparams.appendSlice(self.a(), top.aliasparams);
        try self.vars.appendSlice(self.a(), top.vars);
        try self.addNets(top.nets);
        try self.branches.appendSlice(self.a(), top.branches);
        try self.genvars.appendSlice(self.a(), top.genvars);
        try self.events.appendSlice(self.a(), top.events);
        try self.functions.appendSlice(self.a(), top.functions);
        try self.attrs.appendSlice(self.a(), top.attrs);

        var stack: std.ArrayList(Ast.StrId) = .empty;
        try stack.append(self.a(), top.name);
        try self.walkInstances(top, "", &stack, 0);

        // §5.2 analog blocks are CONCURRENT, so the order they land in carries no
        // meaning of its own — except through one rule that is stated in program
        // order: §5.4.2.2's flow read, where `I(b)` after a flow contribution to
        // `b` is the retained value and before one mints an unknown (lower.zig).
        // A child's equations are not statements of the parent's body, so a
        // parent reading the flow of a child's branch — E.3's Behavior column
        // read through §6.7.1, which is how Table E.1 is observable at all — must
        // see the child's contribution however the two blocks were written. The
        // top's own blocks therefore go in LAST, after every inlined child's.
        try self.analog.appendSlice(self.a(), top.analog);

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

        const out = try self.a().create(Ast.ModuleDecl);
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
            const key = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ path, self.str(dp.path) });
            try self.defparams.put(self.a(), key, .{
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
            if (!isOoc(self.str(n.name))) continue;
            const key = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ path, self.str(n.name) });
            if (self.ooc.get(key)) |first| {
                try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                    key, self.str(first.discipline),
                });
                continue;
            }
            try self.ooc.put(self.a(), key, n);
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
                        self.str(ps.?.target),
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
                    self.str(child.name),
                });
                continue;
            }
            for (stack.items) |on_stack| if (on_stack == child.name) {
                try self.err(inst.main_tok, .E0905, "`{s}` is already being elaborated at `{s}{s}`", .{
                    self.str(child.name), path, self.str(inst.name),
                });
                return;
            };
            if (depth >= max_depth) {
                try self.err(inst.main_tok, .E0905, "the instance tree is more than {d} levels deep at `{s}{s}`", .{
                    max_depth, path, self.str(inst.name),
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
                    try self.err(inst.main_tok, .E0909, "`{s}`", .{self.str(inst.name)});
                    continue;
                };
                const lsb = self.constInt(r.lsb) orelse {
                    try self.err(inst.main_tok, .E0909, "`{s}`", .{self.str(inst.name)});
                    continue;
                };
                lo = @min(msb, lsb);
                hi = @max(msb, lsb);
                is_array = true;
            }

            var k = lo;
            while (k <= hi) : (k += 1) {
                const leaf = if (is_array)
                    try std.fmt.allocPrint(self.a(), "{s}[{d}]", .{ self.str(inst.name), k })
                else
                    self.str(inst.name);
                const child_path = try std.fmt.allocPrint(self.a(), "{s}{s}{c}", .{ path, leaf, sep });
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
            const conn = self.connectionFor(inst, child, p, i);
            try unit.connected.put(self.a(), p.name, conn != null and conn.?.expr != .none);
            const actual: ?Ast.StrId = if (conn) |c| self.netRefName(c.expr) else null;
            if (actual) |n| {
                // The port IS the parent's net. No new node, no new
                // declaration: that identity is what makes the flatten a
                // topology join rather than a copy.
                const bound = self.renameOf(&parent, n);
                try unit.rename.put(self.a(), p.name, bound);
                // §6.7.1 the port still HAS a hierarchical name, and probing it
                // is legal — so the path has to resolve to the net it was joined
                // to. This is the entry that makes `Design.names` more than an
                // identity map.
                try self.names.put(
                    self.a(),
                    try std.fmt.allocPrint(self.a(), "{s}{s}", .{ path, self.str(p.name) }),
                    self.str(bound),
                );
                try self.resolveDiscipline(path, p, bound);
            } else {
                // §6.2.2 "a blank port connection shall represent the situation
                // where the port is not to be connected", and an omitted named
                // port is the same thing. Unconnected still needs a node — the
                // child's equations reference it — so it becomes an internal net
                // of the device, carrying the port's own discipline.
                const internal = try self.join(path, p.name);
                try unit.rename.put(self.a(), p.name, internal);
                try self.nets.append(self.a(), .{
                    .name = internal,
                    // §3.10 order 1 still beats the local declaration on a port
                    // nobody connected: the segment exists, it is just the only
                    // segment of its signal.
                    .discipline = self.oocDiscipline(path, p.name) orelse p.discipline,
                    .main_tok = p.main_tok,
                });
            }
            if (conn) |c| if (c.expr != .none and self.netRefName(c.expr) == null)
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
        for (child.params) |p| {
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
            // §6.3: a flattened child's parameter is not the DEVICE's parameter.
            // The device is the top module, and its model card is the top's
            // parameter list; a child's value was fixed here, at elaboration, so
            // exposing it as overridable would offer the host a knob that can no
            // longer move anything.
            out.is_local = true;
            try self.params.append(self.a(), out);
        }
        for (child.aliasparams) |al| try self.aliasparams.append(self.a(), .{
            .alias = self.flat(al.alias),
            .target = self.flat(al.target),
        });
        for (child.nets) |n| {
            // Annex F.2.1 step 3: a dotted declaration is an out-of-context one,
            // already collected by `walkInstances`. It declares no net HERE.
            if (isOoc(self.str(n.name))) continue;
            var out = n;
            out.name = self.flat(n.name);
            out.range = try self.cloneDim(n.range);
            out.init = try self.cloneExpr(n.init);
            try self.nets.append(self.a(), out);
        }
        for (child.vars) |v| try self.vars.append(self.a(), try self.cloneVar(v));
        for (child.branches) |b| {
            var out = b;
            out.name = self.flat(b.name);
            out.hi = try self.cloneExpr(b.hi);
            out.lo = try self.cloneExpr(b.lo);
            out.range = try self.cloneDim(b.range);
            try self.branches.append(self.a(), out);
        }
        for (child.genvars) |g| try self.genvars.append(self.a(), self.flat(g));
        for (child.events) |e| try self.events.append(self.a(), self.flat(e));
        for (child.functions) |fd| try self.functions.append(self.a(), try self.cloneFunc(fd));
        for (child.attrs) |at| try self.attrs.append(self.a(), .{
            .name = at.name,
            .value = try self.cloneExpr(at.value),
            .main_tok = at.main_tok,
        });
        for (child.analog) |blk| try self.analog.append(self.a(), .{
            .is_initial = blk.is_initial,
            .body = try self.cloneStmt(blk.body),
            .main_tok = blk.main_tok,
        });

        // ---- recurse, with this unit's map in force ------------------------
        try stack.append(self.a(), child.name);
        try self.walkInstances(child, path, stack, depth + 1);
        _ = stack.pop();

        self.unit = parent;
    }

    /// §6.2.2 which connection binds `port` (the i'th declared port), or null
    /// for "not in the list at all".
    fn connectionFor(
        self: *Flatten,
        inst: *const Ast.Instance,
        child: *const Ast.ModuleDecl,
        port: Ast.Port,
        i: usize,
    ) ?Ast.PortConn {
        _ = child;
        _ = self;
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) return if (i < inst.ports.len) inst.ports[i] else null;
        for (inst.ports) |c| if (c.name == port.name) return c;
        return null;
    }

    /// The two ways a connection list can be malformed: longer than the port
    /// list, or naming a port that does not exist. §6.2.2 permits it to be
    /// SHORTER — that is the omitted-port spelling of "not to be connected".
    fn checkConnectionShape(self: *Flatten, inst: *const Ast.Instance, child: *const Ast.ModuleDecl) Error!void {
        const named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (!named) {
            if (inst.ports.len > child.ports.len) try self.err(
                inst.ports[child.ports.len].main_tok,
                .E0906,
                "`{s}` declares {d} port{s}, and this instance connects {d}",
                .{ self.str(child.name), child.ports.len, if (child.ports.len == 1) "" else "s", inst.ports.len },
            );
            return;
        }
        for (inst.ports) |c| {
            if (c.name == .none) {
                try self.err(c.main_tok, .E0906, "an ordered connection in a list of named connections", .{});
                continue;
            }
            const found = for (child.ports) |p| {
                if (p.name == c.name) break true;
            } else false;
            if (!found) try self.err(c.main_tok, .E0906, "`{s}` is not a port of `{s}`", .{
                self.str(c.name), self.str(child.name),
            });
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
        for (inst.params, 0..) |o, i| {
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
                if (i >= child.params.len) {
                    try self.err(o.main_tok, .E0907, "`{s}` declares {d} parameter{s}, and this instance overrides {d}", .{
                        self.str(child.name), child.params.len,
                        if (child.params.len == 1) "" else "s", inst.params.len,
                    });
                    continue;
                }
                try over.put(self.a(), child.params[i].name, value);
                continue;
            }
            if (self.ctx.file.strings.eql(o.name, "$mfactor")) {
                mfactor = if (mfactor == .none)
                    value
                else
                    try self.ex().add(self.a(), .{
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
                    self.str(o.name), self.str(child.name),
                });
                continue;
            };
            // §3.4.5 a localparam is not overridable.
            if (decl.is_local) {
                try self.err(o.main_tok, .E0907, "`{s}` is a localparam of `{s}`", .{
                    self.str(o.name), self.str(child.name),
                });
                continue;
            }
            // §3.4.7: "It shall be an error to specify a value for both the
            // original parameter and its alias in the same module instantiation".
            if (over.contains(target)) {
                try self.err(o.main_tok, .E0908, "`{s}` and its alias are both given a value", .{self.str(target)});
                continue;
            }
            try over.put(self.a(), target, value);
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
            const key = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ path, self.str(p.name) });
            const dp = self.defparams.getPtr(key) orelse continue;
            dp.used = true;
            try over.put(self.a(), p.name, dp.value);
        }

        // §9.19 `$param_given` — decided here, once, for every parameter of the
        // child. It is a question about the INSTANTIATION, so it has one answer
        // per flattened parameter and the clone can substitute a literal.
        for (child.params) |p| try unit.given.put(self.a(), p.name, over.contains(p.name));
        for (child.aliasparams) |al| if (over.contains(al.target))
            try unit.given.put(self.a(), al.alias, true);
    }

    // ---- §6.4 paramsets ---------------------------------------------------

    /// §6.4.2 which paramset of an overload set this instance uses.
    ///
    /// "Paramset identifiers need not be unique: multiple paramsets can be
    /// declared using the same paramset_identifier ... During elaboration, the
    /// simulator shall choose an appropriate paramset from the set that shares a
    /// given name for every instance that references that name."
    ///
    /// Two of the clause's criteria are applied, and they are the two that are
    /// decidable from the instantiation alone:
    ///
    ///   - every parameter the instance overrides is a parameter of the paramset
    ///     (an override the paramset has no home for cannot be honoured);
    ///   - "the parameters of the paramset, with overrides and defaults, shall be
    ///     all within the allowed ranges specified in the paramset parameter
    ///     declaration" — which is what makes a BINNED set (§6.4.2's short- and
    ///     long-channel pair, annex E's `spice_binning`) select on geometry.
    ///
    /// ponytail: first survivor wins, and the ceiling is the rest of §6.4.2's
    /// tie-breaking (the largest-number-of-parameters rule and the
    /// implementation-defined remainder). A tie is not diagnosed, because the
    /// clause does not make one an error; a set where NOTHING survives is E0911,
    /// because that instance has no paramset and the LRM's own binning examples
    /// rely on exactly one surviving.
    fn selectParamset(self: *Flatten, inst: *const Ast.Instance) Error!?*const Ast.ParamsetDecl {
        var candidates: usize = 0;
        for (self.ctx.file.paramsets) |*ps| {
            if (ps.name != inst.module) continue;
            candidates += 1;
            if (self.paramsetAdmits(inst, ps)) return ps;
        }
        if (candidates == 0) {
            try self.err(inst.main_tok, .E0904, "`{s}`", .{self.str(inst.module)});
        } else {
            try self.err(inst.main_tok, .E0911, "`{s}`: no paramset named `{s}` admits these parameter values", .{
                self.str(inst.name), self.str(inst.module),
            });
        }
        return null;
    }

    fn paramsetAdmits(self: *Flatten, inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl) bool {
        const named = inst.params.len != 0 and inst.params[0].name != .none;
        if (!named and inst.params.len > ps.params.len) return false;
        for (ps.params, 0..) |p, i| {
            // §6.4.2 "with overrides and defaults": the value this paramset would
            // give the parameter, whichever supplied it.
            var value = p.default;
            if (named) {
                for (inst.params) |o| {
                    if (o.name == p.name) value = o.value;
                }
            } else if (i < inst.params.len) {
                value = inst.params[i].value;
            }
            if (!self.inRanges(value, p.ranges)) return false;
        }
        if (!named) return true;
        for (inst.params) |o| {
            // §9.18's system parameters are not the paramset's to declare.
            if (self.ctx.file.strings.eql(o.name, "$mfactor")) continue;
            const found = for (ps.params) |p| {
                if (p.name == o.name) break true;
            } else for (ps.aliasparams) |al| {
                if (al.alias == o.name) break true;
            } else false;
            if (!found) return false;
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
        const x = self.ex();
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
        const ps_path = try std.fmt.allocPrint(self.a(), "{s}{s}{c}", .{ path, self.str(ps.name), sep });

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
        for (ps.params) |p| {
            var out = p;
            out.name = self.flat(p.name);
            out.ranges = try self.cloneRanges(p.ranges);
            out.dims = try self.cloneDims(p.dims);
            if (ps_over.get(p.name)) |v| {
                out.default = v; // cloned in the parent's namespace already
                out.is_override = true;
            } else {
                out.default = try self.cloneExpr(p.default);
            }
            out.is_local = true; // §6.3: the device's model card is the TOP's
            try self.params.append(self.a(), out);
        }
        for (ps.aliasparams) |al| try self.aliasparams.append(self.a(), .{
            .alias = self.flat(al.alias),
            .target = self.flat(al.target),
        });

        // ---- level 2: the module's parameters, from the paramset's statements
        for (ps.overrides) |o| {
            switch (o.kind) {
                .module_param => {
                    const decl = for (child.params) |*p| {
                        if (p.name == o.name) break p;
                    } else {
                        try self.err(o.main_tok, .E0907, "`{s}` is not a parameter of `{s}`", .{
                            self.str(o.name), self.str(child.name),
                        });
                        continue;
                    };
                    if (decl.is_local) {
                        try self.err(o.main_tok, .E0907, "`{s}` is a localparam of `{s}`", .{
                            self.str(o.name), self.str(child.name),
                        });
                        continue;
                    }
                    try over.put(self.a(), o.name, try self.cloneExpr(o.value));
                },
                // §9.18 `.$mfactor = expr;` in a paramset is the same override the
                // instance's `.$mfactor(expr)` is, so it multiplies the same way.
                .system_param => {
                    if (!self.ctx.file.strings.eql(o.name, "$mfactor")) {
                        try self.err(o.main_tok, .E0907, "`{s}` is not a system parameter this paramset can set", .{
                            self.str(o.name),
                        });
                        continue;
                    }
                    const v = try self.cloneExpr(o.value);
                    ps_unit.mfactor = if (ps_unit.mfactor == .none) v else try self.ex().add(self.a(), .{
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
        self.unit = saved;

        unit.mfactor = ps_unit.mfactor;
        // §9.19 as for a module instance: decided here, once, per parameter.
        for (child.params) |p| try unit.given.put(self.a(), p.name, over.contains(p.name));
        for (child.aliasparams) |al| if (over.contains(al.target))
            try unit.given.put(self.a(), al.alias, true);
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
            if (isOoc(self.str(n.name))) continue;
            try self.nets.append(self.a(), n);
        }
    }

    /// §3.10 precedence order 1: the out-of-context discipline for one segment,
    /// if a declaration named it.
    ///
    /// ponytail: consulted at PORT bindings only, which is where the LRM's own
    /// example lands (`electrical top.middle.bottom.sig;` names a port segment).
    /// A declaration naming a child's internal net is therefore read and ignored
    /// rather than applied — and that is also why an unmatched one is NOT
    /// diagnosed the way an unmatched `defparam` is: the two cases are
    /// indistinguishable from here, and reporting both would report a legal form.
    /// The upgrade is to consult it in the child-net loop too.
    fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, self.str(local) }) catch return null;
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
    /// ponytail: first declaration wins, and the ceiling is that TWO declared
    /// segments of one signal are not compared here. That is §3.11's Signal
    /// Connection Rule (compatible disciplines) and lowering already owns it
    /// (E0902 for one net, two declarations) — what does NOT exist is 4.b's
    /// resolveto/connectrules arm, which needs the `connect` design element VerA
    /// has none of. `annex_f_resolution/unknown_discipline_mixed_port.va` is the
    /// fixture that stays red on it.
    fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId) Error!void {
        const disc = self.oocDiscipline(path, p.name) orelse p.discipline;
        if (disc == .none) return;
        if (self.declaredDiscipline(bound) != .none) return;
        try self.nets.append(self.a(), .{
            .name = bound,
            .discipline = disc,
            // The DECLARATION's token, not the connection's: if this discipline
            // turns out to be wrong for the net, the source the reader has to fix
            // is the one that named it.
            .main_tok = p.main_tok,
        });
    }

    /// The discipline the flat net `name` already has, from the top's ports, the
    /// top's own declarations, or a segment resolved earlier in the walk.
    fn declaredDiscipline(self: *Flatten, name: Ast.StrId) Ast.StrId {
        for (self.top.ports) |p| if (p.name == name) {
            if (p.discipline != .none) return p.discipline;
        };
        for (self.nets.items) |n| if (n.name == name) {
            if (n.discipline != .none) return n.discipline;
        };
        return .none;
    }

    // ---- names ------------------------------------------------------------

    /// `path ++ local`, interned, and recorded in the §6.7 path table.
    fn join(self: *Flatten, path: []const u8, local: Ast.StrId) Error!Ast.StrId {
        const s = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ path, self.str(local) });
        const id = try self.ctx.file.intern(self.a(), s);
        try self.names.put(self.a(), s, s);
        return id;
    }

    fn bind(self: *Flatten, unit: *Unit, path: []const u8, local: Ast.StrId) Error!void {
        // A port already bound to the parent's net keeps that binding: `inout p;
        // electrical p;` leaves a NetDecl behind for the same name, and rewriting
        // it here would disconnect the port.
        if (unit.rename.contains(local)) return;
        try unit.rename.put(self.a(), local, try self.join(path, local));
    }

    /// The flat spelling of a name in the unit being cloned. A name with no
    /// entry is not the unit's — a block-local, a function formal, or an
    /// undeclared net §3.6.5 makes implicit — and keeps its own spelling.
    fn flat(self: *Flatten, local: Ast.StrId) Ast.StrId {
        return self.unit.rename.get(local) orelse local;
    }

    fn renameOf(self: *Flatten, unit: *const Unit, local: Ast.StrId) Ast.StrId {
        _ = self;
        return unit.rename.get(local) orelse local;
    }

    /// The net a port connection names. §6.2.2 allows an expression; VerA takes
    /// a scalar net reference, which is what a topology join can be expressed as
    /// without introducing a node and an equation for the expression's value.
    fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
        if (e == .none) return null;
        if (self.ex().tag(e) != .ident) return null;
        return self.ex().strOf(e);
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
        const want = self.str(name);
        for (self.ctx.file.netlistModules()) |*m| {
            if (std.ascii.eqlIgnoreCase(self.str(m.name), want)) return m;
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
            const a_ = self.str(access);
            if (std.mem.eql(u8, a_, "V")) break :blk .potential;
            if (std.mem.eql(u8, a_, "I")) break :blk .flow;
            return access; // not one of the table's two spellings
        };
        const name = self.netRefName(net) orelse return access;
        const disc = self.declaredDiscipline(name);
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
        if (self.ex().tag(v) != .ident) return access;
        return self.ex().strOf(v);
    }

    /// §6.2.2 an instance array bound. Integer literals and the arithmetic over
    /// them, which is what a range is written as; a bound reading a parameter is
    /// E0909, because the parameter table does not exist until lowering.
    fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
        if (e == .none) return null;
        const x = self.ex();
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

    fn cloneDim(self: *Flatten, d: ?Ast.Dim) Error!?Ast.Dim {
        const dim = d orelse return null;
        return .{ .msb = try self.cloneExpr(dim.msb), .lsb = try self.cloneExpr(dim.lsb) };
    }

    fn cloneDims(self: *Flatten, dims: []const Ast.Dim) Error![]const Ast.Dim {
        if (dims.len == 0) return &.{};
        const out = try self.a().alloc(Ast.Dim, dims.len);
        for (dims, out) |d, *o| o.* = (try self.cloneDim(d)).?;
        return out;
    }

    fn cloneRanges(self: *Flatten, rs: []const Ast.ValueRange) Error![]const Ast.ValueRange {
        if (rs.len == 0) return &.{};
        const out = try self.a().alloc(Ast.ValueRange, rs.len);
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
        try list.append(self.a(), .{ .name = name, .was = self.unit.rename.get(name) });
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
        const out = try self.a().alloc(Ast.ParamDecl, ps.len);
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
        const out = try self.a().alloc(Ast.VarDecl, vs.len);
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
        const x = self.ex();
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
                const out = try self.a().alloc(Ast.StrId, parts.len);
                for (parts, out, 0..) |p, *o, i| o.* = if (i == 0) self.flat(p) else p;
                n.extra = try self.ex().addStrList(self.a(), out);
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
                n.extra = try self.cloneArgs(e);
            },
            .sys_call => {
                if (try self.rewriteSysCall(e)) |lit| return lit;
                n.extra = try self.cloneArgs(e);
            },
            .builtin_call, .filter_call, .noise_call, .event_function, .concat, .assign_pattern => {
                n.extra = try self.cloneArgs(e);
            },
        }
        return self.ex().add(self.a(), n);
    }

    fn cloneArgs(self: *Flatten, e: Ast.ExprId) Error!u32 {
        const src = self.ex().args(e);
        const out = try self.a().alloc(Ast.ExprId, src.len);
        for (src, out) |s, *o| o.* = try self.cloneExpr(s);
        return self.ex().addExprList(self.a(), out);
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
        const x = self.ex();
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
        return try self.ex().addInt(self.a(), tok, @intFromBool(answer));
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
                const body = try self.a().alloc(Ast.StmtId, b.body.len);
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
                const arms = try self.a().alloc(Ast.CaseArm, v.arms.len);
                for (v.arms, arms) |src, *o| {
                    const labels = try self.a().alloc(Ast.ExprId, src.labels.len);
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
                const args = try self.a().alloc(Ast.ExprId, v.args.len);
                for (v.args, args) |src, *o| o.* = try self.cloneExpr(src);
                break :blk .{ .sys_task = .{ .name = v.name, .args = args } };
            },
            .jump => |v| .{ .jump = .{ .kind = v.kind, .value = try self.cloneExpr(v.value) } },
        };
        return file.addStmt(self.a(), out, tok);
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
        const s = self.str(sample.value_ptr.*);
        const cut = std.mem.lastIndexOfScalar(u8, s, sep) orelse return name;
        return self.join(s[0 .. cut + 1], name);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parser = @import("../frontend/parser.zig");
const Preprocessor = @import("../frontend/preprocessor.zig");

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
