//! The rows every model builder shares: `Building` (a scope under
//! construction), the §11.6.10/§11.6.11 array rows, IEEE 1364-2005 §26.6.10
//! range rows, §6.2.2 instance-array rows, and `freeze`, which turns a
//! builder's growable lists into the fixed `Design` tables. The builders are
//! model/analog.zig (over `Lowered`) and model/digital.zig (over a
//! `sim.digital.Run`); both append rows to one `Rows`.
//!
//! Every builder keeps the `Scope` invariant (root.zig): the module rows come
//! first, in scope order. Row strings and slices live in `Design.arena`; the
//! growable lists live in `gpa` until `freeze` copies them.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Elaborate = @import("ir").Elaborate;
const sim = @import("sim");
const code = @import("code.zig");
const root = @import("root.zig");

const Design = root.Design;
const Error = root.Error;
const Kind = root.Kind;
const Obj = root.Obj;
const Cold = root.Cold;
const Scope = root.Scope;
const vpiSize = root.vpiSize;

/// The rows a builder appends: the `Obj` table and the `Cold` rows its
/// `Obj.cold` indexes. Both live in `gpa`, the `Design`'s allocator, until
/// `freeze` hands them to the `Design`; everything else a builder grows is
/// scratch, in an arena it frees when it returns.
pub const Rows = struct {
    gpa: std.mem.Allocator,
    hot: std.ArrayList(Obj) = .empty,
    cold: std.ArrayList(Cold) = .empty,

    /// Frees whatever `freeze` did not take.
    pub fn deinit(rows: *Rows) void {
        rows.hot.deinit(rows.gpa);
        rows.cold.deinit(rows.gpa);
    }

    /// Appends row `o`, with no cold fields.
    pub fn append(rows: *Rows, o: Obj) Error!void {
        try rows.hot.append(rows.gpa, o);
    }

    /// Appends row `o` with cold fields `c`.
    pub fn appendCold(rows: *Rows, o: Obj, c: Cold) Error!void {
        try rows.hot.ensureUnusedCapacity(rows.gpa, 1);
        var row = o;
        row.cold = @intCast(rows.cold.items.len);
        try rows.cold.append(rows.gpa, c);
        rows.hot.appendAssumeCapacity(row);
    }

    /// Row `at`'s cold fields to write, its `Cold` row added on first use.
    /// Invalidates earlier results of `coldFor` and `coldOf`.
    pub fn coldFor(rows: *Rows, at: u32) Error!*Cold {
        const o = &rows.hot.items[at];
        if (o.cold == root.no_cold) {
            try rows.cold.append(rows.gpa, .{});
            o.cold = @intCast(rows.cold.items.len - 1);
        }
        return &rows.cold.items[o.cold];
    }

    /// Row `at`'s cold fields to read: `Cold{}` when it has none.
    pub fn coldOf(rows: *const Rows, at: u32) *const Cold {
        const c = rows.hot.items[at].cold;
        return if (c == root.no_cold) &empty_cold else &rows.cold.items[c];
    }

    const empty_cold: Cold = .{};
};

/// A scope under construction: the definition it instantiates, plus the
/// growable sets that become `Scope`'s slices.
pub const Building = struct {
    decl: *const Ast.ModuleDecl,
    def_name: []const u8,
    library: []const u8 = "work",
    config: []const u8 = "",
    path: []const u8,
    time_unit: ?i8 = null,
    time_precision: ?i8 = null,
    parent: ?u32,
    /// A digital model's `digital.Run` scope id for this instance.
    engine: u32 = 0,
    children: std.ArrayList(u32) = .empty,
    ports: std.ArrayList(u32) = .empty,
    nets: std.ArrayList(u32) = .empty,
    regs: std.ArrayList(u32) = .empty,
    params: std.ArrayList(u32) = .empty,
    integers: std.ArrayList(u32) = .empty,
    reals: std.ArrayList(u32) = .empty,
    reg_arrays: std.ArrayList(u32) = .empty,
    net_arrays: std.ArrayList(u32) = .empty,
    variables: std.ArrayList(u32) = .empty,
    module_arrays: std.ArrayList(u32) = .empty,
    nodes: std.ArrayList(u32) = .empty,
    branches: std.ArrayList(u32) = .empty,
    code: code.ScopeLists = .{},

    /// Frees the growable lists, which live in `gpa`; the strings they index
    /// are the arena's and stay.
    pub fn deinit(s: *Building, gpa: std.mem.Allocator) void {
        s.children.deinit(gpa);
        s.ports.deinit(gpa);
        s.nets.deinit(gpa);
        s.regs.deinit(gpa);
        s.params.deinit(gpa);
        s.integers.deinit(gpa);
        s.reals.deinit(gpa);
        s.reg_arrays.deinit(gpa);
        s.net_arrays.deinit(gpa);
        s.variables.deinit(gpa);
        s.module_arrays.deinit(gpa);
        s.nodes.deinit(gpa);
        s.branches.deinit(gpa);
        s.code.deinit(gpa);
    }
};

/// The model's fixed arrays, from what a builder accumulated. `rows` must
/// hold the modules first and in scope order — the `Scope` invariant. Takes
/// `rows`' tables (no copy), leaving it empty; `rows.gpa` must be `d.gpa`.
pub fn freeze(d: *Design, rows: *Rows, scopes: []const Building) Error!void {
    const gpa = d.gpa;
    const arena = d.arena.allocator();
    d.objects = try rows.hot.toOwnedSlice(rows.gpa);
    d.cold = try rows.cold.toOwnedSlice(rows.gpa);
    const objects = d.objects;
    d.scopes = try gpa.alloc(Scope, scopes.len);
    for (scopes, 0..) |*s, i| d.scopes[i] = .{
        .parent = s.parent,
        .def_name = s.def_name,
        .library = s.library,
        .config = s.config,
        .path = s.path,
        .time_unit = s.time_unit,
        .time_precision = s.time_precision,
        .children = try arena.dupe(u32, s.children.items),
        .internal = blk: {
            var all: std.ArrayList(u32) = .empty;
            try all.appendSlice(arena, s.children.items);
            for (s.code.gen_arrays.items) |g| try all.appendSlice(arena, objects[g].lists[0].items);
            try all.appendSlice(arena, s.code.internal.items);
            break :blk all.items;
        },
        .ports = try arena.dupe(u32, s.ports.items),
        .nets = try arena.dupe(u32, s.nets.items),
        .regs = try arena.dupe(u32, s.regs.items),
        .params = try arena.dupe(u32, s.params.items),
        .integers = try arena.dupe(u32, s.integers.items),
        .reals = try arena.dupe(u32, s.reals.items),
        .reg_arrays = try arena.dupe(u32, s.reg_arrays.items),
        .net_arrays = try arena.dupe(u32, s.net_arrays.items),
        .variables = try arena.dupe(u32, s.variables.items),
        .module_arrays = try arena.dupe(u32, s.module_arrays.items),
        .nodes = try arena.dupe(u32, s.nodes.items),
        .branches = try arena.dupe(u32, s.branches.items),
        .lists = try s.code.freeze(arena),
        .engine = s.engine,
    };
    d.top_modules = try arena.dupe(u32, &[_]u32{0});
    // A constant and a quantity have no name to be found by (§11.6.7 lists
    // none), and a node shares its net's name — the NET is what a name
    // denotes (§11.6.8), the node is reached from it. Disciplines and
    // natures live in their own namespace (§3.6), not the hierarchy's.
    for (d.objects, 0..) |o, i| switch (o.kind) {
        .constant, .quantity, .node, .discipline, .nature => {},
        // A named block, task, function or named event has a full name; a
        // statement or expression does not.
        .code => if (o.full.len != 0) try d.by_name.put(gpa, o.full, @intCast(i)),
        // An implicit net shares its name with the port that made it; the
        // name keeps denoting what the source declared.
        .net => if (!o.implicit or !d.by_name.contains(o.full)) try d.by_name.put(gpa, o.full, @intCast(i)),
        .module, .port, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .branch => try d.by_name.put(gpa, o.full, @intCast(i)),
    };
}

/// §11.6.10/§11.6.11: an array object and, after it, each element preceded by
/// the constant its `vpiIndex` leads to — elements in increasing index,
/// row-major over the dimensions `[low:high]` then `rest`, so the element
/// count is IEEE 1364-2005 §26.6.6/§26.6.7's vpiSize. A multidimensional
/// element is named by all its indices (`m[1][2]`) and its vpiIndex is the
/// innermost ("the index for the reg", §26.6.7 m). The digital engine stores
/// element k of that order in `base + k` (`digital.Run.arrays`), which is the
/// slot given each element here.
pub fn addArray(
    arena: std.mem.Allocator,
    objects: *Rows,
    kind: Kind,
    owner: u32,
    name: []const u8,
    full: []const u8,
    ty: Ast.Type,
    low: i64,
    high: i64,
    rest: []const sim.digital.Span,
    width: u32,
    base: ?u32,
) Error!u32 {
    const at: u32 = @intCast(objects.hot.items.len);
    var count: u32 = @intCast(high - low + 1);
    for (rest) |sp| count *= @intCast(sp.high - sp.low + 1);
    const members = try arena.alloc(u32, count);
    try objects.appendCold(.{ .kind = kind, .owner = .of(owner), .name = name, .full = full, .size = count, .ty = ty }, .{ .members = members });
    const elem: Kind = switch (kind) {
        .reg_array => .word,
        .net_array => .net,
        else => .var_select, // else: the one other array class addArray is given
    };
    var suffix: std.ArrayList(u8) = .empty;
    for (0..count) |k| {
        // Peel the indices off `k`, innermost (fastest) dimension first.
        suffix.clearRetainingCapacity();
        var q: i64 = @intCast(k);
        var inner: i64 = 0;
        var d = rest.len + 1;
        while (d > 0) {
            d -= 1;
            const sp: sim.digital.Span = if (d == 0) .{ .low = low, .high = high } else rest[d - 1];
            const n = sp.high - sp.low + 1;
            const i = sp.low + @mod(q, n);
            q = @divTrunc(q, n);
            if (d == rest.len) inner = i;
            var buf: [24]u8 = undefined;
            try suffix.insertSlice(arena, 0, std.mem.print(&buf, "[{d}]", .{i}) catch unreachable);
        }
        const c: u32 = @intCast(objects.hot.items.len);
        try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = inner } });
        members[k] = @intCast(objects.hot.items.len);
        const local = try arena.print("{s}{s}", .{ name, suffix.items });
        try objects.append(.{
            .kind = elem,
            .owner = .of(owner),
            .name = local,
            .full = try arena.print("{s}{s}", .{ full, suffix.items }),
            .size = width,
            .ty = ty,
            .slot = .of(if (base) |b| b + @as(u32, @intCast(k)) else null),
            .parent = .of(at),
            .index = .of(c),
        });
    }
    return at;
}

/// IEEE 1364-2005 §26.6.10: a range object over `[left:right]`, its two
/// bounds decimal constants, its vpiSize the element count.
///
/// The caller adds one row for each dimension it models.
pub fn addRange(arena: std.mem.Allocator, objects: *Rows, owner: u32, left: i64, right: i64) Error!u32 {
    const l: u32 = @intCast(objects.hot.items.len);
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = left } });
    try objects.append(.{ .kind = .constant, .owner = .of(owner), .name = "", .full = "", .size = 32, .value = .{ .int = right } });
    const edges = try arena.dupe(code.Edge, &.{ .{ .tag = code.vpiLeftRange, .to = l }, .{ .tag = code.vpiRightRange, .to = l + 1 } });
    const size: c_int = @intCast(@abs(left - right) + 1);
    const props = try arena.dupe(code.Prop, &.{.{ .prop = vpiSize, .value = size }});
    try objects.append(.{ .kind = .code, .vtype = code.vpiRange, .owner = .of(owner), .name = "", .full = "", .edges = edges, .props = props });
    return l + 2;
}

/// §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`:
/// elaboration names each element `u[k]`, so sibling scopes that share the
/// identifier before `[` are one array. The array object goes in the parent
/// scope, and every member module learns its array and its index.
pub fn addModuleArrays(gpa: std.mem.Allocator, arena: std.mem.Allocator, objects: *Rows, scopes: []Building, top_name: []const u8) Error!void {
    for (scopes, 0..) |*parent, p| {
        var i: usize = 0;
        while (i < parent.children.items.len) : (i += 1) {
            const first = parent.children.items[i];
            const name = arrayBase(lastComponent(scopes[first].path)) orelse continue;
            // Already grouped under an earlier sibling?
            if (objects.hot.items[first].parent != .none) continue;
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
            const at: u32 = @intCast(objects.hot.items.len);
            const path = if (parent.path.len == 0) name else try joinPath(arena, parent.path, name);
            try objects.appendCold(.{
                .kind = .module_array,
                .owner = .of(@intCast(p)),
                .name = name,
                .full = try joinPath(arena, top_name, path),
                .size = @intCast(members.items.len),
            }, .{ .members = try arena.dupe(u32, members.items) });
            try parent.module_arrays.append(gpa, at);
            for (members.items) |m| {
                const c: u32 = @intCast(objects.hot.items.len);
                try objects.append(.{ .kind = .constant, .owner = .of(@intCast(p)), .name = "", .full = "", .size = 32, .value = .{ .int = scopeIndex(scopes, m) } });
                objects.hot.items[m].parent = .of(at);
                objects.hot.items[m].index = .of(c);
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

/// The declarations each scope's attribute pass decorates: rows owned by
/// one of the scopes, neither `.code` nor `.module`, with a source token.
/// Bucketed by owner in object order, once, rather than found by a scan of
/// every object per scope. Exact for a pass that runs scope by scope over
/// the rows that exist before it, because a scope's pass adds only rows it
/// owns, `.code` rows and ownerless ones.
pub const Decls = struct {
    /// Scope `i`'s rows are `rows[first[i]..first[i + 1]]`.
    first: []u32,
    rows: []u32,

    pub fn init(gpa: std.mem.Allocator, objects: []const Obj, n_scopes: usize) Error!Decls {
        const first = try gpa.alloc(u32, n_scopes + 1);
        errdefer gpa.free(first);
        @memset(first, 0);
        for (objects) |o| if (isDecl(o, n_scopes)) {
            first[o.owner.get().? + 1] += 1;
        };
        for (1..first.len) |k| first[k] += first[k - 1];
        const rows = try gpa.alloc(u32, first[n_scopes]);
        errdefer gpa.free(rows);
        const fill = try gpa.dupe(u32, first[0..n_scopes]);
        defer gpa.free(fill);
        for (objects, 0..) |o, at| if (isDecl(o, n_scopes)) {
            rows[fill[o.owner.get().?]] = @intCast(at);
            fill[o.owner.get().?] += 1;
        };
        return .{ .first = first, .rows = rows };
    }

    pub fn deinit(d: *Decls, gpa: std.mem.Allocator) void {
        gpa.free(d.first);
        gpa.free(d.rows);
    }

    /// Scope `i`'s declaration rows, in object order.
    pub fn of(d: Decls, i: usize) []const u32 {
        return d.rows[d.first[i]..d.first[i + 1]];
    }

    fn isDecl(o: Obj, n_scopes: usize) bool {
        return o.owner != .none and o.owner.get().? < n_scopes and o.kind != .code and o.kind != .module and o.src_tok != 0;
    }
};

/// §6.7 full name -> object, for resolving the identifiers of the
/// behavioural objects. Built in object order, so where a port and a net
/// share a name (a port of the top is declared as a net too) the net wins,
/// as it does in `by_name`.
pub fn nameTable(gpa: std.mem.Allocator, objects: []const Obj) Error!std.StringHashMapUnmanaged(u32) {
    var names: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer names.deinit(gpa);
    for (objects, 0..) |o, i| switch (o.kind) {
        .constant, .quantity, .node, .discipline, .nature => {},
        .module, .port, .net, .reg, .parameter, .integer, .real_var, .time_var, .reg_array, .var_array, .net_array, .word, .var_select, .module_array, .branch, .code => if (o.full.len != 0) try names.put(gpa, o.full, @intCast(i)),
    };
    return names;
}

/// §6.7 join: `parent` and `local` with `Elaborate.sep` between them, or just
/// `local` when `parent` is the empty root path. `vpiFullName` is this applied
/// once more with the top module's own name on the left, which is the form
/// §12.21's own example passes (`vpi_handle_by_name("top.mod1", …)`).
pub fn joinPath(arena: std.mem.Allocator, parent: []const u8, local: []const u8) Error![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, local);
    if (local.len == 0) return arena.dupe(u8, parent);
    return arena.print("{s}{c}{s}", .{ parent, Elaborate.sep, local });
}

/// The `vpiName` part of a §6.7 path: what follows the last `Elaborate.sep`,
/// or all of `path`. A slice of `path`, not a copy.
pub fn lastComponent(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, Elaborate.sep) orelse return path;
    return path[at + 1 ..];
}
