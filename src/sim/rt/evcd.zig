//! IEEE 1364-2005 §18.3/§18.4 extended VCD in a native executable: the
//! `$dumpports` calls `emit` resolved at compile time (`File`), and per file
//! what has been written -> the file `digital/evcd.zig` writes. A port's
//! state is read from its net's driver rows in `rt.net`, split at the
//! instance boundary (`Port.inside`, §18.4.3.2). Changes are looked for at
//! the end of every time step (`State.count`, and the run's end), which is
//! where the interpreter's `.vcd_tick` writes them; a step whose ports did
//! not change writes nothing either way.
const std = @import("std");
const Ast = @import("frontend").Ast;
const root = @import("root.zig");
const State = root.State;
const Error = root.Error;
const net = @import("net.zig");
const dvcd = @import("../digital/vcd.zig");
const devcd = @import("../digital/evcd.zig");
const Signal = @import("../digital/net.zig").Signal;

/// §18.3 the control tasks after `$dumpports`.
pub const Op = devcd.Op;

/// One dumped port (§18.4.2) of a `File`.
pub const Port = struct {
    off: u32,
    width: u32,
    /// Its `rt.net` row; null for an output declared as a variable.
    net: ?u32 = null,
    dir: Ast.Direction,
    /// Per driver of the net, in its row's order: inside the dumped
    /// instance, so the port's output side.
    inside: []const bool = &.{},
};

/// One `$dumpports` call: its file, the call as written, the tick's power
/// of ten, and the `$scope`/`$var port` text of its ports.
pub const File = struct {
    name: []const u8,
    call: []const u8,
    finest: i32,
    header: []const u8,
    ports: []const Port,
};

/// What a run has done with one `File`.
pub const Live = struct {
    selected: bool = false,
    started: bool = false,
    on: bool = true,
    limit: ?u64 = null,
    limited: bool = false,
    pos: u64 = 0,
    last_time: ?u64 = null,
    file: ?std.Io.File = null,
    /// Per port, the state text last written.
    last: [][]u8 = &.{},
};

/// `$dumpports` call `k` runs: its file is written at the end of the step.
pub fn select(s: *State, k: u32) Error!void {
    if (s.quiet) return;
    // "the execution of all $dumpports tasks shall be at the same
    // simulation time" (§18.3.1).
    if (s.ports_at) |t| if (t != s.sched.now) return s.fail("§18.3.1: every $dumpports shall execute at the same simulation time", .{});
    s.ports_at = s.sched.now;
    const f = &s.port_live[k];
    if (f.selected) return s.fail("§18.3.1: the same file_pathname shall not be given to two $dumpports calls", .{});
    f.selected = true;
    f.last = try s.gpa.alloc([]u8, s.port_files[k].ports.len);
    @memset(f.last, &.{});
}

/// `$dumpportsoff`, `on`, `all`, `limit` (`size`) or `flush` of file `k`,
/// or of every file when `k` is null (`devcd.task`).
pub fn control(s: *State, op: Op, k: ?u32, size: u64) Error!void {
    if (s.quiet) return;
    for (s.port_live, s.port_files, 0..) |*f, file, i| {
        if (k) |want| if (want != i) continue;
        if (!f.selected) continue;
        switch (op) {
            .ports => unreachable, // `select`
            .limit => f.limit = size,
            .flush => {},
            .off => if (f.started and f.on) {
                try changes(s, f, file, s.sched.now);
                try checkpoint(s, f, file, "$dumpportsoff", true, s.sched.now);
                f.on = false;
            },
            .on => if (f.started and !f.on) {
                f.on = true;
                try checkpoint(s, f, file, "$dumpportson", false, s.sched.now);
            },
            .all => if (f.started and f.on) {
                try changes(s, f, file, s.sched.now);
                try checkpoint(s, f, file, "$dumpportsall", false, s.sched.now);
            },
        }
    }
}

/// The end of the step at tick `at`: each new file's header and
/// `$dumpports` section, and each running file's changes.
pub fn tick(s: *State, at: u64) Error!void {
    if (s.quiet) return;
    for (s.port_live, s.port_files) |*f, file| {
        if (!f.selected) continue;
        if (f.started) {
            try changes(s, f, file, at);
            continue;
        }
        f.file = std.Io.Dir.cwd().createFile(s.io, file.name, .{}) catch return s.fail("cannot create the dump file `{s}`", .{file.name});
        f.started = true;
        var w: std.Io.Writer.Allocating = .init(s.gpa);
        defer w.deinit();
        try dvcd.preamble(&w.writer, s.io, file.call, file.finest);
        try w.writer.writeAll(file.header);
        try put(s, f, file, w.written());
        try checkpoint(s, f, file, "$dumpports", false, at);
    }
}

/// The run is over at tick `at`: the step's changes, then §18.3.6.1's
/// `$vcdclose`.
pub fn close(s: *State, at: u64) Error!void {
    if (s.quiet or s.port_live.len == 0) return;
    try tick(s, at);
    for (s.port_live, s.port_files) |*f, file| if (f.started) {
        var buf: [64]u8 = undefined;
        try put(s, f, file, std.mem.print(&buf, "$vcdclose #{d} $end\n", .{at}) catch unreachable);
    };
}

fn put(s: *State, f: *Live, file: File, bytes: []const u8) Error!void {
    if (f.limited or bytes.len == 0) return;
    const out_file = f.file orelse return;
    var out = bytes;
    // §18.3.4: "When this filesize is reached, the dumping stops, and a
    // comment is inserted into file_pathname indicating the size limit was
    // attained."
    if (f.limit) |lim| if (f.pos + bytes.len > lim) {
        out = "$comment $dumpportslimit reached $end\n";
        f.limited = true;
    };
    out_file.writePositionalAll(s.io, out, f.pos) catch return s.fail("cannot write the dump file `{s}`", .{file.name});
    f.pos += out.len;
}

fn time(f: *Live, w: *std.Io.Writer, at: u64) std.Io.Writer.Error!void {
    if (f.last_time == at) return;
    f.last_time = at;
    try w.print("#{d}\n", .{at});
}

/// A section of every port (`as_x`: each unknown, for `$dumpportsoff`),
/// which then counts as written.
fn checkpoint(s: *State, f: *Live, file: File, keyword: []const u8, as_x: bool, at: u64) Error!void {
    var w: std.Io.Writer.Allocating = .init(s.gpa);
    defer w.deinit();
    try time(f, &w.writer, at);
    try w.writer.print("{s}\n", .{keyword});
    for (file.ports, f.last, 0..) |p, *last, n| {
        const text = if (as_x) try unknown(s.gpa, p) else try state(s, p);
        s.gpa.free(last.*);
        last.* = text;
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try w.writer.writeAll("$end\n");
    try put(s, f, file, w.written());
}

/// The ports whose state is not the one last written.
fn changes(s: *State, f: *Live, file: File, at: u64) Error!void {
    if (!f.on) return;
    var w: std.Io.Writer.Allocating = .init(s.gpa);
    defer w.deinit();
    for (file.ports, f.last, 0..) |p, *last, n| {
        const text = try state(s, p);
        if (std.mem.eql(u8, text, last.*)) {
            s.gpa.free(text);
            continue;
        }
        if (w.written().len == 0) try time(f, &w.writer, at);
        s.gpa.free(last.*);
        last.* = text;
        try w.writer.print("{s} <{d}\n", .{ text, n });
    }
    try put(s, f, file, w.written());
}

/// §18.4.3 `p<port_value> <0_strength> <1_strength>` of port `p`
/// (`devcd.state`), allocated from `s.gpa`.
fn state(s: *State, p: Port) Error![]u8 {
    var chars = try s.gpa.alloc(u8, 3 * p.width);
    defer s.gpa.free(chars);
    for (0..p.width) |i| {
        const bit: u32 = @intCast(p.width - 1 - i);
        var in: Signal = .{};
        var out: Signal = .{};
        if (p.net) |k| {
            for (s.nets.nets[k].drivers, p.inside) |d, inside| {
                const c = net.contribution(&s.nets, d, bit);
                if (inside) out = out.combine(c) else in = in.combine(c);
            }
        } else out = .of(shown(s, p, bit), .strong, .strong);
        const st = devcd.portState(p.dir, in, out);
        chars[i] = st.c;
        chars[p.width + i] = '0' + st.s0;
        chars[2 * p.width + i] = '0' + st.s1;
    }
    return s.gpa.print("p{s} {s} {s}", .{ chars[0..p.width], chars[p.width .. 2 * p.width], chars[2 * p.width ..] });
}

fn shown(s: *const State, p: Port, at: u32) @import("frontend").Integer.Bit {
    const o = p.off + at / 64;
    const v: u2 = @intCast(s.v[o] >> @intCast(at % 64) & 1);
    const x: u2 = if (root.logic.two) 0 else @intCast(s.x[o] >> @intCast(at % 64) & 1);
    return @fromBackingInt(@intCast(v | x << 1));
}

/// `$dumpportsoff`'s X: Table 18-7's unknown of the port's direction.
fn unknown(gpa: std.mem.Allocator, p: Port) Error![]u8 {
    const c: u8 = switch (p.dir) {
        .input => 'N',
        .output => 'X',
        .inout, .unspecified => '?',
    };
    const out = try gpa.alloc(u8, 3 * p.width + 3);
    out[0] = 'p';
    @memset(out[1..][0..p.width], c);
    out[1 + p.width] = ' ';
    @memset(out[2 + p.width ..][0..p.width], '6');
    out[2 + 2 * p.width] = ' ';
    @memset(out[3 + 2 * p.width ..][0..p.width], '6');
    return out;
}
