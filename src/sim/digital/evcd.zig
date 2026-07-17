//! IEEE 1364-2005 §18.3/§18.4 extended value change dump: the `$dumpports`
//! calls and every resolution of a dumped port's net in; one file per call
//! out, header and `$dumpports` section at the end of the call's step
//! (§18.3.1), then one `#time` section per step of the ports whose state
//! (§18.4.3) changed, and `$vcdclose` when the run ends (§18.3.6.1).
//! A port's state is read from its net's drivers, split at the instance
//! boundary: those inside the dumped instance drive its output side, the
//! rest its input side (§18.4.3.2). A native executable writes the same
//! file through `rt/evcd.zig`, from `rt.net`'s driver rows.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const compile = @import("compile.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const Signal = @import("net.zig").Signal;

/// §18.3 the extended VCD tasks.
pub const Op = enum { ports, off, on, all, limit, flush };

/// The §18.3 task names, each to its `Op`.
pub const tasks = std.StaticStringMap(Op).initComptime(.{
    .{ "$dumpports", .ports },
    .{ "$dumpportsoff", .off },
    .{ "$dumpportson", .on },
    .{ "$dumpportsall", .all },
    .{ "$dumpportslimit", .limit },
    .{ "$dumpportsflush", .flush },
});

/// What §18.3.1's rules across `$dumpports` calls need at compile time: the
/// scopes and literal file names already given.
pub const Check = struct {
    scopes: std.ArrayList(u32) = .empty,
    files: std.ArrayList(Ast.StrId) = .empty,
};

/// Refuses a malformed §18.3 call (Syntax 18-21 to 18-25).
pub fn check(r: *Run, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    const ex = &r.file.exprs;
    const given = present(args);
    for (given) |a| if (a == .none) return r.fail(tok, "the §18.3 dump tasks take no null arguments", .{});
    switch (op) {
        // `$dumpports ( scope_list , file_pathname )`: "Only modules are
        // allowed (not variables)", "Each scope specified in the scope_list
        // shall be unique", and "Specifying the same file_pathname multiple
        // times is not allowed". The last argument is the file unless it
        // names an instance.
        .ports => for (given, 0..) |a, i| {
            const last = i + 1 == given.len;
            if (last and ex.tag(a) == .str_literal) {
                const f = ex.strOf(a);
                if (std.mem.indexOfScalar(Ast.StrId, r.ports_dump.files.items, f) != null)
                    return r.exprFail(a, "§18.3.1: the same file_pathname shall not be given to two $dumpports calls");
                try r.ports_dump.files.append(r.arena, f);
                continue;
            }
            if (ex.tag(a) != .ident and ex.tag(a) != .hier_ident) {
                if (last) continue;
                return r.exprFail(a, "§18.3.1: a $dumpports scope is a module instance");
            }
            const sc = switch (try vcd.target(r, a)) {
                .scope => |sc| sc,
                .slot => if (last) continue else return r.exprFail(a, "§18.3.1: a $dumpports scope is a module instance: only modules are allowed, not variables"),
            };
            if (std.mem.indexOfScalar(u32, r.ports_dump.scopes.items, sc) != null)
                return r.exprFail(a, "§18.3.1: each $dumpports scope shall be unique");
            try r.ports_dump.scopes.append(r.arena, sc);
        },
        .off, .on, .all, .flush => if (given.len > 1) return r.fail(tok, "$dumpportsoff, $dumpportson, $dumpportsall and $dumpportsflush take at most one file_pathname argument", .{}),
        // "The filesize argument is required".
        .limit => if (given.len == 0 or given.len > 2) return r.fail(tok, "$dumpportslimit takes a filesize, then optionally a file_pathname", .{}),
    }
    for (given) |a| if (ex.tag(a) != .ident and ex.tag(a) != .hier_ident) try compile.checkExpr(r, a);
}

/// `name()` and `name` alike: §18.3.7's "the name followed by ()".
fn present(args: []const Ast.ExprId) []const Ast.ExprId {
    return if (args.len == 1 and args[0] == .none) &.{} else args;
}

/// One dumped port (§18.4.2), in its module's declaration order.
const Port = struct {
    /// The dumped instance: drivers below it are the port's output side.
    inst: u32,
    slot: u32,
    net: ?u32,
    dir: Ast.Direction,
    /// The state text last written: `p<states> <s0> <s1>`.
    last: []u8 = &.{},
};

/// One `$dumpports` call's file.
const File = struct {
    name: []const u8,
    call: []const u8,
    scopes: []const u32,
    ports: []Port,
    file: ?std.Io.File = null,
    pos: u64 = 0,
    started: bool = false,
    on: bool = true,
    limit: ?u64 = null,
    limited: bool = false,
    last_time: ?u64 = null,
};

/// Every `$dumpports` file and the time they were called at.
pub const Evcd = struct {
    files: std.ArrayList(File) = .empty,
    selected_at: ?u64 = null,
};

/// The interpreter's run of one §18.3 task.
pub fn task(r: *Run, a: std.mem.Allocator, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    const ex = &r.file.exprs;
    const given = present(args);
    const d = &r.evcd;
    if (op == .ports) {
        // "the execution of all $dumpports tasks shall be at the same
        // simulation time".
        if (d.selected_at) |t| if (t != r.scheduler.now) return r.fail(tok, "§18.3.1: every $dumpports shall execute at the same simulation time", .{});
        d.selected_at = r.scheduler.now;
        var scopes: std.ArrayList(u32) = .empty;
        var name: []const u8 = "dumpports.vcd";
        for (given, 0..) |e, i| {
            if (ex.tag(e) == .ident or ex.tag(e) == .hier_ident) switch (try vcd.target(r, e)) {
                .scope => |sc| {
                    try scopes.append(r.arena, sc);
                    continue;
                },
                .slot => {},
            };
            if (i + 1 == given.len) name = try fileName(r, a, e) orelse return;
        }
        // "If no scope_list is specified, the scope shall be the one
        // containing the $dumpports call" (§18.3.1).
        if (scopes.items.len == 0) try scopes.append(r.arena, r.instanceOf(r.scope));
        for (d.files.items) |f| if (std.mem.eql(u8, f.name, name)) return r.fail(tok, "§18.3.1: the same file_pathname shall not be given to two $dumpports calls", .{});
        var ports: std.ArrayList(Port) = .empty;
        for (scopes.items) |sc| {
            const m = &r.file.modules[r.scope_info.items[sc].def];
            for (m.ports) |p| {
                const slot = r.names.get(.{ .scope = sc, .str = p.name }) orelse continue;
                try ports.append(r.arena, .{ .inst = sc, .slot = slot, .net = r.net_of.get(slot), .dir = p.direction });
                r.watch[slot].insert(.ports);
            }
        }
        try d.files.append(r.arena, .{
            .name = try r.arena.dupe(u8, name),
            .call = vcd.callText(r.text, r.starts[tok]),
            .scopes = scopes.items,
            .ports = ports.items,
        });
        return exec.requestVcd(r);
    }
    // §18.3.7: a file_pathname that names no $dumpports file is ignored;
    // none names every one of them.
    var want: ?[]const u8 = null;
    if (given.len != 0 and (op != .limit or given.len == 2))
        want = try fileName(r, a, given[given.len - 1]) orelse return;
    const size = if (op == .limit) std.math.lossyCast(u64, (try exec.eval(r, a, given[0], 0)).asInt() orelse 0) else 0;
    for (d.files.items) |*f| {
        if (want) |w| if (!std.mem.eql(u8, w, f.name)) continue;
        switch (op) {
            .ports => unreachable,
            .limit => f.limit = size,
            // Every section is written as it happens: no buffer to empty.
            .flush => {},
            // §18.3.2: "a checkpoint is made ... where each specified port
            // is dumped with an X value"; ignored when already suspended.
            .off => if (f.started and f.on) {
                try changes(r, a, f);
                try checkpoint(r, a, f, "$dumpportsoff", true);
                f.on = false;
            },
            .on => if (f.started and !f.on) {
                f.on = true;
                try checkpoint(r, a, f, "$dumpportson", false);
            },
            // §18.3.3: every port, "regardless of whether the port values
            // have changed since the last time step".
            .all => if (f.started and f.on) {
                try changes(r, a, f);
                try checkpoint(r, a, f, "$dumpportsall", false);
            },
        }
    }
}

/// The characters of a file_pathname argument; null for an x or z bit.
fn fileName(r: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?[]const u8 {
    return @import("system.zig").text(a, try exec.eval(r, a, e, 0));
}

/// The end of a step with a port's net resolved, or of the `$dumpports`
/// step: each new file's header and `$dumpports` section, and each running
/// file's changes.
pub fn tick(r: *Run, a: std.mem.Allocator) Error!void {
    for (r.evcd.files.items) |*f| {
        if (f.started) {
            try changes(r, a, f);
            continue;
        }
        const io = r.io orelse return r.fail(0, "$dumpports needs a filesystem to write `{s}`", .{f.name});
        f.file = std.Io.Dir.cwd().createFile(io, f.name, .{}) catch return r.fail(0, "cannot create the dump file `{s}`", .{f.name});
        f.started = true;
        var w: std.Io.Writer.Allocating = .init(a);
        try vcd.preamble(&w.writer, io, f.call, r.finest);
        // §18.4.2: "$scope module <full instance path> $end", then one
        // `$var port <size> <n> <name> $end` per port.
        var n: u32 = 0;
        for (f.scopes) |sc| {
            try w.writer.writeAll("$scope module ");
            try path(r, &w.writer, sc);
            try w.writer.writeAll(" $end\n");
            for (f.ports) |p| if (p.inst == sc) {
                const width = r.values[p.slot].width;
                try w.writer.writeAll("$var port ");
                if (width == 1) try w.writer.writeAll("1") else {
                    const range = r.vecRange(p.slot);
                    try w.writer.print("[{d}:{d}]", .{ range.msb, range.lsb });
                }
                try w.writer.print(" <{d} {s} $end\n", .{ n, portName(r, p) });
                n += 1;
            };
            try w.writer.writeAll("$upscope $end\n");
        }
        try w.writer.writeAll("$enddefinitions $end\n");
        try put(r, f, w.written());
        try checkpoint(r, a, f, "$dumpports", false);
    }
}

/// §18.3.6.1 `$vcdclose <final time> $end`, once the run is over.
pub fn close(r: *Run) Error!void {
    for (r.evcd.files.items) |*f| if (f.started) {
        var buf: [64]u8 = undefined;
        try put(r, f, std.mem.print(&buf, "$vcdclose #{d} $end\n", .{r.scheduler.now}) catch unreachable);
    };
}

fn portName(r: *Run, p: Port) []const u8 {
    const m = &r.file.modules[r.scope_info.items[p.inst].def];
    for (m.ports) |mp| if (r.names.get(.{ .scope = p.inst, .str = mp.name }) == p.slot) return r.file.str(mp.name);
    unreachable; // `task` found the slot by a port's name
}

/// The instance path of `scope` from its root, `top.u`.
pub fn path(r: *Run, w: *std.Io.Writer, scope: u32) std.Io.Writer.Error!void {
    const info = r.scope_info.items[scope];
    if (!root.isRoot(r, scope)) {
        try path(r, w, info.parent);
        try w.writeByte('.');
    }
    try w.writeAll(r.file.str(info.name));
    if (info.index) |i| try w.print("[{d}]", .{i});
}

fn put(r: *Run, f: *File, bytes: []const u8) Error!void {
    if (f.limited or bytes.len == 0) return;
    const file = f.file orelse return;
    var out = bytes;
    // §18.3.4: "When this filesize is reached, the dumping stops, and a
    // comment is inserted into file_pathname indicating the size limit was
    // attained."
    if (f.limit) |lim| if (f.pos + bytes.len > lim) {
        out = "$comment $dumpportslimit reached $end\n";
        f.limited = true;
    };
    file.writePositionalAll(r.io.?, out, f.pos) catch return r.fail(0, "cannot write the dump file `{s}`", .{f.name});
    f.pos += out.len;
}

fn time(r: *Run, f: *File, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (f.last_time == r.scheduler.now) return;
    f.last_time = r.scheduler.now;
    try w.print("#{d}\n", .{r.scheduler.now});
}

/// A section of every port (`as_x`: each unknown, for `$dumpportsoff`),
/// which then counts as written.
fn checkpoint(r: *Run, a: std.mem.Allocator, f: *File, keyword: []const u8, as_x: bool) Error!void {
    var w: std.Io.Writer.Allocating = .init(a);
    try time(r, f, &w.writer);
    try w.writer.print("{s}\n", .{keyword});
    for (f.ports, 0..) |*p, n| {
        const text = if (as_x) try unknown(a, r, p.*) else try state(r, a, p.*);
        p.last = try r.arena.dupe(u8, text);
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try w.writer.writeAll("$end\n");
    try put(r, f, w.written());
}

/// The ports whose state is not the one last written.
fn changes(r: *Run, a: std.mem.Allocator, f: *File) Error!void {
    if (!f.on) return;
    var w: std.Io.Writer.Allocating = .init(a);
    for (f.ports, 0..) |*p, n| {
        const text = try state(r, a, p.*);
        if (std.mem.eql(u8, text, p.last)) continue;
        if (w.written().len == 0) try time(r, f, &w.writer);
        p.last = try r.arena.dupe(u8, text);
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try put(r, f, w.written());
}

/// §18.4.3 `p<port_value> <0_strength> <1_strength>` of port `p`: per bit,
/// most significant first, a Table 18-7 state character and its strength
/// digits.
fn state(r: *Run, a: std.mem.Allocator, p: Port) Error![]const u8 {
    const width = r.values[p.slot].width;
    var chars = try a.alloc(u8, 3 * width);
    for (0..width) |i| {
        const bit: u32 = @intCast(width - 1 - i);
        var in: Signal = .{};
        var out: Signal = .{};
        if (p.net) |net| {
            for (r.nets[net].drivers) |d| {
                const c = exec.contribution(r.drivers[d], bit);
                if (below(r, r.drivers[d].scope, p.inst)) out = out.combine(c) else in = in.combine(c);
            }
        } else out = .of(r.values[p.slot].bit(bit), .strong, .strong); // an output declared as a variable
        const s = portState(p.dir, in, out);
        chars[i] = s.c;
        chars[width + i] = '0' + s.s0;
        chars[2 * width + i] = '0' + s.s1;
    }
    return a.print("p{s} {s} {s}", .{ chars[0..width], chars[width .. 2 * width], chars[2 * width ..] });
}

/// `$dumpportsoff`'s X: Table 18-7's unknown of the port's direction.
fn unknown(a: std.mem.Allocator, r: *Run, p: Port) Error![]const u8 {
    const width = r.values[p.slot].width;
    const c: u8 = switch (p.dir) {
        .input => 'N',
        .output => 'X',
        .inout, .unspecified => '?',
    };
    const chars = try a.alloc(u8, width);
    @memset(chars, c);
    const sixes = try a.alloc(u8, width);
    @memset(sixes, '6');
    return a.print("p{s} {s} {s}", .{ chars, sixes, sixes });
}

/// Is `scope` the instance `inst` or inside it?
pub fn below(r: *Run, scope: u32, inst: u32) bool {
    var s = scope;
    while (true) {
        if (s == inst) return true;
        if (root.isRoot(r, s)) return false;
        s = r.scope_info.items[s].parent;
    }
}

/// One port bit as §18.4.3 dumps it: the Table 18-7 state character and
/// its strength0 and strength1 components, each 0..7.
pub const State = struct { c: u8, s0: u8, s1: u8 };

/// A signal's strength components: the strength0 and strength1 levels it
/// spans (0 on a side it does not reach).
fn levels(s: Signal) [2]u8 {
    return .{ if (s.lo < 0) @intCast(-s.lo) else 0, if (s.hi > 0) @intCast(s.hi) else 0 };
}

/// §18.4.3.1 Table 18-7 and §18.4.3.2's conflict rules for one bit, from
/// what the input side (`in`, the test fixture) and the output side (`out`,
/// the device) drive. "Strength 7 to 5: strong strength; Strength 4 to 1:
/// weak strength."
pub fn portState(dir: Ast.Direction, in: Signal, out: Signal) State {
    const li = levels(in);
    const lo = levels(out);
    if (in.none() and out.none()) return .{ .c = switch (dir) {
        .input => 'Z',
        .output => 'T',
        .inout, .unspecified => 'f',
    }, .s0 = 0, .s1 = 0 };
    if (out.none()) return .{ .c = pick(in.collapse(), "DUN"), .s0 = li[0], .s1 = li[1] };
    if (in.none()) return .{ .c = pick(out.collapse(), "LHX"), .s0 = lo[0], .s1 = lo[1] };
    const vi = in.collapse();
    const vo = out.collapse();
    if (vi == vo and (vi == .zero or vi == .one)) {
        const side: usize = if (vi == .zero) 0 else 1;
        const strong_in = li[side] >= 5;
        const strong_out = lo[side] >= 5;
        // "If both input and output are driving the same value with the
        // same range of strength ... the resolved value is 0/1, and the
        // strength is the stronger of the two." Strong input over weak
        // output is d/u at the input's strength, the reverse l/h at the
        // output's.
        if (strong_in == strong_out) return .{ .c = pick(vi, "01?"), .s0 = @max(li[0], lo[0]), .s1 = @max(li[1], lo[1]) };
        if (strong_in) return .{ .c = pick(vi, "du?"), .s0 = li[0], .s1 = li[1] };
        return .{ .c = pick(vi, "lh?"), .s0 = lo[0], .s1 = lo[1] };
    }
    // Disagreeing sides: "A unknown (input 0 and output 1)" and the rest.
    const both = levels(in.combine(out));
    const c: u8 = switch (vi) {
        .zero => if (vo == .one) 'A' else 'a',
        .one => if (vo == .zero) 'B' else 'b',
        else => switch (vo) {
            .zero => 'C',
            .one => 'c',
            else => '?',
        },
    };
    return .{ .c = c, .s0 = both[0], .s1 = both[1] };
}

/// `set`'s character for 0, 1, else unknown.
fn pick(b: Front.Integer.Bit, set: *const [3]u8) u8 {
    return switch (b) {
        .zero => set[0],
        .one => set[1],
        .x, .z => set[2],
    };
}

test "§18.4.3.2 port states from the two sides' drivers" {
    const strong1: Signal = .of(.one, .strong, .strong);
    const weak0: Signal = .of(.zero, .weak, .weak);
    const strong0: Signal = .of(.zero, .strong, .strong);
    try std.testing.expectEqual(State{ .c = '1', .s0 = 0, .s1 = 6 }, portState(.inout, strong1, strong1));
    try std.testing.expectEqual(State{ .c = 'l', .s0 = 6, .s1 = 0 }, portState(.inout, weak0, strong0));
    try std.testing.expectEqual(State{ .c = 'd', .s0 = 6, .s1 = 0 }, portState(.inout, strong0, weak0));
    try std.testing.expectEqual(State{ .c = 'D', .s0 = 3, .s1 = 0 }, portState(.inout, weak0, .{}));
    try std.testing.expectEqual(State{ .c = 'f', .s0 = 0, .s1 = 0 }, portState(.inout, .{}, .{}));
    try std.testing.expectEqual(State{ .c = 'N', .s0 = 6, .s1 = 6 }, portState(.input, .of(.x, .strong, .strong), .{}));
    try std.testing.expectEqual(State{ .c = 'A', .s0 = 6, .s1 = 6 }, portState(.inout, strong0, strong1));
}
