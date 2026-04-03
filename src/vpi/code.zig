//! §11.6.3, §11.6.16–§11.6.24 — the BEHAVIOURAL objects: processes,
//! statements, continuous assignments, tasks and functions, named events and
//! the expressions they hold, materialized from the source AST into the one
//! fixed object array root.zig hands handles into (AST in -> `Obj` rows out).
//!
//! LRM clauses this code cites: §11.6.3 (scope, task, function, io decl),
//! §11.6.10 (named event), §11.6.16 (task and function call), §11.6.17
//! (continuous assignment), §11.6.18/§11.6.19 (simple and compound
//! expressions), §11.6.20 (contribs), §11.6.21 (process, block, statement,
//! event statement), §11.6.22 (assignment, delay/event/repeat control, while,
//! repeat, wait, for, forever), §11.6.23 (if, if-else, case), §11.6.24 (assign
//! statement, deassign, force, release, disable), §12.11 (the delays a
//! continuous assignment and a delay control carry).
//!
//! ONE CLASS FOR ALL OF THEM. Every object here is a root `Obj` of kind
//! `.code`, typed by `vtype` (the Annex G object number `vpi_get(vpiType)`
//! returns) and carrying its diagram's edges as DATA: `edges` are the single
//! arrows (tag -> object), `lists` the double arrows (tag -> objects),
//! `props` the int/bool properties. vpi_handle, vpi_iterate and vpi_get answer
//! a `.code` object by looking the tag up in those rows — so what a diagram
//! draws is exactly what the builder below wrote, and a tag it did not write
//! is "no such relationship" (an error), never a guess.
//!
//! An edge the diagram DRAWS but this object does not have — an if with no
//! else is a vpiIf and draws no vpiElseStmt at all, but an assignment with no
//! intra-assignment delay still draws vpiDelayControl — is written with
//! `none`: vpi_handle then answers NULL with no error (§11.5.3's "no object").
//!
//! Identifiers resolve to the objects the model already holds — a `bus` in an
//! expression IS the §11.6.8 net object (§11.6.18: "simple expr" is the class
//! of nets, regs, variables, parameters, memories and their selects).

const std = @import("std");
const Ast = @import("frontend").Ast;
const root = @import("root.zig");

const Obj = root.Obj;
pub const none = root.no_obj;

// Annex G object types (IEEE 1364-2005, which §12.2 and §12.31 defer to).
pub const vpiAlways: c_int = 1;
pub const vpiAssignStmt: c_int = 2;
pub const vpiAssignment: c_int = 3;
pub const vpiBegin: c_int = 4;
pub const vpiCase: c_int = 5;
pub const vpiCaseItem: c_int = 6;
pub const vpiContAssign: c_int = 8;
pub const vpiDeassign: c_int = 9;
pub const vpiDelayControl: c_int = 11;
pub const vpiDisable: c_int = 12;
pub const vpiEventControl: c_int = 13;
pub const vpiEventStmt: c_int = 14;
pub const vpiFor: c_int = 15;
pub const vpiForce: c_int = 16;
pub const vpiForever: c_int = 17;
pub const vpiFork: c_int = 18;
pub const vpiFuncCall: c_int = 19;
pub const vpiFunction: c_int = 20;
pub const vpiIf: c_int = 22;
pub const vpiIfElse: c_int = 23;
pub const vpiInitial: c_int = 24;
pub const vpiIODecl: c_int = 28;
pub const vpiNamedBegin: c_int = 33;
pub const vpiNamedEvent: c_int = 34;
pub const vpiNamedFork: c_int = 35;
pub const vpiNetBit: c_int = 37;
pub const vpiNullStmt: c_int = 38;
pub const vpiOperation: c_int = 39;
pub const vpiPartSelect: c_int = 42;
pub const vpiRegBit: c_int = 49;
pub const vpiRelease: c_int = 50;
pub const vpiRepeat: c_int = 51;
pub const vpiSysFuncCall: c_int = 56;
pub const vpiSysTaskCall: c_int = 57;
pub const vpiTask: c_int = 59;
pub const vpiTaskCall: c_int = 60;
pub const vpiWait: c_int = 69;
pub const vpiWhile: c_int = 70;
pub const vpiGate: c_int = 21;
pub const vpiPrimTerm: c_int = 46;
pub const vpiTableEntry: c_int = 58;
pub const vpiUdp: c_int = 65;
pub const vpiUdpDefn: c_int = 66;
pub const vpiPrimitive: c_int = 103;
pub const vpiPrimType: c_int = 33;
pub const vpiTermIndex: c_int = 30;
pub const vpiSeqPrim: c_int = 27;
pub const vpiCombPrim: c_int = 28;

// Annex G relationships.
pub const vpiCondition: c_int = 71;
pub const vpiDelay: c_int = 72;
pub const vpiElseStmt: c_int = 73;
pub const vpiForIncStmt: c_int = 74;
pub const vpiForInitStmt: c_int = 75;
pub const vpiLhs: c_int = 77;
pub const vpiIndex: c_int = 78;
pub const vpiLeftRange: c_int = 79;
pub const vpiParent: c_int = 81;
pub const vpiRhs: c_int = 82;
pub const vpiScope: c_int = 84;
pub const vpiArgument: c_int = 89;
pub const vpiOperand: c_int = 97;
pub const vpiProcess: c_int = 99;
pub const vpiExpr: c_int = 102;
pub const vpiStmt: c_int = 104;
pub const vpiRightRange: c_int = 83;

// Annex G properties.
pub const vpiOpType: c_int = 39;
pub const vpiBlocking: c_int = 41;
pub const vpiCaseType: c_int = 42;
pub const vpiDirection: c_int = 20;
pub const vpiSize: c_int = 4;

// vpiCaseType values.
pub const vpiCaseExact: c_int = 1;
pub const vpiCaseX: c_int = 2;
pub const vpiCaseZ: c_int = 3;

// vpiOpType values.
pub const vpiMinusOp: c_int = 1;
pub const vpiPlusOp: c_int = 2;
pub const vpiNotOp: c_int = 3;
pub const vpiBitNegOp: c_int = 4;
pub const vpiUnaryAndOp: c_int = 5;
pub const vpiUnaryNandOp: c_int = 6;
pub const vpiUnaryOrOp: c_int = 7;
pub const vpiUnaryNorOp: c_int = 8;
pub const vpiUnaryXorOp: c_int = 9;
pub const vpiUnaryXNorOp: c_int = 10;
pub const vpiSubOp: c_int = 11;
pub const vpiDivOp: c_int = 12;
pub const vpiModOp: c_int = 13;
pub const vpiEqOp: c_int = 14;
pub const vpiNeqOp: c_int = 15;
pub const vpiCaseEqOp: c_int = 16;
pub const vpiCaseNeqOp: c_int = 17;
pub const vpiGtOp: c_int = 18;
pub const vpiGeOp: c_int = 19;
pub const vpiLtOp: c_int = 20;
pub const vpiLeOp: c_int = 21;
pub const vpiLShiftOp: c_int = 22;
pub const vpiRShiftOp: c_int = 23;
pub const vpiAddOp: c_int = 24;
pub const vpiMultOp: c_int = 25;
pub const vpiLogAndOp: c_int = 26;
pub const vpiLogOrOp: c_int = 27;
pub const vpiBitAndOp: c_int = 28;
pub const vpiBitOrOp: c_int = 29;
pub const vpiBitXorOp: c_int = 30;
pub const vpiBitXNorOp: c_int = 31;
pub const vpiConditionOp: c_int = 32;
pub const vpiConcatOp: c_int = 33;
pub const vpiMultiConcatOp: c_int = 34;
pub const vpiEventOrOp: c_int = 35;
pub const vpiPosedgeOp: c_int = 39;
pub const vpiNegedgeOp: c_int = 40;
pub const vpiArithLShiftOp: c_int = 41;
pub const vpiArithRShiftOp: c_int = 42;
pub const vpiPowerOp: c_int = 43;

// Verilog-AMS names these and numbers none; VerA's numbers, beside the
// analog classes of root.zig.
/// §11.6.21's `analog` process.
pub const vpiAnalog: c_int = 733;
/// §11.6.20 a contribution statement; `vpiDirect`/`vpiFlow` tell the four
/// members of the class apart.
pub const vpiContrib: c_int = 734;
pub const vpiDirect: c_int = 735;
/// §11.6.19 `accessfunc`, an access function applied to a branch or nodes.
pub const vpiAccessFunc: c_int = 736;

pub const Edge = struct { tag: c_int, to: u32 };
pub const List = struct { tag: c_int, items: []const u32 };
pub const Prop = struct { prop: c_int, value: c_int };

/// The `vpi_get_str(vpiType)` spelling of every type this file makes.
pub fn typeName(t: c_int) ?[]const u8 {
    return switch (t) {
        vpiAlways => "vpiAlways",
        vpiAssignStmt => "vpiAssignStmt",
        vpiAssignment => "vpiAssignment",
        vpiBegin => "vpiBegin",
        vpiCase => "vpiCase",
        vpiCaseItem => "vpiCaseItem",
        vpiContAssign => "vpiContAssign",
        vpiDeassign => "vpiDeassign",
        vpiDelayControl => "vpiDelayControl",
        vpiDisable => "vpiDisable",
        vpiEventControl => "vpiEventControl",
        vpiEventStmt => "vpiEventStmt",
        vpiFor => "vpiFor",
        vpiForce => "vpiForce",
        vpiForever => "vpiForever",
        vpiFork => "vpiFork",
        vpiFuncCall => "vpiFuncCall",
        vpiFunction => "vpiFunction",
        vpiIf => "vpiIf",
        vpiIfElse => "vpiIfElse",
        vpiInitial => "vpiInitial",
        vpiIODecl => "vpiIODecl",
        vpiNamedBegin => "vpiNamedBegin",
        vpiNamedEvent => "vpiNamedEvent",
        vpiNamedFork => "vpiNamedFork",
        vpiNetBit => "vpiNetBit",
        vpiNullStmt => "vpiNullStmt",
        vpiOperation => "vpiOperation",
        vpiPartSelect => "vpiPartSelect",
        vpiRegBit => "vpiRegBit",
        vpiRelease => "vpiRelease",
        vpiRepeat => "vpiRepeat",
        vpiSysFuncCall => "vpiSysFuncCall",
        vpiSysTaskCall => "vpiSysTaskCall",
        vpiTask => "vpiTask",
        vpiTaskCall => "vpiTaskCall",
        vpiWait => "vpiWait",
        vpiGate => "vpiGate",
        vpiPrimTerm => "vpiPrimTerm",
        vpiTableEntry => "vpiTableEntry",
        vpiUdp => "vpiUdp",
        vpiUdpDefn => "vpiUdpDefn",
        vpiWhile => "vpiWhile",
        vpiAnalog => "vpiAnalog",
        vpiContrib => "vpiContrib",
        vpiAccessFunc => "vpiAccessFunc",
        else => null, // else: not a type this file makes; the caller answers
    };
}

/// The per-scope double arrows of §11.6.1 this file fills.
pub const ScopeLists = struct {
    cont_assigns: std.ArrayList(u32) = .empty,
    processes: std.ArrayList(u32) = .empty,
    tasks: std.ArrayList(u32) = .empty,
    functions: std.ArrayList(u32) = .empty,
    events: std.ArrayList(u32) = .empty,
    primitives: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *ScopeLists, gpa: std.mem.Allocator) void {
        s.cont_assigns.deinit(gpa);
        s.processes.deinit(gpa);
        s.tasks.deinit(gpa);
        s.functions.deinit(gpa);
        s.events.deinit(gpa);
        s.primitives.deinit(gpa);
    }

    /// Frozen as tagged rows, the shape `vpi_iterate(tag, module)` reads.
    pub fn freeze(s: *const ScopeLists, arena: std.mem.Allocator) ![]const List {
        return arena.dupe(List, &.{
            .{ .tag = vpiContAssign, .items = try arena.dupe(u32, s.cont_assigns.items) },
            .{ .tag = vpiProcess, .items = try arena.dupe(u32, s.processes.items) },
            .{ .tag = vpiTask, .items = try arena.dupe(u32, s.tasks.items) },
            .{ .tag = vpiFunction, .items = try arena.dupe(u32, s.functions.items) },
            .{ .tag = vpiNamedEvent, .items = try arena.dupe(u32, s.events.items) },
            .{ .tag = vpiPrimitive, .items = try arena.dupe(u32, s.primitives.items) },
        });
    }
};

pub const Error = root.Error;

/// One scope's worth of building: where new rows go, how a name in this
/// scope resolves, and the path new named objects hang under.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *std.ArrayList(Obj),
    file: *const Ast.SourceFile,
    /// §6.7 full name -> object index, for every object that has a name.
    /// Named objects this builder makes (events, tasks, named blocks) are
    /// added as they are made, so a later statement finds them.
    names: *std.StringHashMapUnmanaged(u32),
    top_name: []const u8,
    /// The scope being built, and its §6.7 path relative to the top.
    scope: u32,
    path: []const u8,
    lists: *ScopeLists,
    /// The analog model's discipline-by-name table and the branch objects,
    /// for §11.6.19's accessfunc and §11.6.20's contribution; empty for a
    /// digital scope.
    analog: ?*const Analog = null,
    /// §11.6.14 UDP definition name -> its `vpiUdpDefn` object.
    udps: ?*const std.AutoHashMapUnmanaged(Ast.StrId, u32) = null,

    pub const Analog = struct {
        /// Flat branch name -> branch object.
        branches: std.StringHashMapUnmanaged(u32) = .empty,
        /// Discipline object -> its flow access name, for telling a flow
        /// contribution from a potential one (§3.6.1.4).
        flow_access: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    };

    fn full(b: *Builder, local: []const u8) Error![]const u8 {
        const rel = if (b.path.len == 0) try b.arena.dupe(u8, local) else try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ b.path, local });
        return std.fmt.allocPrint(b.arena, "{s}.{s}", .{ b.top_name, rel });
    }

    fn add(b: *Builder, o: Obj) Error!u32 {
        const at: u32 = @intCast(b.objects.items.len);
        try b.objects.append(b.gpa, o);
        return at;
    }

    fn code(b: *Builder, vtype: c_int, edges: []const Edge, lists: []const List, props: []const Prop) Error!u32 {
        return b.add(.{
            .kind = .code,
            .owner = b.scope,
            .name = "",
            .full = "",
            .vtype = vtype,
            .edges = try b.arena.dupe(Edge, edges),
            .lists = try b.arena.dupe(List, lists),
            .props = try b.arena.dupe(Prop, props),
        });
    }

    /// Give object `at` the local name `local` and a full name under this
    /// scope, and make the full name resolvable.
    fn setName(b: *Builder, at: u32, local: []const u8) Error!void {
        const f = try b.full(local);
        b.objects.items[at].name = local;
        b.objects.items[at].full = f;
        try b.names.put(b.gpa, f, at);
    }

    fn many(b: *Builder, items: []const u32) Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        for (items) |i| if (i != none) try out.append(b.arena, i);
        return out.items;
    }

    // ---------------------------------------------------------------- module

    /// The behavioural contents of one digital module instance: its named
    /// events, tasks and functions, continuous assignments and processes.
    pub fn module(b: *Builder, m: *const Ast.ModuleDecl) Error!void {
        // §11.6.10's named event: scope <->> named event, named in the scope.
        for (m.events) |e| {
            const at = try b.add(.{ .kind = .code, .owner = b.scope, .name = "", .full = "", .vtype = vpiNamedEvent });
            try b.setName(at, try b.arena.dupe(u8, b.file.str(e)));
            try b.lists.events.append(b.gpa, at);
        }
        // §11.6.3 task and function, before any statement that calls one.
        for (m.tasks) |*t| {
            const at = try b.add(.{ .kind = .code, .owner = b.scope, .name = "", .full = "", .vtype = if (t.is_function) vpiFunction else vpiTask });
            try b.setName(at, try b.arena.dupe(u8, b.file.str(t.name)));
            try (if (t.is_function) &b.lists.functions else &b.lists.tasks).append(b.gpa, at);
        }
        for (m.tasks, 0..) |*t, k| {
            const at = (if (t.is_function) b.lists.functions.items else b.lists.tasks.items)[subIndex(m.tasks, k)];
            var ios: std.ArrayList(u32) = .empty;
            for (t.ports) |p| {
                const local = try b.arena.dupe(u8, b.file.str(p.v.name));
                try ios.append(b.arena, try b.add(.{
                    .kind = .code,
                    .owner = b.scope,
                    .name = local,
                    .full = "",
                    .vtype = vpiIODecl,
                    .props = try b.arena.dupe(Prop, &.{
                        .{ .prop = vpiDirection, .value = direction(p.direction) },
                        .{ .prop = vpiSize, .value = packedWidth(b.file, p.v) },
                    }),
                }));
            }
            const body = try b.stmt(t.body);
            b.objects.items[at].edges = try b.arena.dupe(Edge, &.{.{ .tag = vpiStmt, .to = body }});
            b.objects.items[at].lists = try b.arena.dupe(List, &.{.{ .tag = vpiIODecl, .items = ios.items }});
        }
        // §11.6.17.
        for (m.assigns) |a| {
            const lhs = try b.expr(a.target);
            const rhs = try b.expr(a.value);
            const delay = if (a.delay.any()) try b.expr(a.delay.rise) else none;
            const at = try b.code(vpiContAssign, &.{
                .{ .tag = vpiLhs, .to = lhs },
                .{ .tag = vpiRhs, .to = rhs },
                .{ .tag = vpiDelay, .to = delay },
            }, &.{}, &.{});
            b.objects.items[at].delays = try b.delays(a.delay);
            try b.lists.cont_assigns.append(b.gpa, at);
        }
        // §11.6.13 gates, in source order, then UDP instances.
        for (m.gates) |g| {
            var terms: std.ArrayList(Ast.ExprId) = .empty;
            try terms.append(b.arena, g.out);
            try terms.appendSlice(b.arena, g.ins);
            const at = try b.primitive(vpiGate, gateType(g.kind), gateName(g.kind), terms.items);
            const delay = if (g.delay.any()) try b.expr(g.delay.rise) else none;
            b.objects.items[at].delays = try b.delays(g.delay);
            b.objects.items[at].edges = try b.arena.dupe(Edge, &.{.{ .tag = vpiDelay, .to = delay }});
        }
        if (b.udps) |udps| for (m.instances) |inst| {
            const defn = udps.get(inst.module) orelse continue;
            var terms: std.ArrayList(Ast.ExprId) = .empty;
            for (inst.ports) |c| try terms.append(b.arena, c.expr);
            const d = b.objects.items[defn];
            const at = try b.primitive(vpiUdp, d.props[1].value, d.def_name, terms.items);
            try b.setName(at, try b.arena.dupe(u8, b.file.str(inst.name)));
            const delay = if (inst.delay.any()) try b.expr(inst.delay.rise) else none;
            b.objects.items[at].delays = try b.delays(inst.delay);
            b.objects.items[at].edges = try b.arena.dupe(Edge, &.{
                .{ .tag = vpiUdpDefn, .to = defn },
                .{ .tag = vpiDelay, .to = delay },
            });
        };
        // §11.6.21 initial and always.
        for (m.discrete) |d| {
            const body = try b.stmt(d.body);
            const at = try b.code(if (d.is_always) vpiAlways else vpiInitial, &.{.{ .tag = vpiStmt, .to = body }}, &.{}, &.{});
            try b.lists.processes.append(b.gpa, at);
        }
    }

    /// §11.6.21's third process, `analog`, over the flattened analog blocks
    /// that belong to this scope (`AnalogBlock.unit`).
    pub fn analogBlocks(b: *Builder, blocks: []const Ast.AnalogBlock) Error!void {
        for (blocks) |blk| {
            if (blk.unit != b.scope) continue;
            const body = try b.stmt(blk.body);
            const at = try b.code(vpiAnalog, &.{.{ .tag = vpiStmt, .to = body }}, &.{}, &.{});
            try b.lists.processes.append(b.gpa, at);
        }
    }

    /// A §11.6.13 primitive with its terminals: output first, then the
    /// inputs, vpiTermIndex in that order (A.3.3's terminal lists).
    fn primitive(b: *Builder, vtype: c_int, prim_type: c_int, def_name: []const u8, terms: []const Ast.ExprId) Error!u32 {
        const at = try b.code(vtype, &.{}, &.{}, &.{
            .{ .prop = vpiPrimType, .value = prim_type },
            // NOTE 1: "vpiSize shall return the number of inputs."
            .{ .prop = vpiSize, .value = @intCast(terms.len - 1) },
        });
        b.objects.items[at].def_name = def_name;
        var items: std.ArrayList(u32) = .empty;
        for (terms, 0..) |t, k| {
            const e = try b.expr(t);
            try items.append(b.arena, try b.code(vpiPrimTerm, &.{
                .{ .tag = vpiExpr, .to = e },
                .{ .tag = vpiPrimitive, .to = at },
            }, &.{}, &.{
                .{ .prop = vpiDirection, .value = if (k == 0) root.vpiOutput else root.vpiInput },
                .{ .prop = vpiTermIndex, .value = @intCast(k) },
            }));
        }
        b.objects.items[at].lists = try b.arena.dupe(List, &.{.{ .tag = vpiPrimTerm, .items = items.items }});
        try b.lists.primitives.append(b.gpa, at);
        return at;
    }

    fn subIndex(tasks: []const Ast.Subroutine, k: usize) usize {
        var n: usize = 0;
        for (tasks[0..k]) |t| {
            if (t.is_function == tasks[k].is_function) n += 1;
        }
        return n;
    }

    /// A delay3's literal values, in the module's time unit: IEEE 1364
    /// §7.14's rise, fall, and turn-off. A value that is not a literal is not
    /// folded here, and the object then holds no delays (§12.11 refuses).
    fn delays(b: *Builder, d: Ast.Delay3) Error![]const f64 {
        if (!d.any()) return &.{};
        var out: std.ArrayList(f64) = .empty;
        for ([_]Ast.ExprId{ d.rise, d.fall, d.off }) |e| {
            if (e == .none) break;
            try out.append(b.arena, literal(b.file, e) orelse return &.{});
        }
        return out.items;
    }

    // ------------------------------------------------------------ statements

    pub fn stmt(b: *Builder, id: Ast.StmtId) Error!u32 {
        if (id == .none) return none;
        const f = b.file;
        return switch (f.stmt(id)) {
            .empty => b.code(vpiNullStmt, &.{}, &.{}, &.{}),
            .block => |blk| blk: {
                // The block is made — and named — BEFORE its statements, so
                // a `disable` inside it finds it (§11.6.24 disable -> scope).
                const named = blk.name != .none;
                const vt: c_int = if (blk.parallel) (if (named) vpiNamedFork else vpiFork) else if (named) vpiNamedBegin else vpiBegin;
                const at = try b.code(vt, &.{}, &.{}, &.{});
                if (named) try b.setName(at, try b.arena.dupe(u8, f.str(blk.name)));
                var items: std.ArrayList(u32) = .empty;
                for (blk.body) |s| try items.append(b.arena, try b.stmt(s));
                b.objects.items[at].lists = try b.arena.dupe(List, &.{.{ .tag = vpiStmt, .items = try b.many(items.items) }});
                break :blk at;
            },
            .assign => |a| switch (a.continuous) {
                .none => blk: {
                    const lhs = try b.expr(a.target);
                    const rhs = try b.expr(a.value);
                    // §11.6.22 NOTE: "For delay control and event control
                    // associated with assignment, the statement shall always
                    // be NULL."
                    var dc = none;
                    var ec = none;
                    if (a.timing != .none) {
                        const e = try b.expr(a.timing);
                        if (a.timing_is_delay) {
                            dc = try b.code(vpiDelayControl, &.{ .{ .tag = vpiDelay, .to = e }, .{ .tag = vpiStmt, .to = none } }, &.{}, &.{});
                        } else {
                            ec = try b.code(vpiEventControl, &.{ .{ .tag = vpiCondition, .to = e }, .{ .tag = vpiStmt, .to = none } }, &.{}, &.{});
                        }
                    }
                    break :blk b.code(vpiAssignment, &.{
                        .{ .tag = vpiLhs, .to = lhs },
                        .{ .tag = vpiRhs, .to = rhs },
                        .{ .tag = vpiDelayControl, .to = dc },
                        .{ .tag = vpiEventControl, .to = ec },
                    }, &.{}, &.{.{ .prop = vpiBlocking, .value = @intFromBool(!a.nonblocking) }});
                },
                // §11.6.24: force and assign stmt draw vpiLhs and vpiRhs;
                // deassign and release draw vpiLhs alone.
                .assign, .force => b.code(if (a.continuous == .force) vpiForce else vpiAssignStmt, &.{
                    .{ .tag = vpiLhs, .to = try b.expr(a.target) },
                    .{ .tag = vpiRhs, .to = try b.expr(a.value) },
                }, &.{}, &.{}),
                .deassign, .release => b.code(if (a.continuous == .release) vpiRelease else vpiDeassign, &.{
                    .{ .tag = vpiLhs, .to = try b.expr(a.target) },
                }, &.{}, &.{}),
            },
            .if_stmt => |s| blk: {
                const cond = try b.expr(s.cond);
                const then = try b.stmt(s.then_s);
                if (s.else_s == .none) break :blk b.code(vpiIf, &.{
                    .{ .tag = vpiCondition, .to = cond },
                    .{ .tag = vpiStmt, .to = then },
                }, &.{}, &.{});
                break :blk b.code(vpiIfElse, &.{
                    .{ .tag = vpiCondition, .to = cond },
                    .{ .tag = vpiStmt, .to = then },
                    .{ .tag = vpiElseStmt, .to = try b.stmt(s.else_s) },
                }, &.{}, &.{});
            },
            .case_stmt => |s| blk: {
                const cond = try b.expr(s.scrutinee);
                var items: std.ArrayList(u32) = .empty;
                for (s.arms) |arm| {
                    // §11.6.23 NOTE 2: the default item has no expression, so
                    // its vpiExpr set is empty and vpi_iterate is NULL.
                    var labels: std.ArrayList(u32) = .empty;
                    for (arm.labels) |l| try labels.append(b.arena, try b.expr(l));
                    try items.append(b.arena, try b.code(vpiCaseItem, &.{.{ .tag = vpiStmt, .to = try b.stmt(arm.body) }}, &.{.{ .tag = vpiExpr, .items = try b.many(labels.items) }}, &.{}));
                }
                break :blk b.code(vpiCase, &.{.{ .tag = vpiCondition, .to = cond }}, &.{.{ .tag = vpiCaseItem, .items = items.items }}, &.{.{ .prop = vpiCaseType, .value = switch (s.kind) {
                    .normal => vpiCaseExact,
                    .casex => vpiCaseX,
                    .casez => vpiCaseZ,
                } }});
            },
            .for_stmt => |s| b.code(vpiFor, &.{
                .{ .tag = vpiForInitStmt, .to = try b.stmt(s.init) },
                .{ .tag = vpiCondition, .to = try b.expr(s.cond) },
                .{ .tag = vpiForIncStmt, .to = try b.stmt(s.step) },
                .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            .while_stmt => |s| b.code(vpiWhile, &.{
                .{ .tag = vpiCondition, .to = try b.expr(s.cond) },
                .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            .repeat_stmt => |s| b.code(vpiRepeat, &.{
                .{ .tag = vpiCondition, .to = try b.expr(s.count) },
                .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            .event_control => |s| switch (s.kind) {
                .delay => blk: {
                    const at = try b.code(vpiDelayControl, &.{
                        .{ .tag = vpiDelay, .to = try b.expr(s.event) },
                        .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                    }, &.{}, &.{});
                    if (literal(f, s.event)) |v| b.objects.items[at].delays = try b.arena.dupe(f64, &.{v});
                    break :blk at;
                },
                .event => b.code(vpiEventControl, &.{
                    .{ .tag = vpiCondition, .to = try b.expr(s.event) },
                    .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{}),
                .level => b.code(vpiWait, &.{
                    .{ .tag = vpiCondition, .to = try b.expr(s.event) },
                    .{ .tag = vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{}),
            },
            // §11.6.21 event stmt '->' -> named event.
            .event_trigger => |s| b.code(vpiEventStmt, &.{.{ .tag = vpiNamedEvent, .to = b.lookup(f.str(s.name)) }}, &.{}, &.{}),
            // §11.6.24 disable -> vpiScope: the named block, task or function.
            .disable => |s| b.code(vpiDisable, &.{.{ .tag = vpiScope, .to = b.lookup(f.str(s.name)) }}, &.{}, &.{}),
            .sys_task => |s| blk: {
                const name = f.str(s.name);
                var args: std.ArrayList(u32) = .empty;
                for (s.args) |a| try args.append(b.arena, if (a == .none) none else try b.expr(a));
                // A.6.9: a name without `$` is a user task enable (§11.6.16
                // task call -> task).
                const user = name.len == 0 or name[0] != '$';
                const at = try b.code(if (user) vpiTaskCall else vpiSysTaskCall, if (user) &.{.{ .tag = vpiTask, .to = b.lookup(name) }} else &.{}, &.{.{ .tag = vpiArgument, .items = try b.many(args.items) }}, &.{});
                b.objects.items[at].name = try b.arena.dupe(u8, name);
                b.objects.items[at].in_analog = b.analog != null;
                break :blk at;
            },
            .contribute => |s| b.contrib(s.lhs, s.rhs),
            // §5.6.7's indirect form: the class's `ind flow`/`ind potential`,
            // with vpiLhs the probe it equates and vpiRhs the equation.
            .indirect => |s| blk: {
                const at = try b.contrib(s.lhs, s.eqn);
                const probe = try b.expr(s.probe);
                // Taken after every append: a row pointer does not survive
                // the array growing.
                const o = &b.objects.items[at];
                o.edges = try b.arena.dupe(Edge, &.{
                    o.edges[0],
                    .{ .tag = vpiLhs, .to = probe },
                    o.edges[1],
                });
                o.props = try b.arena.dupe(Prop, &.{ o.props[0], .{ .prop = vpiDirect, .value = 0 } });
                break :blk at;
            },
            // A jump has no §11.6.21 object.
            .jump => none,
        };
    }

    /// §11.6.20: a contribution to a branch. The branch is the one the
    /// access names when it names a declared branch; `vpiFlow` is whether the
    /// access is the branch discipline's flow access.
    fn contrib(b: *Builder, lhs: Ast.ExprId, rhs: Ast.ExprId) Error!u32 {
        const f = b.file;
        var branch = none;
        var flow: c_int = 0;
        if (f.exprs.tag(lhs) == .branch_access) {
            const first = f.exprs.lhs(lhs);
            if (b.analog) |an| if (f.exprs.tag(first) == .ident and f.exprs.rhs(lhs) == .none) {
                if (an.branches.get(f.str(f.exprs.strOf(first)))) |br| {
                    branch = br;
                    if (b.objects.items[br].disc) |di| if (an.flow_access.get(di)) |acc| {
                        flow = @intFromBool(std.mem.eql(u8, acc, f.str(f.exprs.strOf(lhs))));
                    };
                }
            };
        }
        return b.code(vpiContrib, &.{
            .{ .tag = root.vpiBranch, .to = branch },
            .{ .tag = vpiRhs, .to = try b.expr(rhs) },
        }, &.{}, &.{
            .{ .prop = root.vpiFlow, .value = flow },
            .{ .prop = vpiDirect, .value = 1 },
        });
    }

    // ----------------------------------------------------------- expressions

    /// The object a name denotes from this scope: §6.7's upward search over
    /// the full names, innermost first.
    fn lookup(b: *Builder, name: []const u8) u32 {
        var path = b.path;
        while (true) {
            var buf: [root.name_buf_len]u8 = undefined;
            const full_name = if (path.len == 0)
                std.fmt.bufPrint(&buf, "{s}.{s}", .{ b.top_name, name }) catch return none
            else
                std.fmt.bufPrint(&buf, "{s}.{s}.{s}", .{ b.top_name, path, name }) catch return none;
            if (b.names.get(full_name)) |at| return at;
            if (path.len == 0) return none;
            path = path[0 .. std.mem.lastIndexOfScalar(u8, path, '.') orelse 0];
        }
    }

    pub fn expr(b: *Builder, id: Ast.ExprId) Error!u32 {
        if (id == .none) return none;
        const ex = &b.file.exprs;
        return switch (ex.tag(id)) {
            .ident => b.lookup(b.file.str(ex.strOf(id))),
            // An unsized integer is written in decimal (A.8.7 unsigned_number);
            // a sized one's base is not recorded by the parser, so its
            // vpiConstType is not answered.
            .int_literal => b.constant(.{ .int = ex.intValue(id) }, if (ex.intLiteral(id).width == 0) 32 else @intCast(ex.intLiteral(id).width), if (ex.intLiteral(id).width == 0) root.vpiDecConst else 0),
            .real_literal => b.constant(.{ .real = ex.realValue(id) }, 64, root.vpiRealConst),
            .str_literal => b.constant(.{ .str = try b.arena.dupe(u8, b.file.str(ex.strOf(id))) }, 0, root.vpiStringConst),
            .logic_literal => blk: {
                const lit = ex.logicValue(id);
                // A value with no x or z that fits 64 bits is an integer
                // constant; anything else is a constant whose value this
                // model does not carry.
                const known = for (lit.unknowns()) |u| {
                    if (u != 0) break false;
                } else true;
                const v = lit.values();
                const fits = v.len == 1 or (v.len > 1 and std.mem.allEqual(u64, v[1..], 0));
                break :blk b.constant(if (known and fits) .{ .int = @bitCast(v[0]) } else null, lit.width, 0);
            },
            .unary => b.operation(unaryOp(ex.unOp(id)), &.{ex.lhs(id)}),
            .binary => b.operation(binaryOp(ex.binOp(id)), &.{ ex.lhs(id), ex.rhs(id) }),
            .ternary => b.operation(vpiConditionOp, &.{ ex.lhs(id), ex.rhs(id), ex.ternaryElse(id) }),
            .concat => b.operation(vpiConcatOp, ex.args(id)),
            // §11.6.19 NOTE: "For an operator whose type is vpiMultiConcat,
            // the first operand shall be the multiplier expression."
            .multi_concat => blk: {
                const inner = ex.rhs(id);
                var ops: std.ArrayList(Ast.ExprId) = .empty;
                try ops.append(b.arena, ex.lhs(id));
                if (ex.tag(inner) == .concat) try ops.appendSlice(b.arena, ex.args(inner)) else try ops.append(b.arena, inner);
                break :blk b.operation(vpiMultiConcatOp, ops.items);
            },
            .event_posedge => b.operation(vpiPosedgeOp, &.{ex.lhs(id)}),
            .event_negedge => b.operation(vpiNegedgeOp, &.{ex.lhs(id)}),
            .event_or => b.operation(vpiEventOrOp, &.{ ex.lhs(id), ex.rhs(id) }),
            .index => b.select(id),
            .sys_call, .call => blk: {
                var args: std.ArrayList(u32) = .empty;
                for (ex.args(id)) |a| try args.append(b.arena, try b.expr(a));
                const name = b.file.str(ex.strOf(id));
                const sys = ex.tag(id) == .sys_call;
                const at = try b.code(if (sys) vpiSysFuncCall else vpiFuncCall, if (sys) &.{} else &.{.{ .tag = vpiFunction, .to = b.lookup(name) }}, &.{.{ .tag = vpiArgument, .items = try b.many(args.items) }}, &.{});
                b.objects.items[at].name = try b.arena.dupe(u8, name);
                b.objects.items[at].in_analog = b.analog != null;
                break :blk at;
            },
            // §11.6.19 accessfunc -> branches, discipline.
            .branch_access => blk: {
                var branch = none;
                if (b.analog) |an| {
                    const first = ex.lhs(id);
                    if (ex.tag(first) == .ident and ex.rhs(id) == .none) branch = an.branches.get(b.file.str(ex.strOf(first))) orelse none;
                }
                const disc = if (branch != none) b.objects.items[branch].disc orelse none else none;
                const at = try b.code(vpiAccessFunc, &.{
                    .{ .tag = root.vpiBranch, .to = branch },
                    .{ .tag = root.vpiDiscipline, .to = disc },
                }, &.{}, &.{});
                b.objects.items[at].name = try b.arena.dupe(u8, b.file.str(ex.strOf(id)));
                break :blk at;
            },
            // Not modelled: a hierarchical reference, the analog operators
            // and filters, event functions, patterns, infinities. No object.
            .hier_ident, .builtin_call, .filter_call, .noise_call, .port_access, .assign_pattern, .pattern_repl, .range, .pos_inf, .neg_inf, .event_initial_step, .event_final_step, .event_driver_update, .event_function => none,
        };
    }

    fn constant(b: *Builder, v: ?root.Const, width: u32, const_type: c_int) Error!u32 {
        return b.add(.{ .kind = .constant, .owner = null, .name = "", .full = "", .size = width, .value = v, .const_type = const_type });
    }

    fn operation(b: *Builder, op: c_int, operands: []const Ast.ExprId) Error!u32 {
        var items: std.ArrayList(u32) = .empty;
        for (operands) |o| try items.append(b.arena, try b.expr(o));
        const at = try b.code(vpiOperation, &.{}, &.{.{ .tag = vpiOperand, .items = try b.many(items.items) }}, &.{.{ .prop = vpiOpType, .value = op }});
        b.objects.items[at].owner = null;
        return at;
    }

    /// `base[i]` and `base[msb:lsb]`: an array element is the memory word or
    /// variable select the model already holds (§11.6.18); a bit of a vector
    /// is a net bit or reg bit with vpiParent and vpiIndex; a range is
    /// §11.6.19's part select.
    fn select(b: *Builder, id: Ast.ExprId) Error!u32 {
        const ex = &b.file.exprs;
        const base = try b.expr(ex.lhs(id));
        const ix = ex.rhs(id);
        if (base != none) {
            const bo = b.objects.items[base];
            if (bo.members.len != 0 and ex.tag(ix) == .int_literal) {
                const want = ex.intValue(ix);
                for (bo.members) |m| {
                    const c = b.objects.items[m].index orelse continue;
                    if (b.objects.items[c].value.?.int == want) return m;
                }
            }
        }
        if (ex.tag(ix) == .range) {
            const at = try b.code(vpiPartSelect, &.{
                .{ .tag = vpiParent, .to = base },
                .{ .tag = vpiLeftRange, .to = try b.expr(ex.lhs(ix)) },
                .{ .tag = vpiRightRange, .to = try b.expr(ex.rhs(ix)) },
            }, &.{}, &.{});
            b.objects.items[at].owner = null;
            return at;
        }
        const is_net = base != none and b.objects.items[base].kind == .net;
        const at = try b.code(if (is_net) vpiNetBit else vpiRegBit, &.{
            .{ .tag = vpiParent, .to = base },
            .{ .tag = vpiIndex, .to = try b.expr(ix) },
        }, &.{}, &.{});
        b.objects.items[at].owner = null;
        return at;
    }
};

/// Annex G's vpiPrimType for a §7.8 gate.
fn gateType(k: Ast.GateKind) c_int {
    return switch (k) {
        .g_and => 1,
        .g_nand => 2,
        .g_nor => 3,
        .g_or => 4,
        .g_xor => 5,
        .g_xnor => 6,
        .g_buf => 7,
        .g_not => 8,
        .g_bufif0 => 9,
        .g_bufif1 => 10,
        .g_notif0 => 11,
        .g_notif1 => 12,
    };
}

/// A gate's vpiDefName: its keyword (A.3.4).
fn gateName(k: Ast.GateKind) []const u8 {
    return switch (k) {
        .g_and => "and",
        .g_nand => "nand",
        .g_nor => "nor",
        .g_or => "or",
        .g_xor => "xor",
        .g_xnor => "xnor",
        .g_buf => "buf",
        .g_not => "not",
        .g_bufif0 => "bufif0",
        .g_bufif1 => "bufif1",
        .g_notif0 => "notif0",
        .g_notif1 => "notif1",
    };
}

/// §11.6.14 the UDP definitions of `file`, design-wide (the diagram's
/// circled arrow): each with its io decls (the output, then the inputs) and
/// its table entries, whose vpiSize is "number of symbol entries" — one per
/// input field (an edge `(01)` is one field), one for the current state of
/// a sequential entry, one for the output.
pub fn udpDefns(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *std.ArrayList(Obj),
    file: *const Ast.SourceFile,
    out: *std.AutoHashMapUnmanaged(Ast.StrId, u32),
) Error![]const u32 {
    const defns = try arena.alloc(u32, file.udps.len);
    for (file.udps, defns) |*u, *at| {
        var ios: std.ArrayList(u32) = .empty;
        for (u.ports, 0..) |p, k| {
            try ios.append(arena, @intCast(objects.items.len));
            try objects.append(gpa, .{ .kind = .code, .owner = null, .name = try arena.dupe(u8, file.str(p)), .full = "", .vtype = vpiIODecl, .props = try arena.dupe(Prop, &.{
                .{ .prop = vpiDirection, .value = if (k == 0) root.vpiOutput else root.vpiInput },
                .{ .prop = vpiSize, .value = 1 },
            }) });
        }
        var rows: std.ArrayList(u32) = .empty;
        for (u.rows) |r| {
            var fields: c_int = 0;
            var in_edge = false;
            for (r.inputs) |c| switch (c) {
                '(' => in_edge = true,
                ')' => {
                    in_edge = false;
                    fields += 1;
                },
                ' ', '\t' => {},
                else => if (!in_edge) {
                    fields += 1;
                },
            };
            try rows.append(arena, @intCast(objects.items.len));
            try objects.append(gpa, .{ .kind = .code, .owner = null, .name = "", .full = "", .vtype = vpiTableEntry, .props = try arena.dupe(Prop, &.{
                .{ .prop = vpiSize, .value = fields + @intFromBool(u.is_sequential) + 1 },
            }) });
        }
        at.* = @intCast(objects.items.len);
        try objects.append(gpa, .{
            .kind = .code,
            .owner = null,
            .name = "",
            .full = "",
            .vtype = vpiUdpDefn,
            .def_name = try arena.dupe(u8, file.str(u.name)),
            .props = try arena.dupe(Prop, &.{
                .{ .prop = vpiSize, .value = @intCast(u.ports.len - 1) },
                .{ .prop = vpiPrimType, .value = if (u.is_sequential) vpiSeqPrim else vpiCombPrim },
            }),
            .lists = try arena.dupe(List, &.{
                .{ .tag = vpiIODecl, .items = ios.items },
                .{ .tag = vpiTableEntry, .items = rows.items },
            }),
        });
        try out.put(gpa, u.name, at.*);
    }
    return defns;
}

fn direction(d: Ast.Direction) c_int {
    return switch (d) {
        .input => root.vpiInput,
        .output => root.vpiOutput,
        .inout => root.vpiInout,
        .unspecified => root.vpiNoDirection,
    };
}

fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) c_int {
    if (v.ty == .integer and v.storage != .reg) return 32;
    if (v.ty == .real) return 64;
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return root.vpiUndefined;
    return @intCast(@abs(file.exprs.intValue(range.msb) - file.exprs.intValue(range.lsb)) + 1);
}

/// A literal delay, as a real: an integer or a real literal. Null otherwise.
fn literal(file: *const Ast.SourceFile, e: Ast.ExprId) ?f64 {
    return switch (file.exprs.tag(e)) {
        .int_literal => @floatFromInt(file.exprs.intValue(e)),
        .real_literal => file.exprs.realValue(e),
        else => null, // else: only a literal folds without the elaborator
    };
}

fn unaryOp(op: Ast.UnaryOp) c_int {
    return switch (op) {
        .plus => vpiPlusOp,
        .minus => vpiMinusOp,
        .logical_not => vpiNotOp,
        .bit_not => vpiBitNegOp,
        .reduce_and => vpiUnaryAndOp,
        .reduce_nand => vpiUnaryNandOp,
        .reduce_or => vpiUnaryOrOp,
        .reduce_nor => vpiUnaryNorOp,
        .reduce_xor => vpiUnaryXorOp,
        .reduce_xnor => vpiUnaryXNorOp,
    };
}

fn binaryOp(op: Ast.BinaryOp) c_int {
    return switch (op) {
        .add => vpiAddOp,
        .sub => vpiSubOp,
        .mul => vpiMultOp,
        .div => vpiDivOp,
        .mod => vpiModOp,
        .pow => vpiPowerOp,
        .eq => vpiEqOp,
        .neq => vpiNeqOp,
        .case_eq => vpiCaseEqOp,
        .case_neq => vpiCaseNeqOp,
        .lt => vpiLtOp,
        .le => vpiLeOp,
        .gt => vpiGtOp,
        .ge => vpiGeOp,
        .logical_and => vpiLogAndOp,
        .logical_or => vpiLogOrOp,
        .bit_and => vpiBitAndOp,
        .bit_or => vpiBitOrOp,
        .bit_xor => vpiBitXorOp,
        .bit_xnor => vpiBitXNorOp,
        .shl => vpiLShiftOp,
        .shr => vpiRShiftOp,
        .ashl => vpiArithLShiftOp,
        .ashr => vpiArithRShiftOp,
    };
}

// ---------------------------------------------------------------------------
// §12.11 vpi_get_delays
// ---------------------------------------------------------------------------

const callback = @import("callback.zig");
const run = @import("run.zig");

/// Figure 12-4, laid out as Annex G does (its `bool`s are PLI_INT32).
pub const Delay = extern struct {
    da: [*c]callback.Time,
    no_of_delays: c_int,
    time_type: c_int,
    mtm_flag: c_int,
    append_flag: c_int,
    pulsere_flag: c_int,
};

/// "shall retrieve the delays or pulse limits of an object and place them in
/// an s_vpi_delay structure which has been allocated by the user. The format
/// of the delay information shall be controlled by the time_type flag".
///
/// The objects with delays here are the ones §11.6 draws `vpi_get_delays()`
/// under and this model folds: a primitive (§11.6.13), a continuous
/// assignment (§11.6.17) and a delay control (§11.6.22). §12.11: "For
/// primitive objects, the no_of_delays value shall be 2 or 3." It names no
/// count for the other two; a continuous assignment carries a primitive's
/// delay3 (IEEE 1364 §6.1.3), so it takes 2 or 3 and the 1 its own `#d`
/// form writes, and a delay control holds 1. A delay asked for beyond those written is IEEE 1364
/// §7.14's derived one: fall = rise, turn-off = min(rise, fall).
///
/// Table 12-3's min/typ/max triple is one value three times (no mintypmax
/// expression reaches this model), and the reject and error limits of an
/// inertial delay are the delay itself (IEEE 1364 §14.6.1's default).
pub export fn vpi_get_delays(obj: root.vpiHandle, delay_p: ?*Delay) void {
    root.clearError();
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_delays: that handle is not an object", .{});
        return;
    };
    const d = delay_p orelse {
        root.fail("BADDELAY", "vpi_get_delays: delay_p is NULL", .{});
        return;
    };
    if (o.kind != .code or o.delays.len == 0) {
        root.fail("NODELAY", "vpi_get_delays: that object carries no delays", .{});
        return;
    }
    // §12.11: "For primitive objects, the no_of_delays value shall be 2 or
    // 3."
    const primitive = o.vtype == vpiGate or o.vtype == vpiUdp;
    const least: c_int = if (primitive) 2 else 1;
    const most: c_int = if (o.vtype == vpiDelayControl) 1 else 3;
    if (d.no_of_delays < least or d.no_of_delays > most) {
        root.fail("BADDELAY", "vpi_get_delays: no_of_delays {d} is not legal here ({d}..{d})", .{ d.no_of_delays, least, most });
        return;
    }
    if (d.time_type != callback.vpiScaledRealTime and d.time_type != callback.vpiSimTime) {
        root.fail("BADDELAY", "vpi_get_delays: time_type {d} is neither vpiScaledRealTime nor vpiSimTime", .{d.time_type});
        return;
    }
    if (d.da == null) {
        root.fail("BADDELAY", "vpi_get_delays: da is NULL", .{});
        return;
    }
    const rise = o.delays[0];
    const fall = if (o.delays.len > 1) o.delays[1] else rise;
    const off = if (o.delays.len > 2) o.delays[2] else @min(rise, fall);
    const values = [3]f64{ rise, fall, off };
    const mtm: usize = if (d.mtm_flag != 0) 3 else 1;
    const pulse: usize = if (d.pulsere_flag != 0) 3 else 1;
    var at: usize = 0;
    for (values[0..@intCast(d.no_of_delays)]) |v| {
        for (0..pulse) |_| for (0..mtm) |_| {
            var t: callback.Time = .{ .type = d.time_type, .high = 0, .low = 0, .real = v };
            if (d.time_type == callback.vpiSimTime) {
                const ticks = run.ticksOf(.{ .type = callback.vpiScaledRealTime, .high = 0, .low = 0, .real = v }, obj) orelse return;
                t = .{ .type = callback.vpiSimTime, .high = @truncate(ticks >> 32), .low = @truncate(ticks), .real = 0 };
            }
            d.da[at] = t;
            at += 1;
        };
    }
}
