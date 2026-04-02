//! Class 11/12 — the VPI object model and the C routines over it.
//! LRM §11.6 (the data model diagrams), §12.2–§12.35 (the routines),
//! §12.33.2 (`vlog_startup_routines`).
//!
//! WHAT THIS IS FOR. Everything above this file compiles Verilog-AMS into one
//! device. An application — a waveform viewer, a testbench driver, a
//! parameter-extraction tool — could not ask that device what the design
//! CONTAINS, because the only C surface VerA had was `contract.SystfHost`: an
//! opaque ctx and one `call(ctx, k, args, partials) -> f64`. That is a hook for
//! a system function, not an interface to a design, and §11.3.1's whole subject
//! is the second thing. This file is the second thing.
//!
//! WHAT IT IS BUILT OVER, and the one design decision worth arguing. §11.2.2
//! says VPI access is INSTANCE-UNIQUE: `m1.w` and `m2.w` are two objects. That
//! is the elaborated design, which is `ir/elaborate.zig`'s output — and that
//! output is FLAT, deliberately (read that file's header). A flat design still
//! carries the whole hierarchy, in two places:
//!
//!   - every flattened declaration is named by its §6.7 path (`u.v.r`), because
//!     `Elaborate.sep` makes the mangling BE the path; and
//!   - `Lowered.hier_names` resolves a path to the entity it denotes, which is
//!     how a child port that was collapsed into its parent's net is still
//!     reachable by the name the source wrote.
//!
//! So the scope tree here is not a second elaboration. It is the instance tree
//! read back out: the SHAPE is `Lowered.unit_paths`, the row elaboration
//! publishes per inlined instance together with the definition it came from —
//! §11.6.1's `vpiDefName`, the one fact flattening erases — and the CONTENTS
//! of each scope come from the elaborated module, split at the last
//! `Elaborate.sep`. Both halves are elaboration's answer; nothing here decides
//! which module an instance names.
//!
//! HANDLES. §12.3 says handle equivalence "can not be determined with a C `==`
//! comparison", which licenses an implementation to hand out a fresh pointer
//! per query. VerA does the opposite: every object is materialized once at
//! `open` into one array that is never resized, and a handle is a pointer into
//! it. Two lookups of the same object therefore give the same pointer, and
//! `vpi_compare_objects` is a pointer compare. That is not laziness about the
//! contract — it is what makes the contract CHEAP AND CHECKABLE. An application
//! may still not use `==`, and nothing here promises it will keep working.
//!
//! The reason the fixed array matters is the trust boundary. Handles crossing
//! this boundary come from C, so every one of them is arbitrary memory until
//! proven otherwise. A pointer is ours iff it lands inside `objects` on an
//! element boundary, or iff it is a live iterator we allocated. Nothing else is
//! ever dereferenced. An `ArrayList` that could reallocate under a handle an
//! application is holding would make that test a lie.
//!
//! NOT HERE, and each is a later plan item rather than an omission:
//!   - values (§12.16 `vpi_get_value`, §12.30 `vpi_put_value`, §12.10's analog
//!     family). `s_vpi_value` is declared in `vpi_user.h`; no routine takes one.
//!   - callbacks (§12.31) and system task/function registration (§12.32,
//!     §12.33). `vlog_startup_routines` IS called — an object model with no
//!     moment to be walked in is not usable — but what an entry can do in it
//!     today is walk the design, not register a systf.

const std = @import("std");
const Ast = @import("frontend").Ast;
const sim = @import("sim");

// The routine families that live in their own files. Referenced here so their
// `export fn`s are emitted and their tests run with this module's.
const print = @import("print.zig");
pub const run = @import("run.zig");
pub const callback = @import("callback.zig");
pub const value = @import("value.zig");
pub const systf = @import("systf.zig");
comptime {
    _ = print;
    _ = run;
    _ = callback;
    _ = value;
    _ = systf;
}
test {
    _ = print;
    _ = run;
    _ = callback;
    _ = value;
    _ = systf;
}
const Lower = @import("ir").Lower;
const Lowered = @import("ir").Lowered;
const Elaborate = @import("ir").Elaborate;

// ---------------------------------------------------------------------------
// vpi_user.h, from the other side.
//
// These MUST agree with src/vpi/vpi_user.h, which is IEEE 1364-2005 Annex G's
// numbering (Verilog-AMS §12.2 and §12.31 both defer to it for the header
// listing). Nothing mechanical enforces the agreement — a `.h` and a `.zig`
// have no shared source of truth — so the acceptance test enforces it instead:
// tests/vpi_app.c is compiled against the HEADER and asserts, for example,
// `vpi_get(vpiType, m) == vpiModule`. Every constant the C program names is
// checked that way, which is why the C program is the acceptance test and a
// Zig unit test could not be.
// ---------------------------------------------------------------------------

// §11.6 object types.
pub const vpiConstant: c_int = 7;
pub const vpiIntegerVar: c_int = 25;
pub const vpiIterator: c_int = 27;
pub const vpiMemory: c_int = 29;
pub const vpiMemoryWord: c_int = 30;
pub const vpiRealVar: c_int = 47;
pub const vpiVarSelect: c_int = 68;
pub const vpiModuleArray: c_int = 112;
pub const vpiRegArray: c_int = 116;

// §11.6.10/§11.6.11 relationships and properties.
pub const vpiArray: c_int = 28;
pub const vpiIsMemory: c_int = 73;
pub const vpiIndex: c_int = 78;
pub const vpiParent: c_int = 81;
pub const vpiDecConst: c_int = 1;
pub const vpiModule: c_int = 32;
pub const vpiNet: c_int = 36;
pub const vpiParameter: c_int = 41;
pub const vpiPort: c_int = 44;
pub const vpiReg: c_int = 48;

// Relationships.
pub const vpiScope: c_int = 84;
pub const vpiInternalScope: c_int = 92;

// Properties.
pub const vpiUndefined: c_int = -1;
pub const vpiType: c_int = 1;
pub const vpiName: c_int = 2;
pub const vpiFullName: c_int = 3;
pub const vpiSize: c_int = 4;
pub const vpiTopModule: c_int = 7;
pub const vpiDefName: c_int = 9;
pub const vpiScalar: c_int = 17;
pub const vpiVector: c_int = 18;
pub const vpiDirection: c_int = 20;
pub const vpiPortIndex: c_int = 29;
pub const vpiConstType: c_int = 40;
pub const vpiSigned: c_int = 65;
pub const vpiLocalParam: c_int = 70;

// §6.5.2.2 directions.
pub const vpiInput: c_int = 1;
pub const vpiOutput: c_int = 2;
pub const vpiInout: c_int = 3;
pub const vpiMixedIO: c_int = 4;
pub const vpiNoDirection: c_int = 5;

// §11.6.12 constant subtypes, over §3.4.1's parameter types.
pub const vpiRealConst: c_int = 2;
pub const vpiStringConst: c_int = 6;
pub const vpiIntConst: c_int = 7;

// §12.2 error state, and Table 12-1's severity ladder.
pub const vpiCompile: c_int = 1;
pub const vpiPLI: c_int = 2;
pub const vpiRun: c_int = 3;
pub const vpiNotice: c_int = 1;
pub const vpiWarning: c_int = 2;
pub const vpiError: c_int = 3;
pub const vpiSystem: c_int = 4;
pub const vpiInternal: c_int = 5;

/// §11.3.1. Opaque to the application: a pointer into `Design.objects`, or to a
/// live `Iter`, and validated as one before it is followed.
pub const vpiHandle = ?*anyopaque;

/// Figure 12-1 `s_vpi_error_info`, laid out for C.
pub const ErrorInfo = extern struct {
    state: c_int,
    level: c_int,
    message: [*c]u8,
    product: [*c]u8,
    code: [*c]u8,
    file: [*c]u8,
    line: c_int,
};

// ---------------------------------------------------------------------------
// The object model
// ---------------------------------------------------------------------------

/// The five object classes P01 answers: §11.6.1 module, §11.6.4 ports,
/// §11.6.8 nets, §11.6.9 regs, §11.6.12 parameter.
///
/// §11.6.5 NODES are not a sixth entry, and that is a judgement rather than an
/// oversight: in the elaborated design an `electrical` declaration and a `wire`
/// declaration are the same `Ast.NetDecl` row, so splitting them here would be
/// a distinction this compiler's IR does not make. Both are reported as
/// `vpiNet`. The day a node earns its own class is the day `vpiDomain` or a
/// discipline handle is answerable, which is P02's neighbourhood.
const Kind = enum(u8) {
    module,
    port,
    net,
    reg,
    parameter,
    /// §11.6.10 `integer` and `real` variables.
    integer,
    real_var,
    /// §11.6.10/§11.6.11 arrays. A reg array is IEEE 1364 §26.6.9's memory
    /// (vpiRegArray, vpiIsMemory); an integer or real array is a variable of
    /// its element type with vpiArray set (§26.6.7). Each holds its elements
    /// in `members`.
    reg_array,
    var_array,
    /// One element: a memory word (a vpiReg) or a variable select.
    word,
    var_select,
    /// §6.2.2's `u[1:0]`: one array object over its member module instances.
    module_array,
    /// An index expression — the object `vpiIndex` leads to. Always a
    /// decimal integer constant, read by vpi_get_value.
    constant,
};

/// `vpi_get(vpiType, o)`.
fn typeOf(o: *const Obj) c_int {
    return switch (o.kind) {
        .module => vpiModule,
        .port => vpiPort,
        .net => vpiNet,
        .reg, .word => vpiReg,
        .parameter => vpiParameter,
        .integer => vpiIntegerVar,
        .real_var => vpiRealVar,
        .reg_array => vpiRegArray,
        .var_array => if (o.ty == .real) vpiRealVar else vpiIntegerVar,
        .var_select => vpiVarSelect,
        .module_array => vpiModuleArray,
        .constant => vpiConstant,
    };
}

/// §26.3.2's string form of a type: `vpi_get_str(vpiType, o)`.
fn typeName(t: c_int) []const u8 {
    return switch (t) {
        vpiModule => "vpiModule",
        vpiPort => "vpiPort",
        vpiNet => "vpiNet",
        vpiReg => "vpiReg",
        vpiParameter => "vpiParameter",
        vpiIntegerVar => "vpiIntegerVar",
        vpiRealVar => "vpiRealVar",
        vpiRegArray => "vpiRegArray",
        vpiVarSelect => "vpiVarSelect",
        vpiModuleArray => "vpiModuleArray",
        vpiConstant => "vpiConstant",
        else => "vpiUndefined",
    };
}

/// One VPI object. Materialized once at `open`; a `vpiHandle` is a pointer to
/// one of these.
///
/// ONE STRUCT FOR FIVE CLASSES rather than a tagged union: the per-class fields
/// are four scalars, the whole table is a few hundred rows in a design of any
/// realistic size, and the alternative costs every `vpi_get` arm a switch on
/// the payload before it can switch on the property. The fields a class does
/// not use hold their defaults and are never read; each names its owner.
pub const Obj = struct {
    kind: Kind,
    /// §11.6's "one-to-one relationship back to module": the SCOPE INDEX this
    /// object is declared in. For a `.module` this is its PARENT scope, so the
    /// edge is the same edge for every class and `vpi_handle(vpiScope, …)` has
    /// one arm. `null` on the top module only.
    owner: ?u32,
    /// `.module` only: which `Design.scopes` row is this module's own scope.
    scope: u32 = 0,
    /// §11.6 `vpiName` — the local name.
    name: []const u8,
    /// §11.6 `vpiFullName` — the hierarchical name, top module included.
    full: []const u8,
    /// §11.6.4/§11.6.8/§11.6.9 `vpiSize`; 1 for a scalar, 0 for a declared
    /// range that did not fold (see `packedWidth`). Meaningless for a `.module`
    /// and a `.parameter`, which report `vpiUndefined` for it.
    size: u32 = 1,
    /// `.port` only — §6.5.2.2.
    direction: Ast.Direction = .unspecified,
    /// `.port` only — §11.6.4 `vpiPortIndex`, the position in the header.
    port_index: u32 = 0,
    /// `.parameter` only — §3.4.1, mapped onto §11.6.12's `vpiConstType`.
    ty: Ast.Type = .unspecified,
    /// `.parameter` only — §3.4.5.
    is_local: bool = false,
    /// `.reg` only.
    is_signed: bool = true,
    /// The digital engine's storage slot for this object's value, when the
    /// design is a running digital one (`openDigital`). Null in the analog
    /// model, whose values live in a compiled device this process never sees.
    slot: ?u32 = null,
    /// `.parameter` of the analog model: the constant lowering folded for it
    /// (`Lowered.consts`), copied. §11.6.12 NOTE 1 gives a parameter "the value
    /// of the parameter" as a value, and this is the only value an analog
    /// compile holds without running the device.
    value: ?Lower.Const = null,
    /// An element (word, var select, array member module): the array object
    /// it belongs to — §11.6.11's `vpiParent`, §6.2.2's `vpiModuleArray`.
    parent: ?u32 = null,
    /// An element: the `.constant` object its `vpiIndex` edge leads to.
    index: ?u32 = null,
    /// An array: its elements, in increasing index.
    members: []const u32 = &.{},
};

/// One module instance, with the §11.6.1 one-to-many sets it is the reference
/// object of. The sets hold object INDICES rather than pointers so that
/// building them cannot be invalidated by the object array being sized; after
/// `open` they are read-only.
///
/// INVARIANT, relied on by every traversal: scope `i`'s own `vpiModule` object
/// is `objects[i]`. Modules are appended first and in scope order, which is
/// what makes an object's `owner` scope index also its owner's object index.
const Scope = struct {
    parent: ?u32,
    /// §11.6.1 `vpiDefName` — the module definition this is an instance of.
    /// The one property the flattened design cannot answer, which is why the
    /// scope tree is walked from the definitions rather than from flat names.
    def_name: []const u8,
    /// The §6.7 path relative to the top, `""` at the root. The key the flat
    /// declarations are bucketed by.
    path: []const u8,
    children: []const u32 = &.{},
    ports: []const u32 = &.{},
    nets: []const u32 = &.{},
    regs: []const u32 = &.{},
    params: []const u32 = &.{},
    integers: []const u32 = &.{},
    reals: []const u32 = &.{},
    reg_arrays: []const u32 = &.{},
    module_arrays: []const u32 = &.{},
};

/// §12.23's iterator. Individually allocated so that a pointer VerA did not
/// hand out cannot be mistaken for one: `Design.iters` is the set of live ones,
/// and membership is the whole validity test.
const Iter = struct {
    /// Object indices, in §11.6's order, which is source order.
    items: []const u32,
    at: usize = 0,
    /// Handles to objects that are not in `Design.objects` (§11.6.25 time
    /// queues), OWNED by the iterator; scanned instead of `items` when set.
    handles: ?[]vpiHandle = null,
};

pub const Design = struct {
    gpa: std.mem.Allocator,
    /// Owns every name string and every slice below. The design's strings are
    /// COPIED out of the compilation arena on purpose: a `CompileResult` may be
    /// freed while an application still holds handles, and a handle into freed
    /// memory is the failure mode this whole file exists to make impossible.
    arena: std.heap.ArenaAllocator,
    /// FIXED allocation — see the file header. A handle points into this, so it
    /// may never move.
    objects: []Obj,
    scopes: []Scope,
    /// §11.6.1 NOTE 1 — what `vpi_iterate(vpiModule, NULL)` walks. One entry:
    /// `Elaborate.pickTop` elaborates exactly one design root.
    top_modules: []const u32,
    /// §11.6 `vpiFullName` → object index. Every object has one and they are
    /// unique, which is what makes §12.21 a lookup rather than a tree walk.
    by_name: std.StringHashMapUnmanaged(u32),
    /// The live iterators, keyed by handle value.
    iters: std.AutoHashMapUnmanaged(usize, *Iter),

    pub fn deinit(self: *Design) void {
        var it = self.iters.valueIterator();
        while (it.next()) |p| {
            if (p.*.handles) |hs| self.gpa.free(hs);
            self.gpa.destroy(p.*);
        }
        self.iters.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.gpa.free(self.objects);
        self.gpa.free(self.scopes);
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// The global design
//
// ponytail: ONE design per process, in a global. The VPI is a global C
// namespace by construction — §12.33.2's `vlog_startup_routines` is itself a
// link-time global, and no routine in Clause 12 takes a context argument — so a
// per-design context would be a parameter no conforming application could pass.
// Upgrade path, if a host ever elaborates two designs at once: give `Design` a
// name, keep a registry, and select with a VerA-specific entry point the
// standard routines read. Not speculatively built.
//
// Not thread-safe, for the same reason and with the same upgrade: the interface
// has no thread parameter either.
// ---------------------------------------------------------------------------

pub var design: ?Design = null;

/// Build the object model over one elaborated design and install it.
///
/// `lowered` is what `Lower.lowerFile` produced: `lowered.module` is the
/// elaborated top (`Elaborate.Design.top`) and `lowered.hier_names` its §6.7
/// path table. Everything read out of it is copied, so the caller may free its
/// `CompileResult` the moment this returns.
pub fn open(gpa: std.mem.Allocator, lowered: *const Lowered) !void {
    if (design != null) close();
    design = try build(gpa, lowered);
}

pub fn close() void {
    if (design) |*d| d.deinit();
    design = null;
    run.detach();
    callback.reset();
    value.reset();
    systf.reset();
    clearError();
}

/// §12.33.2. Call each entry of the application's `vlog_startup_routines` once,
/// in order, stopping at the 0 terminator.
///
/// THE REFERENCE IS STRONG, and that is the clause's own arrangement rather
/// than a limitation: "This C function shall be provided with a VPI-compliant
/// product. Entries in the array shall be added by the user. The location of
/// vlog_startup_routines and the procedure for linking vlog_startup_routines
/// with a software product shall be defined by the product vendor." The array
/// and the application are one link unit — the LRM's own example writes the
/// definition into "a vendor product file" alongside `extern` declarations of
/// the user's routines — so a binary that CALLS this must link one.
///
/// A binary that does not call it does not need one: the `@extern` is inside
/// this body, so a build of VerA with no VPI application attached never
/// references the symbol. `tests/vpi_host.zig` is the binary that does; the
/// module's own tests drive `runStartupTable` instead, which is this function
/// with the table handed to it.
pub fn runStartupRoutines() void {
    runStartupTable(@extern(?[*]const ?StartupFn, .{ .name = "vlog_startup_routines" }));
}

/// The loop half of §12.33.2, separated from the symbol so it is reachable
/// without one. A null table is a no-op and not an error: an application that
/// registers nothing at startup is a legal application.
pub fn runStartupTable(table: ?[*]const ?StartupFn) void {
    const entries = table orelse return;
    var i: usize = 0;
    while (entries[i]) |f| : (i += 1) f();
}

pub const StartupFn = *const fn () callconv(.c) void;

// ---------------------------------------------------------------------------
// Building the model
// ---------------------------------------------------------------------------

/// A scope under construction: the definition it instantiates, plus the
/// growable sets that become `Scope`'s slices.
const Building = struct {
    decl: *const Ast.ModuleDecl,
    def_name: []const u8,
    path: []const u8,
    parent: ?u32,
    children: std.ArrayList(u32) = .empty,
    ports: std.ArrayList(u32) = .empty,
    nets: std.ArrayList(u32) = .empty,
    regs: std.ArrayList(u32) = .empty,
    params: std.ArrayList(u32) = .empty,
    integers: std.ArrayList(u32) = .empty,
    reals: std.ArrayList(u32) = .empty,
    reg_arrays: std.ArrayList(u32) = .empty,
    module_arrays: std.ArrayList(u32) = .empty,

    fn deinit(s: *Building, gpa: std.mem.Allocator) void {
        s.children.deinit(gpa);
        s.ports.deinit(gpa);
        s.nets.deinit(gpa);
        s.regs.deinit(gpa);
        s.params.deinit(gpa);
        s.integers.deinit(gpa);
        s.reals.deinit(gpa);
        s.reg_arrays.deinit(gpa);
        s.module_arrays.deinit(gpa);
    }
};

/// `lowered` carries no elaborated top to model. Not a diagnostic: a caller
/// that hands over a `Lowered` no `lowerFile` produced has a bug in its own
/// sequencing.
pub const Error = error{ OutOfMemory, NotElaborated };

fn build(gpa: std.mem.Allocator, lowered: *const Lowered) Error!Design {
    var d: Design = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .objects = &.{},
        .scopes = &.{},
        .top_modules = &.{},
        .by_name = .empty,
        .iters = .empty,
    };
    errdefer d.deinit();
    const arena = d.arena.allocator();

    const file = lowered.file;
    const flat = lowered.module orelse return error.NotElaborated;
    const top_name = try arena.dupe(u8, file.str(flat.name));

    // --- the scope tree ----------------------------------------------------
    // §11.6.1's `vpiInternalScope`, READ from elaboration rather than walked
    // again. `Lowered.unit_paths` is one row per inlined instance, depth first in
    // source order, and each row carries the definition it was inlined from —
    // `vpiDefName`, the one fact flattening erases. Instance arrays, §6.4.2
    // paramset selection and chains, and Annex E.2.1's netlist match were all
    // decided there, once; a second walk here was a second set of rules, and
    // it drifted. A tree of one publishes no rows (`Elaborate` hands the parsed
    // module over by pointer), so it is its own single row.
    const units = if (lowered.unit_paths.len != 0) lowered.unit_paths else &[_]Elaborate.UnitPath{
        .{ .module = top_name, .path = "", .decl = flat },
    };
    var scopes: std.ArrayList(Building) = .empty;
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    // A path → scope index table: a unit finds its parent by it, and bucketing
    // the flattened declarations costs a lookup per declaration.
    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_path.deinit(gpa);
    for (units, 0..) |u, i| {
        const path = try arena.dupe(u8, std.mem.trimEnd(u8, u.path, &.{Elaborate.sep}));
        const at: u32 = @intCast(i);
        // Rows come parent first, so the parent is already in the table. Unit 0
        // is the top, whose path is "".
        const parent: ?u32 = if (i == 0) null else by_path.get(path[0 .. std.mem.lastIndexOfScalar(u8, path, Elaborate.sep) orelse 0]).?;
        try scopes.append(gpa, .{
            .decl = u.decl,
            .def_name = try arena.dupe(u8, u.module),
            .path = path,
            .parent = parent,
        });
        if (parent) |p| try scopes.items[p].children.append(gpa, at);
        try by_path.put(gpa, path, at);
    }

    // --- the objects -------------------------------------------------------
    var objects: std.ArrayList(Obj) = .empty;
    defer objects.deinit(gpa);

    // Modules FIRST and in scope order: that is the `Scope` invariant, and it
    // is what lets an object's `owner` scope index double as its owner's
    // object index.
    for (scopes.items, 0..) |s, i| try objects.append(gpa, .{
        .kind = .module,
        .owner = s.parent,
        .scope = @intCast(i),
        .name = if (i == 0) top_name else lastComponent(s.path),
        .full = try joinPath(arena, top_name, s.path),
    });

    // §11.6.4 ports. Read from the DEFINITION, not from the flattened module:
    // flattening collapses a child's port into the parent net it was bound to
    // (`Elaborate.Design.names`), so the flat module holds only the top's ports
    // and a child's would otherwise have no object at all — even though §6.7
    // still lets source name it and `hier_names` still resolves it.
    //
    // The SIZE comes back from the flat side through that same table: a port's
    // width is the width of the node it denotes, and `Lowered.vectors` is the
    // §3.6.3 range already folded, keyed by the flat name.
    for (scopes.items, 0..) |*s, i| {
        for (s.decl.ports, 0..) |p, k| {
            const local = try arena.dupe(u8, file.str(p.name));
            const path = try joinPath(arena, s.path, local);
            const node = lowered.hier_names.get(path) orelse path;
            try s.ports.append(gpa, @intCast(objects.items.len));
            try objects.append(gpa, .{
                .kind = .port,
                .owner = @intCast(i),
                .name = local,
                .full = try joinPath(arena, top_name, path),
                .size = vectorSize(lowered, node),
                .direction = p.direction,
                .port_index = @intCast(k),
            });
        }
    }

    // §11.6.8/§11.6.9/§11.6.12 — the contents of every scope, from the
    // ELABORATED module. Each flat name is its own §6.7 path, so the scope it
    // belongs to is the part before the last `Elaborate.sep` and the `vpiName`
    // is the part after. A declaration whose path names no scope is dropped
    // rather than guessed at; nothing a flatten produces has one, and inventing
    // a scope for it would be inventing hierarchy.
    for (flat.nets) |n| {
        const flat_name = file.str(n.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        try scopes.items[split.scope].nets.append(gpa, @intCast(objects.items.len));
        try objects.append(gpa, .{
            .kind = .net,
            .owner = split.scope,
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .size = vectorSize(lowered, flat_name),
        });
    }
    for (flat.vars) |v| {
        // §11.6.9 is about REGS; `real` and `integer` are §11.6.10's
        // variables, with their own tags. Arrays of either are §11.6.11.
        const flat_name = file.str(v.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        if (v.dims.len == 1) {
            const dim = literalDim(file, v.dims[0]) orelse continue;
            const is_reg = v.storage == .reg;
            if (!is_reg and v.ty != .real and v.ty != .integer) continue;
            const at = try addArray(gpa, arena, &objects, if (is_reg) .reg_array else .var_array, split.scope, split.local, try joinPath(arena, top_name, flat_name), if (is_reg) .integer else v.ty, dim.low, dim.high, if (is_reg) packedWidth(file, v) else if (v.ty == .real) 64 else 32, null);
            const list = if (is_reg) &scopes.items[split.scope].reg_arrays else if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, at);
            continue;
        }
        if (v.dims.len != 0) continue;
        if (v.storage == .variable and (v.ty == .real or v.ty == .integer)) {
            const list = if (v.ty == .real) &scopes.items[split.scope].reals else &scopes.items[split.scope].integers;
            try list.append(gpa, @intCast(objects.items.len));
            try objects.append(gpa, .{
                .kind = if (v.ty == .real) .real_var else .integer,
                .owner = split.scope,
                .name = split.local,
                .full = try joinPath(arena, top_name, flat_name),
                .size = if (v.ty == .real) 64 else 32,
                .ty = v.ty,
            });
            continue;
        }
        if (v.storage != .reg) continue;
        try scopes.items[split.scope].regs.append(gpa, @intCast(objects.items.len));
        try objects.append(gpa, .{
            .kind = .reg,
            .owner = split.scope,
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .size = packedWidth(file, v),
            .is_signed = v.is_signed,
        });
    }
    for (flat.params) |p| {
        const flat_name = file.str(p.name);
        const split = (try splitPath(arena, &by_path, flat_name)) orelse continue;
        try scopes.items[split.scope].params.append(gpa, @intCast(objects.items.len));
        try objects.append(gpa, .{
            .kind = .parameter,
            .owner = split.scope,
            .name = split.local,
            .full = try joinPath(arena, top_name, flat_name),
            .ty = p.ty,
            // §3.4.5, as the SOURCE wrote it. Elaboration turns a flattened
            // child's `parameter` into a `localparam` carrying its override, so
            // the flat row's `is_local` describes the flatten and not the
            // declaration; the definition still has the declaration. §11.6.12
            // NOTE 1 is the same sentence about the value beside it.
            .is_local = declaredLocal(scopes.items[split.scope].decl, file, split.local) orelse p.is_local,
            .value = if (lowered.consts.get(flat_name)) |c| switch (c) {
                .str => |text| .{ .str = try arena.dupe(u8, text) },
                else => c,
            } else null,
        });
    }
    try addModuleArrays(gpa, arena, &objects, scopes.items, top_name);

    try freeze(&d, objects.items, scopes.items);
    return d;
}

/// The model's fixed arrays, from what a builder accumulated. `objects` must
/// hold the modules first and in scope order — the `Scope` invariant.
fn freeze(d: *Design, objects: []const Obj, scopes: []const Building) Error!void {
    const gpa = d.gpa;
    const arena = d.arena.allocator();
    d.objects = try gpa.dupe(Obj, objects);
    d.scopes = try gpa.alloc(Scope, scopes.len);
    for (scopes, 0..) |*s, i| d.scopes[i] = .{
        .parent = s.parent,
        .def_name = s.def_name,
        .path = s.path,
        .children = try arena.dupe(u32, s.children.items),
        .ports = try arena.dupe(u32, s.ports.items),
        .nets = try arena.dupe(u32, s.nets.items),
        .regs = try arena.dupe(u32, s.regs.items),
        .params = try arena.dupe(u32, s.params.items),
        .integers = try arena.dupe(u32, s.integers.items),
        .reals = try arena.dupe(u32, s.reals.items),
        .reg_arrays = try arena.dupe(u32, s.reg_arrays.items),
        .module_arrays = try arena.dupe(u32, s.module_arrays.items),
    };
    d.top_modules = try arena.dupe(u32, &[_]u32{0});
    // A constant has no name to be found by; everything else does.
    for (d.objects, 0..) |o, i| if (o.kind != .constant) try d.by_name.put(gpa, o.full, @intCast(i));
}

/// §11.6.10/§11.6.11: an array object and, after it, each element preceded by
/// the constant its `vpiIndex` leads to — elements in increasing index. The
/// digital engine stores element `addr` in `base + (addr - low)`
/// (`digital.Run.arrays`), which is the slot given each element here.
fn addArray(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    objects: *std.ArrayList(Obj),
    kind: Kind,
    owner: u32,
    name: []const u8,
    full: []const u8,
    ty: Ast.Type,
    low: i64,
    high: i64,
    width: u32,
    base: ?u32,
) Error!u32 {
    const at: u32 = @intCast(objects.items.len);
    const count: u32 = @intCast(high - low + 1);
    const members = try arena.alloc(u32, count);
    try objects.append(gpa, .{ .kind = kind, .owner = owner, .name = name, .full = full, .size = count, .ty = ty, .members = members });
    const elem: Kind = if (kind == .reg_array) .word else .var_select;
    for (0..count) |k| {
        const addr = low + @as(i64, @intCast(k));
        const c: u32 = @intCast(objects.items.len);
        try objects.append(gpa, .{ .kind = .constant, .owner = owner, .name = "", .full = "", .size = 32, .value = .{ .int = addr } });
        members[k] = @intCast(objects.items.len);
        const local = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, addr });
        try objects.append(gpa, .{
            .kind = elem,
            .owner = owner,
            .name = local,
            .full = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ full, addr }),
            .size = width,
            .ty = ty,
            .slot = if (base) |b| b + @as(u32, @intCast(k)) else null,
            .parent = at,
            .index = c,
        });
    }
    return at;
}

/// §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`:
/// elaboration names each element `u[k]`, so sibling scopes that share the
/// identifier before `[` are one array. The array object goes in the parent
/// scope, and every member module learns its array and its index.
fn addModuleArrays(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *std.ArrayList(Obj), scopes: []Building, top_name: []const u8) Error!void {
    for (scopes, 0..) |*parent, p| {
        var i: usize = 0;
        while (i < parent.children.items.len) : (i += 1) {
            const first = parent.children.items[i];
            const name = arrayBase(lastComponent(scopes[first].path)) orelse continue;
            // Already grouped under an earlier sibling?
            if (objects.items[first].parent != null) continue;
            var members: std.ArrayList(u32) = .empty;
            defer members.deinit(gpa);
            for (parent.children.items[i..]) |c| {
                const other = arrayBase(lastComponent(scopes[c].path)) orelse continue;
                if (std.mem.eql(u8, other, name)) try members.append(gpa, c);
            }
            std.mem.sort(u32, members.items, scopes, struct {
                fn lt(s: []Building, a: u32, b: u32) bool {
                    return scopeIndex(s, a) < scopeIndex(s, b);
                }
            }.lt);
            const at: u32 = @intCast(objects.items.len);
            const path = if (parent.path.len == 0) name else try joinPath(arena, parent.path, name);
            try objects.append(gpa, .{
                .kind = .module_array,
                .owner = @intCast(p),
                .name = name,
                .full = try joinPath(arena, top_name, path),
                .size = @intCast(members.items.len),
                .members = try arena.dupe(u32, members.items),
            });
            try parent.module_arrays.append(gpa, at);
            for (members.items) |m| {
                const c: u32 = @intCast(objects.items.len);
                try objects.append(gpa, .{ .kind = .constant, .owner = @intCast(p), .name = "", .full = "", .size = 32, .value = .{ .int = scopeIndex(scopes, m) } });
                objects.items[m].parent = at;
                objects.items[m].index = c;
            }
        }
    }
}

fn scopeIndex(scopes: []Building, m: u32) i64 {
    return arrayIndex(lastComponent(scopes[m].path)).?;
}

/// `u` of `u[3]`, or null when the name is not an array element's.
fn arrayBase(local: []const u8) ?[]const u8 {
    if (local.len < 3 or local[local.len - 1] != ']') return null;
    const open_at = std.mem.lastIndexOfScalar(u8, local, '[') orelse return null;
    _ = arrayIndex(local) orelse return null;
    return local[0..open_at];
}

fn arrayIndex(local: []const u8) ?i64 {
    const open_at = std.mem.lastIndexOfScalar(u8, local, '[') orelse return null;
    if (local[local.len - 1] != ']') return null;
    return std.fmt.parseInt(i64, local[open_at + 1 .. local.len - 1], 10) catch null;
}

/// A declared unpacked dimension, folded when both bounds are literal integers
/// — the same rule `packedWidth` applies. Null otherwise: the array is then
/// not modelled rather than modelled with a guessed size.
fn literalDim(file: *const Ast.SourceFile, dim: Ast.Dim) ?struct { low: i64, high: i64 } {
    if (file.exprs.tag(dim.msb) != .int_literal or file.exprs.tag(dim.lsb) != .int_literal) return null;
    const a = file.exprs.intValue(dim.msb);
    const b = file.exprs.intValue(dim.lsb);
    return .{ .low = @min(a, b), .high = @max(a, b) };
}

// ---------------------------------------------------------------------------
// The model over a running digital design
//
// `open` models an ANALOG compile, whose values live in a device this process
// never runs. A digital design runs HERE, in `src/sim`'s engine, so its model
// can carry values: every net, reg and integer object is bound to the engine
// slot that stores it (`Obj.slot`), which is what §12.16/§12.30 and
// cbValueChange read and write through.
//
// The SHAPE is the engine's own elaboration, read back rather than redone:
// `digital.Run` numbers instance scopes in depth-first pre-order (the root is
// 0, and each child's scope is minted just before its body is declared), and
// keys every declared name by (scope, name). Walking the same definitions in
// the same order yields the same scope numbers, so `Run.names` answers each
// declaration's slot and nothing here decides what an instance IS.
// ---------------------------------------------------------------------------

/// Build the object model over an elaborated digital run and install it. The
/// run must outlive the model: object values are read from `run.values`.
pub fn openDigital(gpa: std.mem.Allocator, r: *sim.digital.Run) !void {
    if (design != null) close();
    design = try buildDigital(gpa, r);
    run.attach(r);
}

/// §6.2.2: the root is the description nothing instantiates — the engine's
/// own `pickTop` rule, which elaboration has already enforced to be unique.
fn digitalTop(file: *const Ast.SourceFile) Error!*const Ast.ModuleDecl {
    outer: for (file.modules) |*candidate| {
        if (candidate.is_connect) continue;
        for (file.modules) |other| for (other.instances) |inst| {
            if (inst.module == candidate.name) continue :outer;
        };
        return candidate;
    }
    return error.NotElaborated;
}

fn digitalModule(file: *const Ast.SourceFile, name: Ast.StrId) ?*const Ast.ModuleDecl {
    for (file.modules) |*m| if (m.name == name) return m;
    return null;
}

fn buildDigital(gpa: std.mem.Allocator, r: *sim.digital.Run) Error!Design {
    var d: Design = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .objects = &.{},
        .scopes = &.{},
        .top_modules = &.{},
        .by_name = .empty,
        .iters = .empty,
    };
    errdefer d.deinit();
    const arena = d.arena.allocator();
    const file = r.file;
    const top = try digitalTop(file);
    const top_name = try arena.dupe(u8, file.str(top.name));

    var scopes: std.ArrayList(Building) = .empty;
    defer {
        for (scopes.items) |*s| s.deinit(gpa);
        scopes.deinit(gpa);
    }
    try walkDigital(gpa, arena, r, &scopes, top, null, "");

    var objects: std.ArrayList(Obj) = .empty;
    defer objects.deinit(gpa);
    for (scopes.items, 0..) |s, i| try objects.append(gpa, .{
        .kind = .module,
        .owner = s.parent,
        .scope = @intCast(i),
        .name = if (i == 0) top_name else lastComponent(s.path),
        .full = try joinPath(arena, top_name, s.path),
    });

    for (scopes.items, 0..) |*s, i| {
        const scope: u32 = @intCast(i);
        const m = s.decl;
        for (m.ports, 0..) |p, k| {
            const at = r.names.get(.{ .scope = scope, .str = p.name });
            try s.ports.append(gpa, @intCast(objects.items.len));
            try objects.append(gpa, try digitalObj(r, arena, top_name, s.path, scope, p.name, .port, at));
            objects.items[objects.items.len - 1].direction = p.direction;
            objects.items[objects.items.len - 1].port_index = @intCast(k);
        }
        for (m.nets) |n| {
            const at = r.names.get(.{ .scope = scope, .str = n.name }) orelse continue;
            try s.nets.append(gpa, @intCast(objects.items.len));
            try objects.append(gpa, try digitalObj(r, arena, top_name, s.path, scope, n.name, .net, at));
        }
        for (m.vars) |v| {
            const at = r.names.get(.{ .scope = scope, .str = v.name }) orelse continue;
            // §3.9 arrays: §11.6.11's classes, over the engine's own element
            // slots.
            if (r.arrays.get(at)) |a| {
                const is_reg = v.storage == .reg;
                const local = try arena.dupe(u8, file.str(v.name));
                // §26.6.7: a `real` array is a vpiRealVar with vpiArray set,
                // one of the scope's reals — as the analog model builds it.
                const real = !is_reg and v.ty == .real;
                const arr = try addArray(gpa, arena, &objects, if (is_reg) .reg_array else .var_array, scope, local, try joinPath(arena, top_name, try joinPath(arena, s.path, local)), if (real) .real else .integer, a.low, a.high, r.values[at].width, at);
                try (if (is_reg) &s.reg_arrays else if (real) &s.reals else &s.integers).append(gpa, arr);
                continue;
            }
            const kind: Kind = if (v.storage == .reg) .reg else if (v.ty == .integer) .integer else if (v.ty == .real) .real_var else continue;
            const list = if (kind == .reg) &s.regs else if (kind == .real_var) &s.reals else &s.integers;
            try list.append(gpa, @intCast(objects.items.len));
            try objects.append(gpa, try digitalObj(r, arena, top_name, s.path, scope, v.name, kind, at));
            objects.items[objects.items.len - 1].is_signed = v.is_signed or kind == .integer;
        }
        // §11.6.12 parameters. The engine folds each into a slot of its own
        // (IEEE 1364 §12.2, `Run.params`), so NOTE 1's "final value of the
        // parameter after all module instantiation overrides and defparams
        // have been resolved" is that slot, read like any other value.
        for (m.params) |p| {
            const at = r.names.get(.{ .scope = scope, .str = p.name }) orelse continue;
            if (!r.params.contains(at)) continue;
            try s.params.append(gpa, @intCast(objects.items.len));
            var o = try digitalObj(r, arena, top_name, s.path, scope, p.name, .parameter, at);
            o.ty = p.ty;
            o.is_local = p.is_local;
            try objects.append(gpa, o);
        }
    }
    try addModuleArrays(gpa, arena, &objects, scopes.items, top_name);
    try freeze(&d, objects.items, scopes.items);
    return d;
}

/// One declared name of `scope`, bound to the slot `at` that stores it.
fn digitalObj(
    r: *const sim.digital.Run,
    arena: std.mem.Allocator,
    top_name: []const u8,
    path: []const u8,
    scope: u32,
    name: Ast.StrId,
    kind: Kind,
    at: ?u32,
) Error!Obj {
    const local = try arena.dupe(u8, r.file.str(name));
    return .{
        .kind = kind,
        .owner = scope,
        .name = local,
        .full = try joinPath(arena, top_name, try joinPath(arena, path, local)),
        .size = if (at) |a| r.values[a].width else 1,
        .slot = at,
    };
}

/// The engine's instance order: this scope, then each child in source order,
/// each child's subtree before the next child.
fn walkDigital(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    r: *const sim.digital.Run,
    scopes: *std.ArrayList(Building),
    m: *const Ast.ModuleDecl,
    parent: ?u32,
    path: []const u8,
) Error!void {
    const file = r.file;
    const at: u32 = @intCast(scopes.items.len);
    try scopes.append(gpa, .{
        .decl = m,
        .def_name = try arena.dupe(u8, file.str(m.name)),
        .path = path,
        .parent = parent,
    });
    if (parent) |p| try scopes.items[p].children.append(gpa, at);
    for (m.instances) |inst| {
        const child = digitalModule(file, inst.module) orelse return error.NotElaborated;
        const name = file.str(inst.name);
        if (inst.range == null) {
            try walkDigital(gpa, arena, r, scopes, child, at, try joinPath(arena, path, name));
            continue;
        }
        // IEEE 1364 §12.1.2: the elements the engine minted for the array,
        // in its order; `addModuleArrays` groups the `u[k]` siblings.
        for (r.scope_info.items) |info| {
            if (info.parent != at or info.lexical or info.name != inst.name) continue;
            const k = info.index orelse continue;
            try walkDigital(gpa, arena, r, scopes, child, at, try joinPath(arena, path, try std.fmt.allocPrint(arena, "{s}[{d}]", .{ name, k })));
        }
    }
}

/// §3.4.5 as the SOURCE wrote it: is `name` a `localparam` of `decl`? `null`
/// when `decl` declares no such parameter, which is the case for a parameter
/// elaboration synthesized rather than copied.
fn declaredLocal(decl: *const Ast.ModuleDecl, file: *const Ast.SourceFile, name: []const u8) ?bool {
    for (decl.params) |p| {
        if (std.mem.eql(u8, file.str(p.name), name)) return p.is_local;
    }
    return null;
}

/// §3.6.3 a vector net is N nets, and §11.6.8's `vpiSize` is that N.
/// `Lowered.vectors` is the folded `[msb:lsb]` keyed by the flat name — the same
/// fold lowering scalarised the net with, so this cannot disagree with the
/// device's terminal count. A name absent from it is a scalar.
fn vectorSize(lowered: *const Lowered, flat_name: []const u8) u32 {
    const r = lowered.vectors.get(flat_name) orelse return 1;
    return @intCast(@abs(r.msb - r.lsb) + 1);
}

/// §11.6.9's `vpiSize` for a `reg [msb:lsb]`.
///
/// ponytail: LITERAL BOUNDS ONLY — which is what `src/sim/digital/root.zig`
/// already requires of the same declaration ("declaration bounds must be
/// literal integers"). A packed range over a parameter folds nowhere this
/// file can reach: `Lowered.vectors` holds nets and ports, not regs. Reporting 1
/// for a width the design knows would be a wrong answer, so a non-literal range
/// reports 0 and `vpi_get(vpiSize, …)` turns that into `vpiUndefined` plus an
/// error. Upgrade path: lowering interns packed regs into `vectors` the way it
/// interns nets, and this function disappears.
fn packedWidth(file: *const Ast.SourceFile, v: Ast.VarDecl) u32 {
    const range = v.packed_range orelse return 1;
    if (file.exprs.tag(range.msb) != .int_literal or file.exprs.tag(range.lsb) != .int_literal) return 0;
    const hi = file.exprs.intValue(range.msb);
    const lo = file.exprs.intValue(range.lsb);
    if (hi < 0 or lo < 0) return 0;
    return @intCast(@abs(hi - lo) + 1);
}

/// §6.7 join: `parent` and `local` with `Elaborate.sep` between them, or just
/// `local` when `parent` is the empty root path. `vpiFullName` is this applied
/// once more with the top module's own name on the left, which is the form
/// §12.21's own example passes (`vpi_handle_by_name("top.mod1", …)`).
fn joinPath(arena: std.mem.Allocator, parent: []const u8, local: []const u8) Error![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, local);
    if (local.len == 0) return arena.dupe(u8, parent);
    return std.fmt.allocPrint(arena, "{s}{c}{s}", .{ parent, Elaborate.sep, local });
}

fn lastComponent(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, Elaborate.sep) orelse return path;
    return path[at + 1 ..];
}

/// Split a flattened declaration's name into the scope it belongs to and the
/// §11.6 `vpiName` inside it.
///
/// The last `Elaborate.sep` is the split, and that is exact rather than a
/// heuristic: §6.6 generate blocks add no path component in this compiler (they
/// unroll inside a body, not into the declaration space), and `parser.internTok`
/// substitutes a space for a period inside a §2.8.1 escaped identifier — so a
/// period in a flattened name IS a join.
/// `tests/fixtures/ch06_hierarchy/escaped_period_is_not_a_path.va` is the
/// fixture on that substitution.
fn splitPath(
    arena: std.mem.Allocator,
    by_path: *const std.StringHashMapUnmanaged(u32),
    flat: []const u8,
) Error!?struct { scope: u32, local: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, flat, Elaborate.sep);
    const path = if (at) |i| flat[0..i] else "";
    const scope = by_path.get(path) orelse return null;
    return .{ .scope = scope, .local = try arena.dupe(u8, if (at) |i| flat[i + 1 ..] else flat) };
}

// ---------------------------------------------------------------------------
// §12.2 error status
//
// "The error status shall be reset by any VPI routine call except
// vpi_chk_error()." So every entry point below opens with `clearError()`, and
// `vpi_chk_error` does not.
// ---------------------------------------------------------------------------

var err_level: c_int = 0;
var err_code: [:0]const u8 = "";
var err_buf: [512]u8 = undefined;
var err_len: usize = 0;

/// Figure 12-1's `product`. Static, NUL-terminated, never rewritten.
var product_name = "VerA".*;

pub fn clearError() void {
    err_level = 0;
    err_len = 0;
    err_code = "";
}

/// Record one error. The caller returns its own documented failure value.
///
/// `code` is a short stable token — the application's `s_vpi_error_info.code` —
/// and the message is the human half. Both live in static storage until the
/// next VPI call, which is the lifetime Figure 12-1 gives them.
///
/// ponytail: a fixed 512-byte message, truncating. The message is diagnostic
/// text; an application being told it passed an invalid handle needs the code
/// and the first clause far more than the last few words, and a heap allocation
/// on the error path is a second thing that can fail while reporting a failure.
pub fn fail(code: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    err_level = vpiError;
    err_code = code;
    const written = std.fmt.bufPrint(err_buf[0 .. err_buf.len - 1], fmt, args) catch
        err_buf[0 .. err_buf.len - 1];
    err_len = written.len;
    err_buf[err_len] = 0;
}

// ---------------------------------------------------------------------------
// Handle validation — the trust boundary
//
// Every `vpiHandle` below arrived from C. None is dereferenced until it has
// been shown to be one VerA issued:
//
//   an object   lands inside `objects`, on an element boundary
//   an iterator is a key of `iters` — the set of ones we allocated and have
//               not freed
//
// A stale OBJECT handle, one whose design has been closed and reopened, is
// caught by the first test: the array it pointed into was freed and the new one
// is a different allocation. A stale ITERATOR handle is caught by the second,
// because `vpi_scan` and `vpi_free_object` remove the key before destroying the
// object. Neither path reads through the pointer first.
//
// This is deliberately not a magic number in a header struct: a magic number
// has to be READ, and reading is the thing an arbitrary pointer must not have
// done to it.
// ---------------------------------------------------------------------------

pub fn asObj(h: vpiHandle) ?*Obj {
    const d = &(design orelse return null);
    const p = h orelse return null;
    if (d.objects.len == 0) return null;
    const base = @intFromPtr(d.objects.ptr);
    const addr = @intFromPtr(p);
    if (addr < base) return null;
    const off = addr - base;
    if (off >= d.objects.len * @sizeOf(Obj)) return null;
    if (off % @sizeOf(Obj) != 0) return null;
    return &d.objects[off / @sizeOf(Obj)];
}

fn asIter(h: vpiHandle) ?*Iter {
    const d = &(design orelse return null);
    const p = h orelse return null;
    return d.iters.get(@intFromPtr(p));
}

fn handleOf(o: *Obj) vpiHandle {
    return @ptrCast(o);
}

/// How an invalid handle is named in a message. Never dereferences it.
fn describe(h: vpiHandle) []const u8 {
    return if (h == null) "NULL" else "that handle";
}

/// Every routine but `vpi_chk_error` starts here: §12.2 "the error status
/// shall be reset by any VPI routine call", and no routine has an answer
/// without an open design. Null means the error is recorded; the caller
/// returns its own documented failure value.
inline fn enter(comptime who: []const u8) ?*Design {
    clearError();
    if (design) |*d| return d;
    fail("NODESIGN", who ++ ": no design is open", .{});
    return null;
}

/// `h` as an object VerA issued, or null with the error recorded.
inline fn object(comptime who: []const u8, h: vpiHandle) ?*Obj {
    if (asObj(h)) |o| return o;
    fail("BADHANDLE", who ++ ": {s} is not a handle to an object", .{describe(h)});
    return null;
}

// ---------------------------------------------------------------------------
// §12.19 vpi_handle — one-to-one traversal
// ---------------------------------------------------------------------------

/// "Return the object of type `type` associated with object `ref`."
///
/// Two tags are answered and they name the same edge read from two diagrams:
/// `vpiScope` is §11.6.12's "scope has a double-headed relationship with the
/// parameter object", `vpiModule` is §11.6.4's "ports has a one-to-one
/// relationship back to module". A module's own containing scope is its parent
/// instance, and the top module has none — NULL, and NOT an error: "no such
/// object" is this routine's ordinary answer at the root of the hierarchy.
pub export fn vpi_handle(obj_type: c_int, ref: vpiHandle) vpiHandle {
    // §11.6.16 NOTE 1: the call whose compiletf/calltf is running. None ever
    // is in this process (see systf.zig), so the answer is "no such object",
    // which is NULL and not an error — the same answer vpiScope gives at the
    // root.
    if (obj_type == systf.vpiSysTfCall and ref == null) {
        clearError();
        return null;
    }
    const d = enter("vpi_handle") orelse return null;
    const o = object("vpi_handle", ref) orelse return null;
    switch (obj_type) {
        vpiScope, vpiModule => {
            const owner = o.owner orelse return null;
            return handleOf(&d.objects[owner]);
        },
        // §11.6.11: a word or variable select's array. A module in an
        // instance array reaches its array by vpiModuleArray (§26.6.1).
        vpiParent, vpiModuleArray => {
            if (obj_type == vpiParent and o.kind != .word and o.kind != .var_select) return noEdge(obj_type, o);
            if (obj_type == vpiModuleArray and o.kind != .module) return noEdge(obj_type, o);
            const p = o.parent orelse return null;
            return handleOf(&d.objects[p]);
        },
        // The index expression of an element. A module that is not in an
        // array has none, and that is an answer — NULL — not an error.
        vpiIndex => {
            switch (o.kind) {
                .word, .var_select, .module => {},
                else => return noEdge(obj_type, o),
            }
            const c = o.index orelse return null;
            return handleOf(&d.objects[c]);
        },
        else => {
            fail("NOTRAVERSE", "vpi_handle: no one-to-one relationship {d} from a {s}", .{ obj_type, @tagName(o.kind) });
            return null;
        },
    }
}

fn noEdge(obj_type: c_int, o: *const Obj) vpiHandle {
    fail("NOTRAVERSE", "vpi_handle: a {s} has no relationship {d}", .{ @tagName(o.kind), obj_type });
    return null;
}

// ---------------------------------------------------------------------------
// §12.21 vpi_handle_by_name
// ---------------------------------------------------------------------------

/// "The name can be hierarchical or simple. If `scope` is NULL, then `name`
/// shall be searched for from the top level of hierarchy. Otherwise, `name`
/// shall be searched for from `scope` using the scope search rules defined by
/// the Verilog-AMS HDL."
///
/// §6.7's search rule is upward: a name not found in the enclosing scope is
/// looked for in ITS parent, and so on to the top. That loop is the whole of
/// the `scope != NULL` arm. With a NULL scope the name is absolute and matched
/// against `vpiFullName` — the property §12.21 says the routine "can be applied
/// to all objects with".
pub export fn vpi_handle_by_name(name: [*c]const u8, scope: vpiHandle) vpiHandle {
    const d = enter("vpi_handle_by_name") orelse return null;
    if (name == null) {
        fail("BADNAME", "vpi_handle_by_name: the name is NULL", .{});
        return null;
    }
    const want = std.mem.span(name);
    if (scope) |s| {
        const from = object("vpi_handle_by_name", s) orelse return null;
        // §6.7's upward search. `scope` need not be a module: the scope of a
        // non-module object is the one it is declared in, and the scope of a
        // module is itself.
        var at: ?u32 = if (from.kind == .module) from.scope else from.owner;
        while (at) |sc| : (at = d.scopes[sc].parent) {
            var buf: [name_buf_len]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ d.objects[sc].full, Elaborate.sep, want }) catch continue;
            if (d.by_name.get(full)) |i| return handleOf(&d.objects[i]);
        }
        // The search ends at the top, where a hierarchical name is an absolute
        // one: `vpi_handle_by_name("top.u.k", any_scope)` is §12.21's
        // "hierarchical" spelling and resolves as it would with a NULL scope.
        if (d.by_name.get(want)) |i| return handleOf(&d.objects[i]);
        fail("NONAME", "vpi_handle_by_name: `{s}` names no object from that scope", .{want});
        return null;
    }
    if (d.by_name.get(want)) |i| return handleOf(&d.objects[i]);
    fail("NONAME", "vpi_handle_by_name: `{s}` names no object in the design", .{want});
    return null;
}

/// Bound on a §6.7 name, both for the upward search above and for
/// `vpi_get_str`'s §12.12 buffer.
///
/// ponytail: 4 KiB, truncating. That is far past what a 64-deep instance tree
/// (`Elaborate.max_depth`) makes out of §2.8 identifiers. In the search a name
/// that overflows simply fails that one scope's attempt and the walk continues,
/// so the ceiling costs a lookup rather than correctness. Upgrade path: `open`
/// already sees every `vpiFullName`, so it could size this from the longest.
pub const name_buf_len = 4096;

// ---------------------------------------------------------------------------
// §12.20 vpi_handle_by_index
// ---------------------------------------------------------------------------

/// "Return a handle to an object based on the index number of the object within
/// a parent object. ... This function can be used to access all objects which
/// can access an expression using `vpiIndex`."
///
/// The indexed objects are the §11.6.11 array elements — memory words and
/// variable selects — and the members of a §6.2.2 instance array: "for a memory
/// word, obj is the associated memory". `index` is the element's own declared
/// index, the value its vpiIndex constant holds.
///
/// ponytail: BIT-LEVEL objects (net bit, reg bit, port bit) are not modelled,
/// so indexing a vector is still §12.2's error indication. Each would need
/// §11.6.5's `vpiIndex` expr and its own properties; `Lowered.vectors` already
/// holds the folded `[msb:lsb]` they would need.
pub export fn vpi_handle_by_index(obj: vpiHandle, index: c_int) vpiHandle {
    const d = enter("vpi_handle_by_index") orelse return null;
    const o = object("vpi_handle_by_index", obj) orelse return null;
    if (o.members.len != 0) {
        for (o.members) |m| {
            const c = d.objects[m].index orelse continue;
            if (d.objects[c].value.?.int == index) return handleOf(&d.objects[m]);
        }
        fail("NOINDEX", "vpi_handle_by_index: `{s}` has no element {d}", .{ o.full, index });
        return null;
    }
    fail(
        "NOINDEX",
        "vpi_handle_by_index: a {s} has no indexed object at {d} — bit-level objects are not modelled",
        .{ @tagName(o.kind), index },
    );
    return null;
}

// ---------------------------------------------------------------------------
// §12.23 vpi_iterate / §12.35 vpi_scan
// ---------------------------------------------------------------------------

/// "If there are no objects of type `type` associated with the reference handle
/// `ref`, then `vpi_iterate()` shall return NULL."
///
/// So an EMPTY set and an UNSUPPORTED relationship have the same return value,
/// and the difference between them is the error status: a module with no regs
/// is NULL with no error, `vpi_iterate(vpiPort, some_net)` is NULL with one. An
/// application that does not check errors sees the documented empty loop either
/// way; one that does can tell a fact about the design from a limit of VerA's.
pub export fn vpi_iterate(obj_type: c_int, ref: vpiHandle) vpiHandle {
    const d = enter("vpi_iterate") orelse return null;
    // §11.6.1 NOTE 1: "Top-level modules shall be accessed using vpi_iterate()
    // with a NULL reference object."
    if (ref == null) {
        if (obj_type == systf.vpiUserSystf) {
            const handles = systf.all(d.gpa) catch {
                fail("NOMEM", "vpi_iterate: out of memory", .{});
                return null;
            };
            if (handles.len == 0) {
                d.gpa.free(handles);
                return null;
            }
            return newHandleIter(d, handles);
        }
        if (obj_type == run.vpiTimeQueue) {
            const handles = run.timeQueues(d.gpa) catch {
                fail("NOMEM", "vpi_iterate: out of memory", .{});
                return null;
            };
            if (handles.len == 0) {
                d.gpa.free(handles);
                return null;
            }
            return newHandleIter(d, handles);
        }
        if (obj_type != vpiModule) {
            fail("NOTRAVERSE", "vpi_iterate: only vpiModule and vpiTimeQueue are iterable from a NULL reference, not {d}", .{obj_type});
            return null;
        }
        return newIter(d, d.top_modules);
    }
    const o = object("vpi_iterate", ref) orelse return null;
    // §11.6.11 (IEEE 1364 §26.6.7-9): an array's elements. A memory's words by
    // the legacy vpiMemoryWord tag or as vpiReg; a variable array's by
    // vpiVarSelect; an instance array's members by vpiModule.
    const elements: bool = switch (o.kind) {
        .reg_array => obj_type == vpiMemoryWord or obj_type == vpiReg,
        .var_array => obj_type == vpiVarSelect,
        .module_array => obj_type == vpiModule,
        else => false,
    };
    if (elements) return newIter(d, o.members);
    if (o.kind != .module) {
        fail("NOTRAVERSE", "vpi_iterate: a {s} is the reference object of no one-to-many relationship {d}", .{ @tagName(o.kind), obj_type });
        return null;
    }
    const s = &d.scopes[o.scope];
    const items: []const u32 = switch (obj_type) {
        // §11.6.1 gives module a one-to-many to `scope` tagged vpiInternalScope
        // AND a separate one to `module`. In a design whose only named scopes
        // are instances these are the same set, and answering both tags with it
        // is what lets an application written either way walk.
        vpiModule, vpiInternalScope => s.children,
        vpiPort => s.ports,
        vpiNet => s.nets,
        vpiReg => s.regs,
        vpiParameter => s.params,
        vpiIntegerVar => s.integers,
        vpiRealVar => s.reals,
        // IEEE 1364 §26.6.9: the legacy vpiMemory method returns the reg
        // arrays, as vpiRegArray objects.
        vpiMemory, vpiRegArray => s.reg_arrays,
        vpiModuleArray => s.module_arrays,
        else => {
            fail("NOTRAVERSE", "vpi_iterate: no one-to-many relationship {d} from a module", .{obj_type});
            return null;
        },
    };
    if (items.len == 0) return null;
    return newIter(d, items);
}

/// An iterator over `handles`, which it takes ownership of.
fn newHandleIter(d: *Design, handles: []vpiHandle) vpiHandle {
    const h = newIter(d, &.{});
    if (asIter(h)) |it| it.handles = handles else d.gpa.free(handles);
    return h;
}

fn newIter(d: *Design, items: []const u32) vpiHandle {
    const it = d.gpa.create(Iter) catch {
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    it.* = .{ .items = items };
    d.iters.put(d.gpa, @intFromPtr(it), it) catch {
        d.gpa.destroy(it);
        fail("NOMEM", "vpi_iterate: out of memory", .{});
        return null;
    };
    return @ptrCast(it);
}

/// "Once `vpi_scan()` returns NULL, the iterator handle is no longer valid and
/// can not be used again" (§12.35), and §12.4 spells out the consequence: "The
/// iterator object shall automatically be freed when vpi_scan() returns NULL".
///
/// So exhaustion FREES, and the freed handle is then exactly the invalid handle
/// the validation above rejects. That is the point of doing it this way: an
/// application that scans a dead iterator gets an error, not a use-after-free.
pub export fn vpi_scan(itr: vpiHandle) vpiHandle {
    const d = enter("vpi_scan") orelse return null;
    const it = asIter(itr) orelse {
        fail("BADHANDLE", "vpi_scan: {s} is not a handle to a live iterator", .{describe(itr)});
        return null;
    };
    if (it.handles) |hs| {
        if (it.at >= hs.len) {
            destroyIter(d, it);
            return null;
        }
        it.at += 1;
        return hs[it.at - 1];
    }
    if (it.at >= it.items.len) {
        destroyIter(d, it);
        return null;
    }
    const idx = it.items[it.at];
    it.at += 1;
    return handleOf(&d.objects[idx]);
}

fn destroyIter(d: *Design, it: *Iter) void {
    _ = d.iters.remove(@intFromPtr(it));
    if (it.handles) |hs| d.gpa.free(hs);
    d.gpa.destroy(it);
}

// ---------------------------------------------------------------------------
// §12.5 vpi_get
// ---------------------------------------------------------------------------

/// "Should an error occur, `vpi_get()` shall return `vpiUndefined`."
///
/// Every property below is one §11.6 lists for the class it is asked of. Asking
/// for a property a class does not have — `vpiDirection` of a net, `vpiSize` of
/// a module — is an error and not a zero: §11.6.8 simply gives a net no
/// direction, and a 0 would be indistinguishable from `vpiNoDirection`.
pub export fn vpi_get(prop: c_int, obj: vpiHandle) c_int {
    // Not `enter`: callbacks, time queues, events and systf registrations are
    // objects without a design, and a handle to one still has a type.
    clearError();
    // §12.23 types the iterator `vpiIterator`, so `vpi_get(vpiType, itr)` is a
    // question with an answer. Nothing else about an iterator is a §11.6
    // property.
    if (asIter(obj)) |_| {
        if (prop == vpiType) return vpiIterator;
        fail("NOPROP", "vpi_get: an iterator has no property {d}", .{prop});
        return vpiUndefined;
    }
    // §11.6.25's callback object has a type and nothing else §11.6 lists.
    if (callback.asCb(obj)) |_| {
        if (prop == vpiType) return callback.vpiCallback;
        fail("NOPROP", "vpi_get: a callback has no property {d}", .{prop});
        return vpiUndefined;
    }
    // §12.30's vpiSchedEvent: a type, and whether it is still to happen.
    if (value.asEvent(obj)) |e| {
        if (prop == vpiType) return value.vpiSchedEvent;
        if (prop == value.vpiScheduled) return @intFromBool(value.scheduled(e));
        fail("NOPROP", "vpi_get: a scheduled event has no property {d}", .{prop});
        return vpiUndefined;
    }
    if (systf.asSystf(obj)) |_| {
        if (prop == vpiType) return systf.vpiUserSystf;
        fail("NOPROP", "vpi_get: a vpiUserSystf has no property {d}; vpi_get_systf_info reads it", .{prop});
        return vpiUndefined;
    }
    if (run.asQueue(obj)) |_| {
        if (prop == vpiType) return run.vpiTimeQueue;
        fail("NOPROP", "vpi_get: a time queue has no property {d}; vpi_get_time reads its time", .{prop});
        return vpiUndefined;
    }
    // §12.5's NULL-object case is about vpiTimeUnit/vpiTimePrecision, neither of
    // which VerA answers, so a NULL object is an invalid handle like any other.
    const o = object("vpi_get", obj) orelse return vpiUndefined;
    switch (prop) {
        vpiType => return typeOf(o),
        // IEEE 1364 §26.6.1/§26.6.7: "is item an array" — an array, or a
        // module that is a member of an instance array.
        vpiArray => return switch (o.kind) {
            .reg_array, .var_array => 1,
            .module => @intFromBool(o.parent != null),
            .reg, .integer, .real_var, .word, .var_select => 0,
            else => propFail(prop, o),
        },
        vpiIsMemory => return switch (o.kind) {
            .reg_array => 1,
            .var_array, .reg => 0,
            else => propFail(prop, o),
        },
        // §11.6.1 — true for the root of the instance tree, the one module
        // `Elaborate.pickTop` chose.
        vpiTopModule => {
            if (o.kind != .module) return propFail(prop, o);
            return @intFromBool(o.owner == null);
        },
        vpiSize, vpiScalar, vpiVector => {
            // An array's size counts ELEMENTS (§26.6.9 "array size counts
            // members"), everything else's counts bits.
            switch (o.kind) {
                .reg_array, .var_array, .module_array => if (prop == vpiSize) return @intCast(o.size) else return propFail(prop, o),
                .port, .net, .reg, .integer, .real_var, .word, .var_select, .constant => {},
                else => return propFail(prop, o),
            }
            // A width of 0 means the declared range did not fold (see
            // `packedWidth`): unknown, which is not the same as zero-width.
            if (o.size == 0) {
                fail("NOFOLD", "vpi_get: the declared range of `{s}` is not a constant this model folded", .{o.full});
                return vpiUndefined;
            }
            // §11.6.4 NOTE 3: scalar and vector are about the object's own
            // width and "shall not indicate anything about what is connected".
            return switch (prop) {
                vpiSize => @intCast(o.size),
                vpiScalar => @intFromBool(o.size == 1),
                else => @intFromBool(o.size > 1),
            };
        },
        vpiDirection => {
            if (o.kind != .port) return propFail(prop, o);
            // §6.5.2.2. `.unspecified` is a port named in the header whose
            // direction declaration never arrived — §11.6.4's `vpiNoDirection`,
            // which is an answer rather than a missing one.
            return switch (o.direction) {
                .input => vpiInput,
                .output => vpiOutput,
                .inout => vpiInout,
                .unspecified => vpiNoDirection,
            };
        },
        vpiPortIndex => {
            if (o.kind != .port) return propFail(prop, o);
            return @intCast(o.port_index);
        },
        vpiLocalParam => {
            if (o.kind != .parameter) return propFail(prop, o);
            return @intFromBool(o.is_local);
        },
        // §11.6.12 `vpiConstType` over §3.4.1's parameter types. `.unspecified`
        // is a `parameter p = <expr>;` whose type lowering derives from the
        // default — a question about a VALUE, which is P02's.
        vpiConstType => {
            if (o.kind == .constant) return vpiDecConst;
            if (o.kind != .parameter) return propFail(prop, o);
            return switch (o.ty) {
                .real => vpiRealConst,
                .integer => vpiIntConst,
                .string => vpiStringConst,
                .unspecified => {
                    fail("NOTYPE", "vpi_get: `{s}` has no declared type; its constant type follows its value", .{o.full});
                    return vpiUndefined;
                },
            };
        },
        vpiSigned => {
            if (o.kind != .reg and o.kind != .integer) return propFail(prop, o);
            return @intFromBool(o.is_signed);
        },
        else => {
            fail("NOPROP", "vpi_get: property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return vpiUndefined;
        },
    }
}

fn propFail(prop: c_int, o: *const Obj) c_int {
    fail("NOPROP", "vpi_get: a {s} has no property {d}", .{ @tagName(o.kind), prop });
    return vpiUndefined;
}

// ---------------------------------------------------------------------------
// §12.12 vpi_get_str
// ---------------------------------------------------------------------------

/// "The string shall be placed in a temporary buffer which shall be used by
/// every call to this routine. If the string is to be used after a subsequent
/// call, the string needs to be copied to another location."
///
/// One buffer, reused, exactly as written — which is also why the model stores
/// names unterminated: the copy into this buffer is required whatever the
/// storage is, so a second NUL would buy nothing.
///
/// A failing call returns NULL. §12.12 does not say so in as many words; it is
/// the only value that is not a string an application would go on to print.
pub export fn vpi_get_str(prop: c_int, obj: vpiHandle) [*c]u8 {
    const d = enter("vpi_get_str") orelse return null;
    const o = object("vpi_get_str", obj) orelse return null;
    const s: []const u8 = switch (prop) {
        vpiName => o.name,
        vpiFullName => o.full,
        vpiType => typeName(typeOf(o)),
        // §11.6.1 — a module property and only a module's. A net has no
        // definition to name.
        vpiDefName => blk: {
            if (o.kind != .module) {
                fail("NOPROP", "vpi_get_str: a {s} has no vpiDefName", .{@tagName(o.kind)});
                return null;
            }
            break :blk d.scopes[o.scope].def_name;
        },
        else => {
            fail("NOPROP", "vpi_get_str: string property {d} is not answered for a {s}", .{ prop, @tagName(o.kind) });
            return null;
        },
    };
    const n = @min(s.len, str_buf.len - 1);
    @memcpy(str_buf[0..n], s[0..n]);
    str_buf[n] = 0;
    return @ptrCast(&str_buf);
}

/// §12.12's single shared buffer. See `name_buf_len` for the ceiling.
var str_buf: [name_buf_len]u8 = undefined;

// ---------------------------------------------------------------------------
// §12.3 vpi_compare_objects / §12.4 vpi_free_object
// ---------------------------------------------------------------------------

/// "Handle equivalence can not be determined with a C `==` comparison."
///
/// In VerA it happens to be determinable that way — objects are materialized
/// once — but this routine is what an application is ALLOWED to rely on, and an
/// implementation that interned handles differently would pass the same tests
/// through it. Two invalid handles are not "the same object": that is FALSE
/// plus an error, not TRUE.
pub export fn vpi_compare_objects(obj1: vpiHandle, obj2: vpiHandle) c_int {
    clearError();
    const a = issued(obj1) orelse {
        fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj1)});
        return 0;
    };
    const b = issued(obj2) orelse {
        fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj2)});
        return 0;
    };
    return @intFromBool(a == b);
}

/// The identity of a handle VerA issued, object or iterator (§12.23 gives an
/// iterator the type `vpiIterator`, so it is an object too). Erased to
/// `*anyopaque` because identity is all `vpi_compare_objects` reads.
fn issued(h: vpiHandle) ?*anyopaque {
    if (asObj(h)) |o| return @ptrCast(o);
    if (asIter(h)) |it| return @ptrCast(it);
    if (callback.asCb(h)) |cb| return @ptrCast(cb);
    if (run.asQueue(h)) |q| return @ptrCast(q);
    if (value.asEvent(h)) |e| return @ptrCast(e);
    if (systf.asSystf(h)) |s| return @ptrCast(s);
    return null;
}

/// "It shall generally be used to free memory created for iterator objects. ...
/// This routine can also optionally be used for implementations which have to
/// allocate memory for objects."
///
/// Freeing an ITERATOR is real work: an application that broke out of a scan
/// loop early leaks one otherwise, which is the case §12.4 is written for.
/// Freeing an OBJECT is a no-op returning TRUE — objects are owned by the
/// design and live as long as it does — because an application is entitled to
/// call this on one and must not be told it failed.
pub export fn vpi_free_object(obj: vpiHandle) c_int {
    clearError();
    if (asIter(obj)) |it| {
        destroyIter(&design.?, it);
        return 1;
    }
    // A callback handle is freed by vpi_remove_cb (§12.34), not here; freeing
    // the handle leaves the callback registered, as an object's does.
    if (asObj(obj) != null or callback.asCb(obj) != null or run.asQueue(obj) != null or systf.asSystf(obj) != null) return 1;
    // §12.30 "Calling vpi_free_object() on the handle shall free the handle
    // but shall not effect the event."
    if (value.asEvent(obj)) |e| {
        value.freeEvent(e);
        return 1;
    }
    fail("BADHANDLE", "vpi_free_object: {s} is not a handle VerA issued", .{describe(obj)});
    return 0;
}

/// IEEE 1364-2005's later spelling of `vpi_free_object`, introduced because
/// "free object" reads as though it destroyed the design object rather than the
/// handle to it. Same contract, and deliberately the same body rather than a
/// second one that could drift from it.
pub export fn vpi_release_handle(obj: vpiHandle) c_int {
    return vpi_free_object(obj);
}

// ---------------------------------------------------------------------------
// §12.2 vpi_chk_error
// ---------------------------------------------------------------------------

/// "Shall return an integer constant representing an error severity level if
/// the previous call to a VPI routine resulted in an error ... The error status
/// shall be reset by any VPI routine call except vpi_chk_error(). Calling
/// vpi_chk_error() shall have no effect on the error status."
///
/// So this is the one routine that does NOT clear the status, and it is
/// idempotent: an application may call it twice and get the same answer.
/// "If the error information is not needed, a NULL can be passed to the
/// routine."
pub export fn vpi_chk_error(error_info_p: ?*ErrorInfo) c_int {
    if (error_info_p) |info| {
        info.* = .{
            // Table 12-1's companion field. Every error VerA raises is raised
            // from an application's own call into it, which is `vpiPLI`;
            // `vpiCompile` and `vpiRun` belong to errors a simulator raises
            // outside a VPI call, and there is no such path into this file.
            .state = vpiPLI,
            .level = err_level,
            .message = if (err_len == 0) null else @ptrCast(&err_buf),
            .product = @ptrCast(&product_name),
            .code = if (err_code.len == 0) null else @constCast(err_code.ptr),
            // The APPLICATION's call site. C gives a callee no caller location,
            // so these are reported absent rather than invented.
            .file = null,
            .line = 0,
        };
    }
    return err_level;
}

// ---------------------------------------------------------------------------
// §12.17 vpi_get_vlog_info
// ---------------------------------------------------------------------------

/// Figure 12-12 `s_vpi_vlog_info`, laid out for C.
pub const VlogInfo = extern struct {
    argc: c_int,
    argv: [*c][*c]u8,
    product: [*c]u8,
    version: [*c]u8,
};

/// The product's invocation, as its `main` received it. Kept by pointer: the
/// C runtime owns `argv` for the life of the process, which outlives any
/// application's use of it.
var inv_argc: c_int = 0;
var inv_argv: [*c][*c]u8 = null;

/// A host calls this once, from its `main`, before the startup routines run.
/// A host that never does reports an invocation of no options.
pub fn setInvocation(argc: c_int, argv: [*c][*c]u8) void {
    inv_argc = argc;
    inv_argv = argv;
}

/// Figure 12-12's `version`.
///
/// ponytail: written here rather than read from build.zig.zon, which a module
/// under src/ cannot import. Upgrade path: pass the manifest's version to this
/// module as a build option, as `suite_options` passes the fixture root.
var version_str = "0.9.0".*;

/// "shall obtain the following information about Verilog-AMS product
/// execution: The number of invocation options (argc), Invocation option
/// values (argv), Product and version strings ... The routine shall return
/// TRUE on success and FALSE on failure." The one failure an application can
/// cause is having no structure to fill.
pub export fn vpi_get_vlog_info(vlog_info_p: ?*VlogInfo) c_int {
    clearError();
    const out = vlog_info_p orelse {
        fail("BADINFO", "vpi_get_vlog_info: vlog_info_p is NULL", .{});
        return 0;
    };
    out.* = .{
        .argc = inv_argc,
        .argv = inv_argv,
        .product = @ptrCast(&product_name),
        .version = @ptrCast(&version_str),
    };
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
//
// These check the MODEL: that the scope tree, the names and the sets come out
// of an elaborated design correctly, and that the routines' failure paths are
// failure paths. They are NOT the acceptance test. The ABI, the header's
// constants and real C object lifetimes are `zig build test-vpi`, which
// compiles tests/vpi_app.c against src/vpi/vpi_user.h and links it against the
// exports above; a Zig test calling `vpi_handle` only proves that this file
// agrees with itself.
// ---------------------------------------------------------------------------

const vera = @import("vera");

/// A three-deep design with something of every answered class at every level.
const nested_src =
    \\module top(p, n);
    \\  inout p, n; electrical p, n;
    \\  parameter real g = 2.0;
    \\  localparam integer tag = 7;
    \\  electrical mid;
    \\  reg [3:0] state;
    \\  sub u(p, n);
    \\  analog I(p,n) <+ g*V(p,n);
    \\endmodule
    \\module sub(a, b);
    \\  inout a, b; electrical a, b;
    \\  parameter real k = 1.0;
    \\  electrical inner;
    \\  reg flag;
    \\  leaf v(a, b);
    \\  analog I(a,b) <+ k*V(a,b);
    \\endmodule
    \\module leaf(x, y);
    \\  inout x, y; electrical x, y;
    \\  parameter real r = 3.0;
    \\  electrical deep;
    \\  analog I(x,y) <+ r*V(x,y);
    \\endmodule
;

fn openSource(src: []const u8) !vera.CompileResult {
    var res = try vera.compileSource(std.testing.allocator, src, .lint);
    errdefer res.deinit();
    try open(std.testing.allocator, res.lowered);
    return res;
}

test "the scope tree is the instance tree, with definition names" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const d = &design.?;
    try std.testing.expectEqual(@as(usize, 3), d.scopes.len);
    try std.testing.expectEqualStrings("top", d.objects[0].full);
    try std.testing.expectEqualStrings("top.u", d.objects[1].full);
    try std.testing.expectEqualStrings("top.u.v", d.objects[2].full);
    // §11.6.1 vpiDefName — the fact flattening erases.
    try std.testing.expectEqualStrings("top", d.scopes[0].def_name);
    try std.testing.expectEqualStrings("sub", d.scopes[1].def_name);
    try std.testing.expectEqualStrings("leaf", d.scopes[2].def_name);
}

test "each scope holds the declarations of its own level" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const d = &design.?;
    // §11.6.4: ports come from the definition, so a child instance has them
    // even though the flatten collapsed them into the parent's nets.
    try std.testing.expectEqual(@as(usize, 2), d.scopes[0].ports.len);
    try std.testing.expectEqual(@as(usize, 2), d.scopes[1].ports.len);
    try std.testing.expectEqualStrings("top.u.v.x", d.objects[d.scopes[2].ports[0]].full);
    // §11.6.8/§11.6.9/§11.6.12: one each per level, bucketed by §6.7 path.
    try std.testing.expectEqualStrings("top.mid", d.objects[d.scopes[0].nets[0]].full);
    try std.testing.expectEqualStrings("top.u.inner", d.objects[d.scopes[1].nets[0]].full);
    try std.testing.expectEqualStrings("top.u.v.deep", d.objects[d.scopes[2].nets[0]].full);
    try std.testing.expectEqualStrings("top.state", d.objects[d.scopes[0].regs[0]].full);
    try std.testing.expectEqualStrings("top.u.flag", d.objects[d.scopes[1].regs[0]].full);
    try std.testing.expectEqualStrings("top.u.v.r", d.objects[d.scopes[2].params[0]].full);
}

test "vpi_iterate walks a level and vpi_scan frees the iterator at the end" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    try std.testing.expect(top != null);
    const itr = vpi_iterate(vpiNet, top);
    try std.testing.expect(itr != null);
    try std.testing.expectEqual(vpiIterator, vpi_get(vpiType, itr));
    const first = vpi_scan(itr);
    try std.testing.expectEqualStrings("mid", std.mem.span(vpi_get_str(vpiName, first)));
    try std.testing.expect(vpi_scan(itr) == null);
    // §12.4/§12.35: exhaustion freed it, so the handle is now invalid rather
    // than merely spent.
    try std.testing.expect(vpi_scan(itr) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "an abandoned iterator is freed by vpi_free_object" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    const itr = vpi_iterate(vpiParameter, top);
    _ = vpi_scan(itr);
    try std.testing.expectEqual(@as(usize, 1), design.?.iters.count());
    try std.testing.expectEqual(@as(c_int, 1), vpi_free_object(itr));
    try std.testing.expectEqual(@as(usize, 0), design.?.iters.count());
}

test "the §6.7 upward scope search, and absolute names" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const leaf = vpi_handle_by_name("top.u.v", null);
    try std.testing.expect(leaf != null);
    // Its own declaration.
    try std.testing.expect(vpi_handle_by_name("deep", leaf) != null);
    // One its grandparent declares — found by walking up.
    const mid = vpi_handle_by_name("mid", leaf);
    try std.testing.expect(mid != null);
    try std.testing.expectEqualStrings("top.mid", std.mem.span(vpi_get_str(vpiFullName, mid)));
    // §12.3: two handles to one object are the same object.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(mid, vpi_handle_by_name("top.mid", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(mid, leaf));
    // §11.6.4's edge back to the module, from both tags.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(
        vpi_handle(vpiScope, mid),
        vpi_handle(vpiModule, mid),
    ));
}

test "an invalid handle is an error, not a crash" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    // A pointer into the object array but off an element boundary, and one past
    // its end: the two shapes a stale or corrupted handle takes.
    const base = @intFromPtr(design.?.objects.ptr);
    const misaligned: vpiHandle = @ptrFromInt(base + 1);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, misaligned));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    const past: vpiHandle = @ptrFromInt(base + design.?.objects.len * @sizeOf(Obj));
    try std.testing.expect(vpi_get_str(vpiName, past) == null);
    try std.testing.expect(vpi_iterate(vpiNet, past) == null);
    try std.testing.expect(vpi_handle(vpiScope, past) == null);
    try std.testing.expect(vpi_handle_by_index(past, 0) == null);
    try std.testing.expect(vpi_handle_by_name("mid", past) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_free_object(past));
    // NULL is a handle too, and §12.5's NULL case is not one VerA answers.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
}

test "unsupported property requests report vpiError and vpiUndefined" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    const net = vpi_handle_by_name("top.mid", null);
    // §11.6.8 gives a net no direction and §11.6.1 gives a module no size.
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiDirection, net));
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiSize, top));
    try std.testing.expect(vpi_get_str(vpiDefName, net) == null);
    // A property VerA does not answer at all (vpiFile, §11.6.1's location).
    try std.testing.expectEqual(vpiUndefined, vpi_get(5, top));
    // And a successful call clears the status again (§12.2).
    try std.testing.expectEqual(vpiModule, vpi_get(vpiType, top));
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
}

test "a single-module design is a tree of one" {
    var res = try openSource(
        \\module only(p);
        \\  inout p; electrical p;
        \\  parameter real w = 1.0;
        \\  analog I(p) <+ w*V(p);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("only", null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiTopModule, top));
    try std.testing.expect(vpi_handle(vpiScope, top) == null);
    // §12.23: an empty set is NULL with NO error.
    try std.testing.expect(vpi_iterate(vpiReg, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    // §11.6.1 NOTE 1, and there is exactly one root.
    const roots = vpi_iterate(vpiModule, null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(top, vpi_scan(roots)));
    try std.testing.expect(vpi_scan(roots) == null);
}

test "port, reg and parameter properties come from the declaration" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const p = vpi_handle_by_name("top.p", null);
    try std.testing.expectEqual(vpiInout, vpi_get(vpiDirection, p));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiPortIndex, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiScalar, p));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiPortIndex, vpi_handle_by_name("top.n", null)));
    // §11.6.9 — a packed reg is a vector of its declared width.
    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, state));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiVector, state));
    // §3.4.5 as the SOURCE wrote it, not as the flatten rewrote it: `u.k` is a
    // child's `parameter`, which elaboration turned into a `localparam`.
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.g", null)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiLocalParam, vpi_handle_by_name("top.tag", null)));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiLocalParam, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiRealConst, vpi_get(vpiConstType, vpi_handle_by_name("top.u.k", null)));
    try std.testing.expectEqual(vpiIntConst, vpi_get(vpiConstType, vpi_handle_by_name("top.tag", null)));
}

test "a vector net reports its folded §3.6.3 width" {
    var res = try openSource(
        \\module vec(p);
        \\  inout p; electrical p;
        \\  electrical [0:3] bus;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const bus = vpi_handle_by_name("vec.bus", null);
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, bus));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiScalar, bus));
}

test "vpi_handle_by_index reports the unsupported class rather than guessing" {
    var res = try openSource(nested_src);
    defer res.deinit();
    defer close();

    const state = vpi_handle_by_name("top.state", null);
    try std.testing.expect(vpi_handle_by_index(state, 0) == null);
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(vpiError, vpi_chk_error(&info));
    try std.testing.expectEqual(vpiPLI, info.state);
    try std.testing.expectEqualStrings("NOINDEX", std.mem.span(info.code));
    try std.testing.expectEqualStrings("VerA", std.mem.span(info.product));
    // §12.2: vpi_chk_error itself does not reset the status.
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
}

test "handles survive the compilation they were built from" {
    // The §11.2.2 lifetime claim in the file header, as a test: every string
    // the model reports is copied, so freeing the CompileResult leaves the
    // handles valid.
    var res = try openSource(nested_src);
    defer close();
    const leaf = vpi_handle_by_name("top.u.v", null);
    res.deinit();
    try std.testing.expectEqualStrings("leaf", std.mem.span(vpi_get_str(vpiDefName, leaf)));
    try std.testing.expectEqualStrings("top.u.v.deep", std.mem.span(
        vpi_get_str(vpiFullName, vpi_handle_by_name("deep", leaf)),
    ));
}

var startup_calls: usize = 0;

fn countStartupCall() callconv(.c) void {
    startup_calls += 1;
}

test "§12.33.2 runs every entry of the table, in order, and stops at the 0" {
    startup_calls = 0;
    // A null table is a no-op: an application that registers nothing at startup
    // is a legal application.
    runStartupTable(null);
    try std.testing.expectEqual(@as(usize, 0), startup_calls);
    // "0 shall be last entry in list" — and an entry AFTER it is not reached,
    // which is what makes the terminator the terminator.
    const table = [_]?StartupFn{ &countStartupCall, &countStartupCall, null, &countStartupCall };
    runStartupTable(&table);
    try std.testing.expectEqual(@as(usize, 2), startup_calls);
}

test "no design open is an error on every routine" {
    close();
    try std.testing.expect(vpi_handle_by_name("top", null) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    try std.testing.expect(vpi_iterate(vpiModule, null) == null);
    try std.testing.expectEqual(vpiUndefined, vpi_get(vpiType, null));
    try std.testing.expect(vpi_get_str(vpiName, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_compare_objects(null, null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_release_handle(null));
}

// ---- the scope tree is elaboration's, read and not re-derived --------------

/// The `Scope` whose §6.7 path is `path`, or a test failure.
fn scopeAt(path: []const u8) !*const Scope {
    for (design.?.scopes) |*s| if (std.mem.eql(u8, s.path, path)) return s;
    std.debug.print("no scope at `{s}`\n", .{path});
    return error.TestExpectedEqual;
}

test "an instance array is one scope per element (§6.2.2, §6.7)" {
    // §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`,
    // and §6.7 addresses each element as `u[1].inner`. Elaboration inlines one
    // unit per element, so the VPI has one module per element.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  electrical inner;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    try std.testing.expectEqual(@as(usize, 3), design.?.scopes.len);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[0]")).def_name);
    try std.testing.expectEqualStrings("sub", (try scopeAt("u[1]")).def_name);
    const net = vpi_handle_by_name("top.u[1].inner", null);
    try std.testing.expect(net != null);
    try std.testing.expectEqual(vpiNet, vpi_get(vpiType, net));
    try std.testing.expect(vpi_handle_by_name("top.u[0].a", null) != null);
}

test "a paramset instance is an instance of the module §6.4.2 selected, through the chain" {
    // §6.4 "A chain of paramsets may be defined, but the last paramset in the
    // chain shall reference a module": `c` names `outer`, which names `mid`,
    // which names `leaf`. §6.4.2 selects between the two `pick`s by the range
    // that admits "PMOS", so `s` is a `pmod` and not the first `pick`'s `nmod`.
    // §12.12's example reads that module back as `vpiDefName`.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  outer c(p, n);
        \\  pick #(.t("PMOS")) s(p, n);
        \\endmodule
        \\paramset outer mid;
        \\  real tag;
        \\  tag = 1.0;
        \\endparamset
        \\paramset mid leaf;
        \\  .j = 2.0;
        \\endparamset
        \\paramset pick nmod;
        \\  parameter string t = "NMOS" from '{ "NMOS" };
        \\  .sign = 1.0;
        \\endparamset
        \\paramset pick pmod;
        \\  parameter string t = "PMOS" from '{ "PMOS" };
        \\  .sign = -1.0;
        \\endparamset
        \\module leaf(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real j = 0.0;
        \\  analog I(a,b) <+ j*V(a,b);
        \\endmodule
        \\module nmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
        \\module pmod(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real sign = 0.0;
        \\  analog I(a,b) <+ sign*V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    try std.testing.expectEqualStrings("leaf", (try scopeAt("c")).def_name);
    try std.testing.expectEqualStrings("pmod", (try scopeAt("s")).def_name);
    try std.testing.expect(vpi_handle_by_name("top.c.j", null) != null);
}

test "an instance resolved by Annex E.2.1's case-insensitive netlist match has its scope" {
    // E.2.1 "if no exact match is found, the mixed-case name shall match the
    // same name defined within SPICE regardless of the case". That rule is
    // about which MODULE an instance names, and elaboration owns it.
    //
    // It is NOT a rule about `vpi_handle_by_name`: §12.21 searches "using the
    // scope search rules defined by the Verilog-AMS HDL", and §2.7 makes those
    // case-sensitive. So `TOP.Q` still finds nothing.
    var res = try vera.compileSourceOpts(std.testing.allocator,
        \\module top(c, b, e);
        \\  inout c, b, e; electrical c, b, e;
        \\  VeRtNpN q(c, b, e);
        \\endmodule
    , .lint, .{ .spice_netlist = ".MODEL VERTNPN NPN BF=80 IS=1E-18\n" });
    defer res.deinit();
    try open(std.testing.allocator, res.lowered);
    defer close();

    const q = try scopeAt("q");
    try std.testing.expect(std.ascii.eqlIgnoreCase("vertnpn", q.def_name));
    // The card synthesizes `module vertnpn(c, b, e, s)`: its ports are
    // the definition's, so the scope has all four.
    try std.testing.expectEqual(@as(usize, 4), q.ports.len);
    try std.testing.expect(vpi_handle_by_name("top.q", null) != null);
    try std.testing.expect(vpi_handle_by_name("TOP.Q", null) == null);
}

test "the scopes are elaboration's units, one for one" {
    // One owner per fact: `Elaborate.Design.units` is the instance tree the
    // flatten built. Every unit is a scope with its path and module, in the
    // same depth-first source order, and there is no other scope.
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[0:1](p, n);
        \\  ps w(p, n);
        \\endmodule
        \\paramset ps sub;
        \\  .k = 2.0;
        \\endparamset
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  parameter real k = 1.0;
        \\  leaf v(a, b);
        \\endmodule
        \\module leaf(x, y);
        \\  inout x, y; electrical x, y;
        \\  analog I(x,y) <+ V(x,y);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const units = res.lowered.unit_paths;
    try std.testing.expectEqual(@as(usize, 7), units.len);
    try std.testing.expectEqual(units.len, design.?.scopes.len);
    for (units, design.?.scopes) |u, s| {
        try std.testing.expectEqualStrings(u.module, s.def_name);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, u.path, &.{Elaborate.sep}), s.path);
    }
}

// ---- §11.6.10/§11.6.11 arrays and §6.2.2 instance arrays --------------------

test "an instance array is a vpiModuleArray over its members (§6.2.2, IEEE 1364 §26.6.1)" {
    var res = try openSource(
        \\module top(p, n);
        \\  inout p, n; electrical p, n;
        \\  sub u[1:0](p, n);
        \\endmodule
        \\module sub(a, b);
        \\  inout a, b; electrical a, b;
        \\  analog I(a,b) <+ V(a,b);
        \\endmodule
    );
    defer res.deinit();
    defer close();

    const top = vpi_handle_by_name("top", null);
    // A module in no array has no index, and that is not an error.
    try std.testing.expect(vpi_handle(vpiIndex, top) == null);
    try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, top));

    const u = vpi_handle_by_name("top.u", null);
    try std.testing.expectEqual(vpiModuleArray, vpi_get(vpiType, u));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, u));
    const itr = vpi_iterate(vpiModule, u);
    var seen: u32 = 0;
    while (vpi_scan(itr)) |m| {
        try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, m));
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiModuleArray, m), u));
        var v: callback.Value = std.mem.zeroes(callback.Value);
        v.format = value.vpiIntVal;
        const index = vpi_handle(vpiIndex, m);
        try std.testing.expectEqual(vpiConstant, vpi_get(vpiType, index));
        value.vpi_get_value(index, &v);
        try std.testing.expectEqual(@as(c_int, 0), vpi_chk_error(null));
        seen |= @as(u32, 1) << @intCast(v.value.integer);
        try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle_by_index(u, v.value.integer), m));
    }
    try std.testing.expectEqual(@as(u32, 3), seen);
    try std.testing.expect(vpi_handle_by_index(u, 2) == null);
    try std.testing.expectEqual(vpiError, vpi_chk_error(null));
    // Iterating a module's instance arrays.
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_scan(vpi_iterate(vpiModuleArray, top)), u));
}

test "a digital memory is a vpiRegArray of vpiReg words, each bound to its engine slot" {
    var h: run.Harness = undefined;
    try h.init(
        \\module m;
        \\  reg [7:0] mem [0:3];
        \\  integer counts [2:1];
        \\  real samples [1:0];
        \\  initial begin mem[2] = 8'h7e; counts[1] = 5; end
        \\endmodule
    );
    defer h.deinit();
    try run.simulate();

    const top = vpi_handle_by_name("m", null);
    const mem = vpi_scan(vpi_iterate(vpiMemory, top));
    try std.testing.expectEqual(vpiRegArray, vpi_get(vpiType, mem));
    try std.testing.expectEqualStrings("vpiRegArray", std.mem.span(vpi_get_str(vpiType, mem)));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiIsMemory, mem));
    try std.testing.expectEqual(@as(c_int, 4), vpi_get(vpiSize, mem));
    const w2 = vpi_handle_by_index(mem, 2);
    try std.testing.expectEqual(vpiReg, vpi_get(vpiType, w2));
    try std.testing.expectEqual(@as(c_int, 8), vpi_get(vpiSize, w2));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, w2), mem));
    try std.testing.expectEqualStrings("m.mem[2]", std.mem.span(vpi_get_str(vpiFullName, w2)));
    var v: callback.Value = std.mem.zeroes(callback.Value);
    v.format = value.vpiIntVal;
    value.vpi_get_value(w2, &v);
    try std.testing.expectEqual(@as(c_int, 0x7e), v.value.integer);
    // Every word, by the legacy tag.
    var words: u32 = 0;
    const itr = vpi_iterate(vpiMemoryWord, mem);
    while (vpi_scan(itr)) |_| words += 1;
    try std.testing.expectEqual(@as(u32, 4), words);

    // An integer array is an integer variable with vpiArray set, whose
    // elements are variable selects.
    const counts = vpi_handle_by_name("m.counts", null);
    try std.testing.expectEqual(vpiIntegerVar, vpi_get(vpiType, counts));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, counts));
    const c1 = vpi_scan(vpi_iterate(vpiVarSelect, counts));
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, c1));
    value.vpi_get_value(c1, &v);
    try std.testing.expectEqual(@as(c_int, 5), v.value.integer);

    // A real array is a real variable with vpiArray set (§26.6.7).
    const samples = vpi_handle_by_name("m.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, samples));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, samples));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, samples));
}

test "an analog real array and real variable are §11.6.10's classes" {
    var res = try openSource(
        \\module ra(p);
        \\  inout p; electrical p;
        \\  real samples[1:0];
        \\  real x;
        \\  analog begin
        \\    samples[0] = V(p); samples[1] = 2*V(p); x = samples[0];
        \\    I(p) <+ x;
        \\  end
        \\endmodule
    );
    defer res.deinit();
    defer close();
    const arr = vpi_handle_by_name("ra.samples", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, arr));
    try std.testing.expectEqual(@as(c_int, 1), vpi_get(vpiArray, arr));
    try std.testing.expectEqual(@as(c_int, 2), vpi_get(vpiSize, arr));
    const sel = vpi_handle_by_index(arr, 1);
    try std.testing.expectEqual(vpiVarSelect, vpi_get(vpiType, sel));
    try std.testing.expectEqual(@as(c_int, 1), vpi_compare_objects(vpi_handle(vpiParent, sel), arr));
    const x = vpi_handle_by_name("ra.x", null);
    try std.testing.expectEqual(vpiRealVar, vpi_get(vpiType, x));
    try std.testing.expectEqual(@as(c_int, 0), vpi_get(vpiArray, x));
}
