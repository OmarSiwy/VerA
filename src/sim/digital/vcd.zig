//! IEEE 1364-2005 §18.1/§18.2: the four-state value change dump.
//!
//! In: the `$dump*` task calls and every change of a dumped slot, which
//! arrives through the engine's one value-change hook (`Watcher.vcd` in
//! `exec.store`). Out: the VCD file — the header and definitions at the end
//! of the time step `$dumpvars` ran in (§18.1.3), then one `#time` section per
//! time step with the variables whose value differs from the last one dumped
//! (§18.1.4 "values of variables that do not change ... are not dumped").
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const exec = @import("exec.zig");
const compile = @import("compile.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const zCReal = @import("kernels").str_kernels.zCReal;

/// The §18.1 tasks: `$dumpfile`, `$dumpvars`, `$dumpoff`, `$dumpon`,
/// `$dumpall`, `$dumplimit`, `$dumpflush`.
pub const Op = enum { file, vars, off, on, all, limit, flush };

/// One identifier code (§18.2.1): a slot and the value last written for it.
/// Two references to one slot — a port collapsed onto its parent's net —
/// share the code, which §18.2.3.7 b) permits.
const Code = struct { slot: u32, last: []u64 };

pub const Vcd = struct {
    name: []const u8 = "dump.vcd",
    /// §18.1.2 the `$dumpvars` selection: scopes with their level count
    /// (0 = every level below) and single variables, by slot.
    scopes: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    slots: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The time the `$dumpvars` calls ran at, and the one to blame.
    selected_at: ?u64 = null,
    tok: u32 = 0,
    started: bool = false,
    on: bool = true,
    /// One end-of-step `.vcd_tick` however many dumped values moved.
    pending: bool = false,
    codes: std.ArrayList(Code) = .empty,
    file: ?std.Io.File = null,
    pos: u64 = 0,
    limit: ?u64 = null,
    /// §18.1.5: the limit was reached and dumping has stopped for good.
    limited: bool = false,
    last_time: ?u64 = null,
};

// ---- compile time -----------------------------------------------------------

pub fn check(r: *Run, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    for (args) |a| if (a == .none) return r.fail(tok, "the §18.1 dump tasks take no null arguments", .{});
    switch (op) {
        // §18.1.1: the filename is optional.
        .file => {
            if (args.len > 1) return r.fail(tok, "$dumpfile takes at most one filename", .{});
            for (args) |a| try compile.checkExpr(r, a);
        },
        .vars => if (args.len != 0) {
            try compile.checkExpr(r, args[0]);
            for (args[1..]) |a| _ = try target(r, a);
        },
        .limit => {
            if (args.len != 1) return r.fail(tok, "$dumplimit takes one file size", .{});
            try compile.checkExpr(r, args[0]);
        },
        .off, .on, .all, .flush => if (args.len != 0) return r.fail(tok, "$dumpoff, $dumpon, $dumpall and $dumpflush take no arguments", .{}),
    }
}

/// §18.1.2 `module_or_variable`: a module instance — the root by its module
/// name, or a downward path — or a variable, by slot.
const Target = union(enum) { scope: u32, slot: u32 };

fn target(r: *Run, e: Ast.ExprId) Error!Target {
    const ex = &r.file.exprs;
    const parts: []const Ast.StrId = switch (ex.tag(e)) {
        .ident => &.{ex.strOf(e)},
        .hier_ident => ex.nameParts(e),
        else => return r.exprFail(e, "$dumpvars names a module instance or a variable"), // else: A.8.x forms that name no scope or variable
    };
    var scope = r.instanceOf(r.scope);
    var first = true;
    for (parts, 0..) |p, i| {
        const last = i + 1 == parts.len;
        if (r.instances.get(.{ .scope = scope, .str = p })) |child| {
            scope = child;
        } else if (first and p == r.scope_info.items[0].name) {
            scope = 0;
        } else if (last) {
            const at = (if (parts.len == 1) r.lookup(scope, p) else r.names.get(.{ .scope = scope, .str = p })) orelse
                return r.exprFail(e, "$dumpvars names a module instance or a variable");
            return .{ .slot = at };
        } else return r.exprFail(e, "undeclared instance in a hierarchical reference");
        first = false;
    }
    return .{ .scope = scope };
}

// ---- the tasks ----------------------------------------------------------------

pub fn task(r: *Run, a: std.mem.Allocator, op: Op, args: []const Ast.ExprId, tok: u32) Error!void {
    const v = &r.vcd;
    switch (op) {
        .file => if (args.len == 1 and !v.started) {
            const name = (try @import("system.zig").text(a, try exec.eval(r, a, args[0], 0))) orelse return;
            v.name = try r.arena.dupe(u8, name);
        },
        .vars => {
            if (v.selected_at) |t| if (t != r.scheduler.now or v.started)
                return r.fail(tok, "§18.1.2: every $dumpvars shall execute at the same simulation time", .{});
            v.selected_at = r.scheduler.now;
            v.tok = tok;
            if (args.len == 0) {
                try v.scopes.put(r.arena, 0, 0);
            } else {
                const levels: u32 = std.math.lossyCast(u32, (try exec.eval(r, a, args[0], 0)).asInt() orelse 0);
                // "The argument 0 applies only to subsequent arguments that
                // specify module instances, and not to individual variables."
                for (args[1..]) |e| switch (try target(r, e)) {
                    .scope => |s| try v.scopes.put(r.arena, s, levels),
                    .slot => |s| try v.slots.put(r.arena, s, {}),
                };
            }
            // §18.1.3: dumping starts at the END of the current time unit.
            try exec.requestVcd(r);
        },
        .limit => v.limit = std.math.lossyCast(u64, (try exec.eval(r, a, args[0], 0)).asInt() orelse 0),
        // Every section is written as it happens, so there is no buffer of
        // this writer's own for §18.1.6 to empty.
        .flush => {},
        .off => if (v.started and v.on) {
            try changes(r, a);
            try checkpoint(r, a, "$dumpoff", true);
            v.on = false;
        },
        .on => if (v.started and !v.on) {
            v.on = true;
            try checkpoint(r, a, "$dumpon", false);
        },
        .all => if (v.started and v.on) {
            try changes(r, a);
            try checkpoint(r, a, "$dumpall", false);
        },
    }
}

/// The end of a time step with dumped changes, or the first one after
/// `$dumpvars`: the header and the initial `$dumpvars` section, or the changes.
pub fn tick(r: *Run, a: std.mem.Allocator) Error!void {
    r.vcd.pending = false;
    if (r.vcd.started) return changes(r, a);
    try header(r, a);
    try checkpoint(r, a, "$dumpvars", false);
}

/// §17.4.1 `$finish` ends the run before the step's `.vcd_tick` dispatches;
/// what that step changed is still part of the dump.
pub fn finish(r: *Run, a: std.mem.Allocator) Error!void {
    if (r.vcd.pending) try tick(r, a);
}

// ---- the file (§18.2) ---------------------------------------------------------

fn put(r: *Run, bytes: []const u8) Error!void {
    const v = &r.vcd;
    if (v.limited or bytes.len == 0) return;
    const f = v.file orelse return;
    const io = r.io.?; // `header` opened the file with it
    var out = bytes;
    // §18.1.5: at the limit "the dumping stops, and a comment is inserted".
    if (v.limit) |lim| if (v.pos + bytes.len > lim) {
        out = "$comment $dumplimit reached $end\n";
        v.limited = true;
    };
    f.writePositionalAll(io, out, v.pos) catch return r.fail(v.tok, "cannot write the dump file `{s}`", .{v.name});
    v.pos += out.len;
}

fn header(r: *Run, a: std.mem.Allocator) Error!void {
    const v = &r.vcd;
    const io = r.io orelse return r.fail(v.tok, "$dumpvars needs a filesystem to write `{s}`", .{v.name});
    v.file = std.Io.Dir.cwd().createFile(io, v.name, .{}) catch return r.fail(v.tok, "cannot create the dump file `{s}`", .{v.name});
    v.started = true;
    var w: std.Io.Writer.Allocating = .init(a);
    const t = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, @divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s))) };
    const yd = t.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = t.getDaySeconds();
    try w.writer.print("$date\n\t{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n$end\n", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
    // ponytail: §18.2.3.8 wants the unevaluated `$dumpfile` argument; this
    // prints the name it evaluated to, which is the same text for a literal.
    try w.writer.print("$version\n\tVerA\n\t$dumpfile(\"{s}\")\n$end\n", .{v.name});
    // Ticks are the precision (`Time.Scale`'s global), so the file's unit
    // is the precision: `time_number` 1, 10 or 100 of an SI unit.
    const e = r.finest;
    const units = [_][]const u8{ "fs", "ps", "ns", "us", "ms", "s" };
    const k: i32 = @divFloor(e, 3);
    try w.writer.print("$timescale {d}{s} $end\n", .{ std.math.pow(u32, 10, @intCast(e - 3 * k)), units[@intCast(k + 5)] });
    try dumpScope(r, &w, 0, null);
    try w.writer.writeAll("$enddefinitions $end\n");
    try put(r, w.written());
}

/// One scope and what it dumps, or nothing when nothing below it is
/// selected. `inherited` is the level count a selected ancestor passes down:
/// null none, 0 every level, n that many more.
fn dumpScope(r: *Run, aw: *std.Io.Writer.Allocating, s: u32, inherited: ?u32) Error!void {
    const v = &r.vcd;
    const w = &aw.writer;
    const info = r.scope_info.items[s];
    const own = v.scopes.get(s);
    const eff: ?u32 = if (inherited == null) own else if (own == null) inherited else if (inherited.? == 0 or own.? == 0) 0 else @max(inherited.?, own.?);
    const mark = aw.written().len;
    try w.print("$scope {s} {s}", .{ if (info.lexical) "begin" else "module", r.file.str(info.name) });
    if (info.index) |i| try w.print("[{d}]", .{i});
    try w.writeAll(" $end\n");
    const body = aw.written().len;
    if (!info.lexical) {
        const m = for (r.file.modules) |*m| {
            if (m.name == info.module) break m;
        } else unreachable; // every instance scope was minted from a module
        var names: std.ArrayList(Ast.StrId) = .empty;
        for (m.ports) |p| try names.append(r.arena, p.name);
        for (m.nets) |n| try names.append(r.arena, n.name);
        for (m.vars) |x| try names.append(r.arena, x.name);
        for (names.items, 0..) |name, i| {
            if (std.mem.indexOfScalar(Ast.StrId, names.items[0..i], name) != null) continue;
            const at = r.names.get(.{ .scope = s, .str = name }) orelse continue;
            if (r.arrays.contains(at) or r.params.contains(at) or r.events.contains(at)) continue;
            if (eff == null and !v.slots.contains(at)) continue;
            try variable(r, w, m, name, at);
        }
    }
    // A generate iteration is a `begin` scope of its instance, not a level.
    const down: ?u32 = if (info.lexical) eff else if (eff) |n| (if (n == 0) 0 else if (n == 1) null else n - 1) else null;
    for (r.scope_info.items, 0..) |child, i| {
        if (i == 0 or i == s or child.parent != s or (child.lexical and child.index == null)) continue;
        try dumpScope(r, aw, @intCast(i), down);
    }
    if (aw.written().len == body) {
        aw.shrinkRetainingCapacity(mark);
        return;
    }
    try w.writeAll("$upscope $end\n");
}

/// §18.2.3.7 `$var var_type size identifier_code reference $end`.
fn variable(r: *Run, w: *std.Io.Writer, m: *const Ast.ModuleDecl, name: Ast.StrId, at: u32) Error!void {
    const v = &r.vcd;
    const code: u32 = for (v.codes.items, 0..) |c, i| {
        if (c.slot == at) break @intCast(i);
    } else blk: {
        try v.codes.append(r.arena, .{ .slot = at, .last = try r.arena.alloc(u64, r.values[at].planes.len) });
        r.watch[at].insert(.vcd);
        break :blk @intCast(v.codes.items.len - 1);
    };
    const kind: []const u8 = if (r.net_of.get(at)) |n| switch (r.nets[n].kind) {
        // "a net of net type uwire shall have a variable type of wire"
        .uwire => "wire",
        .wreal => "real",
        .wire, .tri, .tri0, .tri1, .triand, .trior, .trireg, .wand, .wor, .supply0, .supply1 => @tagName(r.nets[n].kind),
    } else if (r.reals.contains(at)) "real" else for (m.vars) |x| {
        if (x.name == name) break switch (x.storage) {
            .reg => "reg",
            .time => "time",
            .variable => "integer",
        };
    } else "reg";
    try w.print("$var {s} {d} ", .{ kind, r.values[at].width });
    try codeText(w, code);
    try w.print(" {s}", .{r.file.str(name)});
    if (r.vec_ranges.get(at)) |range| try w.print(" [{d}:{d}]", .{ range.msb, range.lsb });
    try w.writeAll(" $end\n");
}

/// §18.2.1 identifier codes, "composed of the printable characters ... from
/// ! to ~": code 0 is `!`, and a longer code counts on in base 94.
fn codeText(w: *std.Io.Writer, code: u32) Error!void {
    var n = code;
    while (true) {
        try w.writeByte(@intCast('!' + n % 94));
        if (n < 94) return;
        n = n / 94 - 1;
    }
}

/// `#time`, once per time step however many sections it carries.
fn time(r: *Run, w: *std.Io.Writer) Error!void {
    if (r.vcd.last_time == r.scheduler.now) return;
    r.vcd.last_time = r.scheduler.now;
    try w.print("#{d}\n", .{r.scheduler.now});
}

/// §18.2.3.9-§18.2.3.12: a section holding every dumped variable — as x for
/// `$dumpoff` — which then counts as dumped.
fn checkpoint(r: *Run, a: std.mem.Allocator, keyword: []const u8, as_x: bool) Error!void {
    var w: std.Io.Writer.Allocating = .init(a);
    try time(r, &w.writer);
    try w.writer.print("{s}\n", .{keyword});
    for (r.vcd.codes.items, 0..) |c, i| {
        try value(r, &w.writer, @intCast(i), as_x);
        @memcpy(c.last, r.values[c.slot].planes);
    }
    try w.writer.writeAll("$end\n");
    try put(r, w.written());
}

/// The variables whose value is not the one last dumped.
fn changes(r: *Run, a: std.mem.Allocator) Error!void {
    if (!r.vcd.on) return;
    var w: std.Io.Writer.Allocating = .init(a);
    // ponytail: every dumped variable is compared each dumped step; a changed
    // list fed by `store` replaces the scan when a design dumps thousands.
    for (r.vcd.codes.items, 0..) |c, i| {
        if (std.mem.eql(u64, c.last, r.values[c.slot].planes)) continue;
        if (w.written().len == 0) try time(r, &w.writer);
        try value(r, &w.writer, @intCast(i), false);
        @memcpy(c.last, r.values[c.slot].planes);
    }
    try put(r, w.written());
}

/// §18.2.2 one value change: a scalar's value and code with no space, a
/// vector's `b` digits then one space, a real's `r` and `%.16g`.
fn value(r: *Run, w: *std.Io.Writer, code: u32, as_x: bool) Error!void {
    const at = r.vcd.codes.items[code].slot;
    const v = r.values[at];
    if (r.reals.contains(at) and !as_x) {
        var buf: [64]u8 = undefined;
        try w.print("r{s} ", .{zCReal(&buf, @bitCast(v.values()[0]), 'g', 0, 0, 16)});
    } else if (v.width == 1) {
        try w.writeByte(if (as_x) 'x' else digit(v.bit(0)));
    } else {
        try w.writeByte('b');
        var i = v.width;
        if (as_x) i = 1;
        // Table 18-1: a leading digit the next one would extend to anyway is
        // dropped — 0 before 0 or 1, x before x, z before z.
        while (i > 1) : (i -= 1) {
            const top = v.bit(i - 1);
            const next = v.bit(i - 2);
            const redundant = if (top == .zero) next == .zero or next == .one else top != .one and top == next;
            if (!redundant) break;
        }
        while (i > 0) : (i -= 1) try w.writeByte(if (as_x) 'x' else digit(v.bit(i - 1)));
        try w.writeByte(' ');
    }
    try codeText(w, code);
    try w.writeByte('\n');
}

fn digit(b: Int.Bit) u8 {
    return switch (b) {
        .zero => '0',
        .one => '1',
        .x => 'x',
        .z => 'z',
    };
}
