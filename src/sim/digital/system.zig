//! IEEE 1364-2005 §17 system tasks that keep state of their own: §17.2's
//! file input (and §17.2.3's string output), §17.5's programmable logic
//! arrays and §17.6's stochastic queues.
//!
//! In: a task's argument expressions and the `Run`. Out: values written to
//! the task's output arguments, and (queues) `Run.queues`.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const exec = @import("exec.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;

// ---- §17.6 stochastic analysis queues ---------------------------------------

/// The four §17.6 queue tasks; `$q_full` is a function (`SysFn.q_full`).
pub const QueueOp = enum { initialize, add, remove, exam };

const Job = struct { id: i64, info: i64, arrived: u64 };

/// One §17.6.1 queue: FIFO (type 1) or LIFO (type 2) of at most `max` jobs,
/// with what §17.6.4's statistics are computed from.
pub const Queue = struct {
    lifo: bool,
    max: u64,
    jobs: std.ArrayList(Job) = .empty,
    /// §17.6.4 code 3, "the maximum queue length" reached.
    peak: u64 = 0,
    last_arrival: ?u64 = null,
    interarrivals: u64 = 0,
    interarrival_sum: u64 = 0,
    waits: u64 = 0,
    wait_sum: u64 = 0,
    wait_min: ?u64 = null,
};

// Table 17-16's status codes.
const ok = 0;
const full = 1;
const undefined_id = 2;
const empty = 3;
const bad_type = 4;
const bad_length = 5;
const duplicate_id = 6;

fn int(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return (try exec.eval(self, a, e, 0)).asInt();
}

/// The simulation time in the module's unit, which §17.6's statistics are in.
fn now(self: *Run) u64 {
    return self.timeOf(self.scope).scale.unitsAt(self.scheduler.now);
}

/// One queue task (§17.6.1-§17.6.3, §17.6.5): the status is the last
/// argument of all four, and is always written.
pub fn queueTask(self: *Run, a: std.mem.Allocator, op: QueueOp, args: []const Ast.ExprId) Error!void {
    const id = try int(self, a, args[0]);
    const in1: ?i64 = if (op == .initialize or op == .add or op == .exam) try int(self, a, args[1]) else null;
    const in2: ?i64 = if (op == .initialize or op == .add) try int(self, a, args[2]) else null;
    const r = try queueStep(&self.queues, self.arena, op, id, in1, in2, now(self));
    if (r.out[0]) |v| try exec.assignInt(self, a, args[1], v);
    if (r.out[1]) |v| try exec.assignInt(self, a, args[2], v);
    try exec.assignInt(self, a, args[3], r.status);
}

pub const Queues = std.AutoHashMapUnmanaged(i64, Queue);

/// A queue task's status and the values its output arguments take:
/// `$q_remove`'s job id and information (`out[0]`, `out[1]`), `$q_exam`'s
/// statistic (`out[1]`).
pub const QueueResult = struct { status: i64, out: [2]?i64 = .{ null, null } };

/// §17.6 queue task `op` on queue `id` at time `t` (the module's unit):
/// `in1`/`in2` are its second and third arguments where they are inputs,
/// each an integer or null for x/z. The one queue engine the interpreter
/// and a native executable share.
pub fn queueStep(queues: *Queues, gpa: std.mem.Allocator, op: QueueOp, id: ?i64, in1: ?i64, in2: ?i64, t: u64) std.mem.Allocator.Error!QueueResult {
    switch (op) {
        .initialize => {
            if (in1 != 1 and in1 != 2) return .{ .status = bad_type };
            if (in2 == null or in2.? <= 0) return .{ .status = bad_length };
            const entry = try queues.getOrPut(gpa, id orelse return .{ .status = undefined_id });
            if (entry.found_existing) return .{ .status = duplicate_id };
            entry.value_ptr.* = .{ .lifo = in1 == 2, .max = @intCast(in2.?) };
            return .{ .status = ok };
        },
        .add => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            if (q.jobs.items.len >= q.max) return .{ .status = full };
            if (q.last_arrival) |last| {
                q.interarrivals += 1;
                q.interarrival_sum += t - last;
            }
            q.last_arrival = t;
            try q.jobs.append(gpa, .{ .id = in1 orelse 0, .info = in2 orelse 0, .arrived = t });
            q.peak = @max(q.peak, q.jobs.items.len);
            return .{ .status = ok };
        },
        .remove => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            if (q.jobs.items.len == 0) return .{ .status = empty };
            const job = if (q.lifo) q.jobs.pop().? else q.jobs.orderedRemove(0);
            const wait = t - job.arrived;
            q.waits += 1;
            q.wait_sum += wait;
            q.wait_min = @min(q.wait_min orelse wait, wait);
            return .{ .status = ok, .out = .{ job.id, job.info } };
        },
        // §17.6.4 Table 17-15's statistics codes.
        .exam => {
            const q = queues.getPtr(id orelse return .{ .status = undefined_id }) orelse return .{ .status = undefined_id };
            const value: u64 = switch (in1 orelse 0) {
                1 => q.jobs.items.len,
                2 => if (q.interarrivals == 0) 0 else q.interarrival_sum / q.interarrivals,
                3 => q.peak,
                4 => q.wait_min orelse 0,
                5 => longest: {
                    var w: u64 = 0;
                    for (q.jobs.items) |j| w = @max(w, t - j.arrived);
                    break :longest w;
                },
                6 => if (q.waits == 0) 0 else q.wait_sum / q.waits,
                else => return .{ .status = undefined_id },
            };
            return .{ .status = ok, .out = .{ null, @intCast(value) } };
        },
    }
}

/// §17.6.5 `$q_full(q_id, status)`: 1 when the queue holds its maximum.
pub fn queueFull(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const r = queueIsFull(&self.queues, try int(self, a, args[0]));
    try exec.assignInt(self, a, args[1], r.status);
    return r.full;
}

/// `$q_full` of queue `id`: its status and whether it holds its maximum.
pub fn queueIsFull(queues: *const Queues, id: ?i64) struct { status: i64, full: i64 } {
    const q = if (id) |i| queues.getPtr(i) else null;
    const found = q orelse return .{ .status = undefined_id, .full = 0 };
    return .{ .status = ok, .full = @intFromBool(found.jobs.items.len >= found.max) };
}

// ---- §17.9 probabilistic distribution functions -----------------------------

const rng = @import("kernels").rng_kernels;

/// §17.9.3 Table 17-17: `$random` and the seven `$dist_*` functions.
pub const Dist = enum { random, uniform, normal, exponential, poisson, chi_square, t, erlang };

/// A draw's value and the seed its inout argument is written back with.
pub const Draw = struct { value: i32, seed: i32 };

/// §17.9.3's `rtl_dist_*` over the listing's 32-bit `long` seed; `a` and `b`
/// are the arguments after the seed. Null where the listing prints its
/// "must have positive" warning instead of drawing: the value is 0 and the
/// seed is left as it was (§17.9.2: mean, degree_of_freedom and k_stage
/// "shall be greater than 0").
pub fn dist(f: Dist, seed: i32, a: i32, b: i32) ?Draw {
    const bad = switch (f) {
        .random, .uniform, .normal => false,
        .exponential, .poisson, .chi_square, .t => a <= 0,
        .erlang => a <= 0 or b <= 0,
    };
    if (bad) return null;
    const s: i64 = seed;
    const x: f64 = @floatFromInt(a);
    const y: f64 = @floatFromInt(b);
    // Each kernel is a pure function of the seed; its `Next` twin replays
    // the same draw for the written-back seed.
    const r: f64, const next: f64 = switch (f) {
        .random => .{ rng.zRngRand(s), rng.zRngRandNext(s) },
        .uniform => .{ rng.zRngIUniform(s, x, y), rng.zRngIUniformNext(s, x, y) },
        .normal => .{ rng.zRngNormal(s, x, y), rng.zRngNormalNext(s, x, y) },
        .exponential => .{ rng.zRngExponential(s, x), rng.zRngExponentialNext(s, x) },
        .poisson => .{ rng.zRngPoisson(s, x), rng.zRngPoissonNext(s, x) },
        .chi_square => .{ rng.zRngChiSquare(s, x), rng.zRngChiSquareNext(s, x) },
        .t => .{ rng.zRngT(s, x), rng.zRngTNext(s, x) },
        .erlang => .{ rng.zRngErlang(s, x, y), rng.zRngErlangNext(s, x, y) },
    };
    // The listing's `(long)(r + 0.5)`, mirrored for a negative r; the
    // integer-valued draws are unchanged by it.
    const m = @trunc(@abs(r) + 0.5);
    return .{ .value = std.math.lossyCast(i32, if (r >= 0) m else -m), .seed = @intFromFloat(next) };
}

/// The seed or integer argument `e` as the listing's 32-bit `long`: its
/// low 32 bits, 0 when it holds an x or z bit.
fn long(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!i32 {
    return @truncate(try int(self, a, e) orelse 0);
}

/// §17.9 one call of `$random` or a `$dist_*` function. A seed argument is
/// read and written back (§17.9.1, §17.9.2: "an inout argument"); a
/// seedless `$random` advances `Run.random_seed`.
pub fn random(self: *Run, a: std.mem.Allocator, f: Dist, args: []const Ast.ExprId, tok: u32) Error!i32 {
    if (args.len == 0) {
        const d = dist(.random, self.random_seed, 0, 0).?;
        self.random_seed = d.seed;
        return d.value;
    }
    const seed = try long(self, a, args[0]);
    const x = if (args.len > 1) try long(self, a, args[1]) else 0;
    const y = if (args.len > 2) try long(self, a, args[2]) else 0;
    const d = dist(f, seed, x, y) orelse {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(.lower, .W1151, .{ .start = start, .end = start }, dist_warning, .{});
        return 0;
    };
    try exec.assignInt(self, a, args[0], d.seed);
    return d.value;
}

/// The text of the listing's `print_error` for a non-positive argument.
pub const dist_warning = "a $dist_ mean, degree of freedom or k_stage is not positive: the result is 0 and the seed is unchanged";

// ---- §17.2 file input and output --------------------------------------------

const contract = @import("contract");
const fk = @import("kernels").file_kernels;

/// This engine's own descriptor table: `file_kernels`, the table the analog
/// devices run, so both engines answer §17.2 one way (IEEE 1364-2005 §17.2.1's
/// encodings: an mcd's bit 0 is standard output, an fd has bit 31 set and
/// 0..2 are the standard streams).
pub const own: contract.FileIo = .{ .open = fk.zFOpen, .close = fk.zFClose, .put = fk.zFPut, .getc = fk.zFGetc, .ungetc = fk.zFUngetc, .tell = fk.zFTell, .seek = fk.zFSeek, .eof = fk.zFEof };

/// VAMS §9.5.1.2: ONE descriptor table per simulation — the host's
/// (`Run.file_io`: a mixed simulation's device table), else this engine's
/// own, which only an engine given filesystem access (`Options.io`) opens
/// files through.
fn table(self: *Run) ?contract.FileIo {
    return self.file_io orelse if (self.io != null) own else null;
}

/// The §17.2 functions an expression can call.
pub const FileFn = enum { fopen, fgetc, ungetc, ftell, fseek, rewind, feof, sscanf };

/// The characters an operand holds (§17.1.1.7's reading: 8 bits each, leading
/// NULs dropped), or null when any bit is x or z.
pub fn text(a: std.mem.Allocator, v: Int.Literal) Error!?[]const u8 {
    if (v.hasUnknown()) return null;
    const bytes = (v.width + 7) / 8;
    var out: std.ArrayList(u8) = .empty;
    var n = bytes;
    while (n != 0) {
        n -= 1;
        var c: u8 = 0;
        for (0..8) |k| {
            const at = n * 8 + @as(u32, @intCast(k));
            if (at < v.width and v.bit(at) == .one) c |= @as(u8, 1) << @intCast(k);
        }
        if (c == 0 and out.items.len == 0) continue;
        try out.append(a, c);
    }
    return out.items;
}

/// A descriptor is "a 32-bit value" (§17.2.1): its low 32 bits, however the
/// variable holding it is signed — `integer fd` is the clause's own example.
fn descriptor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return low32(try int(self, a, e));
}

fn low32(d: ?i64) ?i64 {
    return (d orelse return null) & 0xffff_ffff;
}

/// One §17.2 function call; every one of them returns an integer.
pub fn fileCall(self: *Run, a: std.mem.Allocator, f: FileFn, args: []const Ast.ExprId, _: u32) Error!i64 {
    if (f == .sscanf) return scanCall(self, a, args);
    const t = table(self) orelse return if (f == .fopen) 0 else -1;
    if (f == .fopen) {
        const name = try text(a, try exec.eval(self, a, args[0], 0));
        const mode = if (args.len == 1) null else try text(a, try exec.eval(self, a, args[1], 0));
        return fopen(t, a, self.file_name, name, mode, args.len == 1);
    }
    var v: [3]?i64 = .{ null, null, null };
    for (args, 0..) |arg, i| v[i] = try int(self, a, arg);
    return fileOp(t, f, v[0], v[1], v[2]);
}

/// §17.2.1 `$fopen(name)` (`mcd`) or `$fopen(name, type)` on the table `t`
/// of a source `file_name`: no type opens for writing and returns a
/// multichannel descriptor, one bit above bit 0; a Table 17-7 type returns
/// a file descriptor. 0 when the file cannot be opened, or `name` or `mode`
/// is null (an x or z bit).
pub fn fopen(t: contract.FileIo, a: std.mem.Allocator, file_name: []const u8, name: ?[]const u8, mode: ?[]const u8, mcd: bool) std.mem.Allocator.Error!i64 {
    const path = name orelse return 0;
    const ty = if (mcd) "w" else mode orelse return 0;
    const types = [_][]const u8{ "r", "rb", "w", "wb", "a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b", "ab+" };
    for (types) |allowed| {
        if (std.mem.eql(u8, allowed, ty)) break;
    } else return 0;
    // A file read is looked for beside the source first, as `$readmemh`
    // looks (`display.readSideFile`).
    if (ty[0] == 'r') if (std.fs.path.dirname(file_name)) |dir| {
        const d = t.open(try std.fs.path.join(a, &.{ dir, path }), ty, mcd);
        if (d != 0) return d;
    };
    return t.open(path, ty, mcd);
}

/// §17.2.4.1 / §17.2.4.2 / §17.2.5 / §17.2.8 on the table `t`, C's
/// semantics: `x`, `y`, `z` are the call's arguments in order, null where an
/// argument has an x or z bit (or is absent). EOF (-1) for an unknown one.
pub fn fileOp(t: contract.FileIo, f: FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
    const eof: i64 = -1;
    switch (f) {
        .fgetc => return t.getc(low32(x) orelse return eof),
        .ungetc => return t.ungetc(x orelse return eof, low32(y) orelse return eof),
        .ftell => return t.tell(low32(x) orelse return eof),
        // §17.2.5: whence 0 from the start, 1 from here, 2 from the end.
        .fseek, .rewind => {
            const d = low32(x) orelse return eof;
            if (f == .rewind) return t.seek(d, 0, 0);
            const offset = y orelse return eof;
            const whence = z orelse return eof;
            if (whence < 0 or whence > 2) return eof;
            return t.seek(d, offset, whence);
        },
        .feof => return t.eof(low32(x) orelse return eof),
        .fopen, .sscanf => unreachable, // `fopen` and `Scan`
    }
}

/// §17.2.7 `$fclose` of a file descriptor, or of every file a multichannel
/// descriptor's bits name.
pub fn fclose(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    if (table(self)) |t| _ = t.close(d);
}

/// §17.2.2 `$fdisplay`/`$fwrite` and their radix forms: the `$display` text
/// of the arguments after the descriptor, to every channel it names.
/// ponytail: `$fstrobe` and `$fmonitor` are not implemented.
pub fn fdisplay(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: @import("display.zig").Show) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    try @import("display.zig").display(self, args[1..], a, show);
    self.out = saved;
    try channels(table(self), self.io, self.out, d, buf.written());
}

/// `bytes` to every channel descriptor `d` names: bit 0 of an mcd and fd 1
/// (STDOUT) are the transcript `out`; fd 2 is STDERR; every other channel
/// is the table's.
pub fn channels(t: ?contract.FileIo, io: ?std.Io, out: *std.Io.Writer, d: i64, bytes: []const u8) std.Io.Writer.Error!void {
    const fd = d & (@as(i64, 1) << 31) != 0;
    const ch = d & 0x7fff_ffff;
    if ((fd and ch == 1) or (!fd and d & 1 != 0)) try out.writeAll(bytes);
    if (fd and ch == 2) if (io) |i| std.Io.File.stderr().writeStreamingAll(i, bytes) catch {};
    const files = if (fd) (if (ch > 2) d else 0) else d & ~@as(i64, 1);
    if (files != 0) if (t) |tt| {
        _ = tt.put(files, bytes);
    };
}

/// §17.2.4.3 `$sscanf(str, format, args...)` in the interpreter (`Scan`).
fn scanCall(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const input = try text(a, try exec.eval(self, a, args[0], 0));
    const format = try text(a, try exec.eval(self, a, args[1], 0));
    var sc: Scan = .init(input, format, args.len - 2);
    while (sc.next()) |x| switch (x.value) {
        .int => |v| try exec.assignInt(self, a, args[2 + x.arg], v),
        .chars => |c| try exec.assign(self, a, args[2 + x.arg], try stringValue(a, c)),
    };
    return sc.result;
}

/// §17.2.4.3 `$sscanf(str, format, args...)`: C's scanf over the characters
/// of `str`. Each `next` is one assignment to an output argument, in order;
/// once it returns null, `result` is how many were assigned, or EOF (-1)
/// when the input ends before the first conversion — and, the clause's own
/// rule, when either `str` or `format` has an x or z bit (null here).
/// ponytail: the integral conversions %d %h %x %o %b, %c and %s.
pub const Scan = struct {
    input: []const u8,
    format: []const u8,
    /// Output arguments the call has.
    outs: usize,
    at: usize = 0,
    i: usize = 0,
    result: i64 = 0,
    done: bool = false,

    /// Output argument `arg` (0 = the first after the format) takes an
    /// integer or, from `%s`, characters.
    pub const Assign = struct { arg: usize, value: union(enum) { int: i64, chars: []const u8 } };

    pub fn init(input: ?[]const u8, format: ?[]const u8, outs: usize) Scan {
        if (input == null or format == null) return .{ .input = "", .format = "", .outs = outs, .result = -1, .done = true };
        return .{ .input = input.?, .format = format.?, .outs = outs };
    }

    fn stop(self: *Scan, eof: bool) ?Assign {
        if (eof and self.result == 0) self.result = -1;
        self.done = true;
        return null;
    }

    pub fn next(self: *Scan) ?Assign {
        if (self.done) return null;
        const input = self.input;
        const format = self.format;
        while (self.i < format.len) : (self.i += 1) {
            const c = format[self.i];
            if (std.ascii.isWhitespace(c)) {
                while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) self.at += 1;
                continue;
            }
            if (c != '%' or self.i + 1 == format.len) {
                if (self.at >= input.len) return self.stop(true);
                if (input[self.at] != c) return self.stop(false);
                self.at += 1;
                continue;
            }
            self.i += 1;
            const conv = std.ascii.toLower(format[self.i]);
            if (conv == '%') {
                if (self.at >= input.len or input[self.at] != '%') return self.stop(false);
                self.at += 1;
                continue;
            }
            if (conv != 'c') while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) : (self.at += 1) {};
            if (self.at >= input.len) return self.stop(true);
            const arg: usize = @intCast(self.result);
            if (arg >= self.outs) return self.stop(false);
            const value: @FieldType(Assign, "value") = switch (conv) {
                'c' => blk: {
                    self.at += 1;
                    break :blk .{ .int = input[self.at - 1] };
                },
                's' => blk: {
                    const start = self.at;
                    while (self.at < input.len and !std.ascii.isWhitespace(input[self.at])) self.at += 1;
                    break :blk .{ .chars = input[start..self.at] };
                },
                'd', 'h', 'x', 'o', 'b' => blk: {
                    const radix: u8 = switch (conv) {
                        'd' => 10,
                        'o' => 8,
                        'b' => 2,
                        else => 16,
                    };
                    const start = self.at;
                    if (conv == 'd' and (input[self.at] == '-' or input[self.at] == '+')) self.at += 1;
                    while (self.at < input.len and (std.fmt.charToDigit(input[self.at], radix) catch null) != null) self.at += 1;
                    break :blk .{ .int = std.fmt.parseInt(i64, input[start..self.at], radix) catch return self.stop(false) };
                },
                else => return self.stop(false),
            };
            self.i += 1;
            self.result += 1;
            return .{ .arg = arg, .value = value };
        }
        return self.stop(false);
    }
};

/// IEEE 1364-2005 §4.2.3 a string as a value: 8 bits a character, the last
/// character in the low byte. Assigning it pads or truncates on the left.
fn stringValue(a: std.mem.Allocator, s: []const u8) Error!Int.Literal {
    const v = try filled(a, @intCast(@max(1, s.len) * 8), false, .zero);
    for (s, 0..) |ch, k| setBitsOfByte(v, @intCast((s.len - 1 - k) * 8), ch);
    return v;
}

/// §17.2.3 `$swrite`/`$sformat`: `$fwrite`'s text of the arguments after the
/// first, assigned to the first "using the string assignment to variable
/// rules". `compile` has already required `$sformat`'s format to be a literal,
/// which is the one argument `display` reads as a format there.
/// ponytail: a string literal AFTER `$sformat`'s format is read as a further
/// format, where §17.2.3 says "No other arguments are interpreted as format
/// strings"; split the walk when a source needs that.
pub fn sformat(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: @import("display.zig").Show) Error!void {
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    try @import("display.zig").display(self, args[1..], a, show);
    self.out = saved;
    try exec.assign(self, a, args[0], try stringValue(a, buf.written()));
}

fn setBitsOfByte(v: Int.Literal, lo: u32, byte: u8) void {
    for (0..8) |k| if (byte & (@as(u8, 1) << @intCast(k)) != 0) setBit(v, lo + @as(u32, @intCast(k)), .one);
}

// ---- §17.5 programmable logic arrays ----------------------------------------

/// One of §17.5's sixteen PLA tasks: `$async$and$array` and the rest. The
/// logic is applied to each personality row's selected inputs.
pub const Pla = struct {
    logic: enum { @"and", @"or", nand, nor },
    /// `plane` (§17.5.4): 0 selects the complement, 1 the input, z/? nothing.
    /// `array`: 1 selects the input, 0 nothing.
    plane: bool,
    /// `async` re-evaluates whenever an input or the personality changes.
    async_: bool,
};

pub const pla_tasks = blk: {
    var list: [16]struct { []const u8, Pla } = undefined;
    var n = 0;
    for (.{ "async", "sync" }) |timing| for (.{ "and", "or", "nand", "nor" }) |logic| for (.{ "array", "plane" }) |form| {
        list[n] = .{ "$" ++ timing ++ "$" ++ logic ++ "$" ++ form, .{
            .logic = @field(@FieldType(Pla, "logic"), logic),
            .plane = std.mem.eql(u8, form, "plane"),
            .async_ = std.mem.eql(u8, timing, "async"),
        } };
        n += 1;
    };
    break :blk list;
};

/// §17.5 one evaluation: row k of the personality memory (lowest address
/// first) computes output bit k; within a row, bit j of the personality
/// governs input j, both counted from the left. An unknown input selected by
/// a row makes it unknown unless the row's controlling value decides it.
/// ponytail: rows are taken lowest address first, which is the declaration
/// order of the ascending memories §17.5's examples use.
pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void {
    const base = try self.slot(args[0]);
    const arr = self.arrays.get(base).?; // compile proved it is an array
    const in = try exec.eval(self, a, args[1], 0);
    const tt = try exec.targetType(self, args[2]);
    const out = try filled(a, tt.width, false, .x);
    const and_like = p.logic == .@"and" or p.logic == .nand;
    for (0..@min(arr.count, tt.width)) |k| {
        const row = self.values[base + @as(u32, @intCast(k))];
        var unknown = false;
        var decided = false;
        for (0..@min(row.width, in.width)) |j| {
            const sel = row.bit(@intCast(row.width - 1 - j));
            var b = in.bit(@intCast(in.width - 1 - j));
            if (p.plane) {
                if (sel == .zero) b = switch (b) {
                    .zero => .one,
                    .one => .zero,
                    else => .x,
                } else if (sel != .one) continue;
            } else if (sel == .zero) continue else if (sel != .one) b = .x;
            // `and` is decided by a 0, `or` by a 1.
            if (b == (if (and_like) Int.Bit.zero else Int.Bit.one)) decided = true;
            if (b == .x or b == .z) unknown = true;
        }
        const value: Int.Bit = if (decided) (if (and_like) .zero else .one) else if (unknown) .x else (if (and_like) .one else .zero);
        const inverted = p.logic == .nand or p.logic == .nor;
        setBit(out, @intCast(tt.width - 1 - k), if (!inverted) value else switch (value) {
            .zero => .one,
            .one => .zero,
            else => .x,
        });
    }
    try exec.assign(self, a, args[2], out);
}

// ---- tests ------------------------------------------------------------------

test "§17.2.4.3 $sscanf: conversions, a mismatch stops, unknown input is EOF" {
    try expectRun(
        \\module m;
        \\integer n, a, b; reg [15:0] w;
        \\initial begin
        \\  n = $sscanf("12 ff z", "%d %h %s", a, b, w); $write("%0d %0d %0d %s ", n, a, b, w);
        \\  n = $sscanf("7-8", "%d+%d", a, b); $write("%0d %0d ", n, a);
        \\  n = $sscanf(16'h31xx, "%d", a); $display("%0d", n);
        \\end
        \\endmodule
    , "3 12 255 z 1 7 -1\n");
}

test "§17.6 queues: FIFO and LIFO order, capacity and the status codes" {
    try expectRun(
        \\module m;
        \\integer s, j, i, v;
        \\initial begin
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(1, 1, 2, s); $write("%0d", s);
        \\  $q_initialize(2, 2, 2, s); $q_initialize(3, 5, 2, s); $write("%0d", s);
        \\  $q_add(1, 7, 70, s); $q_add(1, 8, 80, s); $q_add(1, 9, 90, s); $write("%0d", s);
        \\  $q_add(2, 7, 70, s); $q_add(2, 8, 80, s);
        \\  v = $q_full(1, s); $write("%0d", v);
        \\  $q_remove(1, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_remove(2, j, i, s); $write(" %0d/%0d", j, i);
        \\  $q_exam(1, 3, v, s); $write(" %0d", v);
        \\  $q_remove(4, j, i, s); $display(" %0d", s);
        \\end
        \\endmodule
    , "06411 7/70 8/80 2 2\n");
}

test "§17.5 a synchronous PLA evaluates only when called, an asynchronous one tracks" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [1:2] mem [1:2]; reg [1:2] in; reg [1:2] s, y;
        \\initial begin
        \\  mem[1] = 2'b11; mem[2] = 2'b10; in = 2'b10;
        \\  $sync$or$array(mem, in, s); $async$nand$plane(mem, in, y);
        \\  #1 in = 2'b01; #1 $display("%b %b", s, y);
        \\end
        \\endmodule
    , "11 11\n");
}

test "§17.9.1 a seedless $random is the listing's stream from seed 0" {
    try expectRun(
        \\module m;
        \\integer a, b;
        \\initial begin a = $random; b = $random; $display("%0d %0d", a, b); end
        \\endmodule
    , "303379748 -1064739199\n");
}
