//! IEEE 1364-2005 §17 system tasks that keep state of their own: a task's
//! argument expressions and the `Run` in; values written to its output
//! arguments (and, for queues, `Run.queues`) out.
//! Clauses: §17.2 file input and output, §17.2.3 string output, §17.5
//! programmable logic arrays, §17.6 stochastic queues, §17.9 distributions.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
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
/// with what §17.6.5's statistics are computed from.
pub const Queue = struct {
    lifo: bool,
    max: u64,
    jobs: std.ArrayList(Job) = .empty,
    /// §17.6.5 code 3, "the maximum queue length" reached.
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
    return (try evaluate.eval(self, a, e, 0)).asInt();
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
    if (r.out[0]) |v| try evaluate.assignInt(self, a, args[1], v);
    if (r.out[1]) |v| try evaluate.assignInt(self, a, args[2], v);
    try evaluate.assignInt(self, a, args[3], r.status);
}

/// The §17.6 queues, by `q_id`.
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
        // §17.6.5 Table 17-15's statistics codes.
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

/// §17.6.4 `$q_full(q_id, status)`: 1 when the queue holds its maximum.
pub fn queueFull(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const r = queueIsFull(&self.queues, try int(self, a, args[0]));
    try evaluate.assignInt(self, a, args[1], r.status);
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
    try evaluate.assignInt(self, a, args[0], d.seed);
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
pub const own: contract.FileIo = .{ .open = fk.zFOpen, .close = fk.zFClose, .put = fk.zFPut, .getc = fk.zFGetc, .ungetc = fk.zFUngetc, .tell = fk.zFTell, .seek = fk.zFSeek, .eof = fk.zFEof, .err = fk.zFError };

/// VAMS §9.5.1.2: one descriptor table per simulation, the host's
/// (`Run.file_io`: a mixed simulation's device table), else this engine's
/// own, which only an engine given filesystem access (`Options.io`) opens
/// files through.
fn table(self: *Run) ?contract.FileIo {
    return self.file_io orelse if (self.io != null) own else null;
}

/// The §17.2 functions an expression can call.
pub const FileFn = enum { fopen, fgetc, ungetc, fgets, fscanf, fread, ftell, fseek, rewind, feof, ferror, sscanf };

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
/// variable holding it is signed (`integer fd` is the clause's own example).
fn descriptor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    return low32(try int(self, a, e));
}

fn low32(d: ?i64) ?i64 {
    return (d orelse return null) & 0xffff_ffff;
}

/// One §17.2 function call; every one of them returns an integer.
pub fn fileCall(self: *Run, a: std.mem.Allocator, f: FileFn, args: []const Ast.ExprId, _: u32) Error!i64 {
    if (f == .sscanf) return scanCall(self, a, args);
    const t = table(self) orelse return switch (f) {
        .fopen, .fgets, .fread, .ferror => 0,
        else => -1, // else: EOF, the error answer of the rest
    };
    switch (f) {
        .fopen => {
            const name = try text(a, try evaluate.eval(self, a, args[0], 0));
            const mode = if (args.len == 1) null else try text(a, try evaluate.eval(self, a, args[1], 0));
            return fopen(t, a, self.file_name, name, mode, args.len == 1);
        },
        .fgets => return fgets(self, a, t, args),
        .fscanf => return fscanf(self, a, t, args),
        .fread => return fread(self, a, t, args),
        // §17.2.7: the code, and its description in `str`, cleared when 0.
        .ferror => {
            const code = if (t.err) |err| err((try descriptor(self, a, args[0])) orelse 0) else 0;
            try evaluate.assign(self, a, args[1], try stringValue(a, fk.zFErrorStr(code, 0)));
            return code;
        },
        else => {}, // else: `fileOp`'s
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
    if (!fileType(ty)) return 0;
    // A file read is looked for beside the source first, as `$readmemh`
    // looks (`display.readSideFile`).
    if (ty[0] == 'r') if (std.fs.path.dirname(file_name)) |dir| {
        const d = t.open(try std.fs.path.join(a, &.{ dir, path }), ty, mcd);
        if (d != 0) return d;
    };
    return t.open(path, ty, mcd);
}

/// Is `ty` one of §17.2.1 Table 17-7's file types?
pub fn fileType(ty: []const u8) bool {
    const types = [_][]const u8{ "r", "rb", "w", "wb", "a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b", "ab+" };
    for (types) |allowed| if (std.mem.eql(u8, allowed, ty)) return true;
    return false;
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
        .fopen, .sscanf, .fgets, .fscanf, .fread, .ferror => unreachable, // `fileCall`'s own
    }
}

/// §17.2.4.2 `$fgets(str, fd)`: characters into `str` "until str is filled,
/// or a newline character is read and transferred to str, or an EOF
/// condition is encountered"; a partial top byte of `str` holds none. The
/// count, 0 when nothing was read (and `str` is left alone).
fn fgets(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const room = (try evaluate.targetType(self, args[0])).width / 8;
    const line = try readLine(a, t, d, room);
    if (line.len != 0) try evaluate.assign(self, a, args[0], try stringValue(a, line));
    return @intCast(line.len);
}

/// §17.2.4.2's byte read, shared by the interpreter and emitted executable.
/// Include the newline, respect the destination's complete-byte capacity,
/// and return no bytes on EOF/error so the caller leaves its target alone.
pub fn readLine(a: std.mem.Allocator, t: contract.FileIo, d: i64, room: u32) std.mem.Allocator.Error![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    while (line.items.len < room) {
        const c = t.getc(d);
        if (c < 0) break;
        try line.append(a, @intCast(c));
        if (c == '\n') break;
    }
    return line.items;
}

/// §17.2.4.3 `$fscanf(fd, format, args...)`: `$sscanf` over the file from its
/// position, which then stands after the characters the scan used: "the
/// offending input character is left unread in the input stream".
fn fscanf(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[0])) orelse return -1;
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    var file = try fileScan(a, t, d, format, args.len - 2);
    try scanAssign(self, a, &file.scan, args[2..]);
    return finishFileScan(t, file, file.scan);
}

/// §17.2.4.3's input snapshot and original descriptor position. The native
/// executable and interpreter use the same scanner and restore only the
/// consumed prefix, so a failed conversion leaves the offending byte unread.
pub const FileScan = struct { scan: Scan, descriptor: ?i64 = null, start: i64 = 0, input_len: usize = 0 };

/// Starts a `$fscanf` on descriptor `descriptor_`: the rest of the file is
/// read into `a` and the descriptor left at its end until `finishFileScan`
/// puts it back. A null, x or unreadable descriptor scans no input (EOF).
pub fn fileScan(a: std.mem.Allocator, t: contract.FileIo, descriptor_: ?i64, format: ?[]const u8, outs: usize) std.mem.Allocator.Error!FileScan {
    const no_input: FileScan = .{ .scan = .init(null, format, outs) };
    const d = low32(descriptor_) orelse return no_input;
    const start = t.tell(d);
    if (start < 0) return no_input;
    // ponytail: reads the rest of the file per call; a streaming scan when a
    // model reads large files this way.
    var rest: std.ArrayList(u8) = .empty;
    while (true) {
        const c = t.getc(d);
        if (c < 0) break;
        try rest.append(a, @intCast(c));
    }
    return .{ .scan = .init(rest.items, format, outs), .descriptor = d, .start = start, .input_len = rest.items.len };
}

/// Ends a `fileScan`: the descriptor is repositioned just past what `scan`
/// consumed, and `$fscanf`'s value (`Scan.result`) returned. Must follow
/// every `fileScan` whose descriptor was readable.
pub fn finishFileScan(t: contract.FileIo, file: FileScan, scan: Scan) i64 {
    const d = file.descriptor orelse return scan.result;
    _ = t.seek(d, file.start + @as(i64, @intCast(scan.at)), 0);
    // A scan that ran to the end of the input met EOF (§17.2.8), which the
    // repositioning cleared.
    if (scan.at == file.input_len) _ = t.getc(d);
    return scan.result;
}

/// §17.2.4.4 `$fread(myreg, fd)` / `$fread(mem, fd, start, count)`: whole
/// words of ceil(width/8) bytes each, the first byte the most significant;
/// a memory from `start` (default its lowest address) for at most `count`
/// words (default to its end). The count of characters read, 0 on none.
fn fread(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const ex = &self.file.exprs;
    const base = if (ex.tag(args[0]) == .ident) try self.slot(args[0]) else 0;
    const arr = (if (ex.tag(args[0]) == .ident) self.arrays.get(base) else null) orelse {
        const width = (try evaluate.targetType(self, args[0])).width;
        const w = try readWord(a, t, d, width);
        if (w.value) |v| try evaluate.assign(self, a, args[0], v);
        return w.n;
    };
    var at = if (args.len > 2 and args[2] != .none) (try int(self, a, args[2])) orelse return 0 else arr.low;
    var left = if (args.len > 3) (try int(self, a, args[3])) orelse return 0 else std.math.maxInt(i64);
    var read: i64 = 0;
    while (at >= arr.low and at <= arr.high and left > 0) {
        const w = try readWord(a, t, d, self.values[base].width);
        read += w.n;
        try waiters.store(self, base + @as(u32, @intCast(at - arr.low)), (w.value orelse break).planes);
        if (at == arr.high) break;
        at += 1;
        left -= 1;
    }
    return read;
}

/// One `$fread` word: ceil(width/8) characters, big-endian, into `width`
/// bits; the value is null when the file ends first. `n` is the characters
/// read.
pub fn readWord(a: std.mem.Allocator, t: contract.FileIo, d: i64, width: u32) Error!struct { value: ?Int.Literal, n: i64 } {
    const bytes = (width + 7) / 8;
    const v = try filled(a, width, false, .zero);
    for (0..bytes) |k| {
        const c = t.getc(d);
        if (c < 0) return .{ .value = null, .n = @intCast(k) };
        const lo: u32 = @intCast((bytes - 1 - k) * 8);
        for (0..8) |b| if (lo + b < width and (c >> @intCast(b)) & 1 != 0) setBit(v, lo + @as(u32, @intCast(b)), .one);
    }
    return .{ .value = v, .n = bytes };
}

/// §17.2.7 `$fclose` of a file descriptor, or of every file a multichannel
/// descriptor's bits name.
pub fn fclose(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    if (table(self)) |t| _ = t.close(d);
}

/// §17.2.2 `$fdisplay`/`$fwrite` and their radix forms: the `$display` text
/// of the arguments after the descriptor, to every channel it names.
pub fn fdisplay(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: @import("display.zig").Show) Error!void {
    // ponytail: `$fstrobe` and `$fmonitor` are not implemented.
    const d = (try descriptor(self, a, args[0])) orelse return;
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    try @import("display.zig").display(self, args[1..], a, show);
    self.out = saved;
    if (try channels(table(self), self.io, self.out, d, buf.written())) {
        const start = self.starts[@min(self.file.exprs.mainTok(args[0]), self.starts.len - 1)];
        try self.bag.add(.lower, .W1154, .{ .start = start, .end = start }, unwritten, .{});
    }
}

/// The W1154 text.
pub const unwritten = "no file this descriptor names is open for writing: the output is not written";

/// `bytes` to every channel descriptor `d` names: bit 0 of an mcd and fd 1
/// (STDOUT) are the transcript `out`; fd 2 is STDERR; every other channel
/// is the table's. True when the table's channels took none of `bytes`:
/// each is closed (§17.2.1: `$fclose` "does not allow any further output to
/// the closed channels") or not open for writing.
pub fn channels(t: ?contract.FileIo, io: ?std.Io, out: *std.Io.Writer, d: i64, bytes: []const u8) std.Io.Writer.Error!bool {
    const fd = d & (@as(i64, 1) << 31) != 0;
    const ch = d & 0x7fff_ffff;
    if ((fd and ch == 1) or (!fd and d & 1 != 0)) try out.writeAll(bytes);
    if (fd and ch == 2) if (io) |i| std.Io.File.stderr().writeStreamingAll(i, bytes) catch {};
    const files = if (fd) (if (ch > 2) d else 0) else d & ~@as(i64, 1);
    if (files == 0 or bytes.len == 0) return false;
    const tt = t orelse return false;
    return tt.put(files, bytes) == 0;
}

/// §17.2.4.3 `$sscanf(str, format, args...)` in the interpreter (`Scan`).
fn scanCall(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const input = try text(a, try evaluate.eval(self, a, args[0], 0));
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    return (try scanInto(self, a, input, format, args[2..])).code;
}

/// `Scan` of `input` by `format`, each value assigned to its output in
/// `outs`: the call's code and the input characters the scan used.
fn scanInto(self: *Run, a: std.mem.Allocator, input: ?[]const u8, format: ?[]const u8, outs: []const Ast.ExprId) Error!struct { code: i64, used: usize } {
    var sc: Scan = .init(input, format, outs.len);
    try scanAssign(self, a, &sc, outs);
    return .{ .code = sc.result, .used = sc.at };
}

fn scanAssign(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void {
    while (sc.next()) |x| switch (x.value) {
        .bits => |b| {
            const v = try filled(a, 64, true, .zero);
            v.values()[0] = b[0];
            v.unknowns()[0] = b[1];
            try evaluate.assign(self, a, outs[x.arg], v);
        },
        .chars => |c| try evaluate.assign(self, a, outs[x.arg], try stringValue(a, c)),
        .real => |r| try evaluate.assignReal(self, a, outs[x.arg], r),
    };
}

/// §17.2.4.3 `$sscanf(str, format, args...)`: C's scanf over the characters
/// of `str`. Each `next` is one assignment to an output argument, in order;
/// once it returns null, `result` is how many were assigned, or EOF (-1)
/// when the input ends before the first conversion, and (the clause's own
/// rule) when either `str` or `format` has an x or z bit (null here).
/// A conversion is `%`, an optional `*` (match, do not assign or count), an
/// optional maximum field width, and one of %b %o %d %h %x %c %s %f %e %g.
pub const Scan = struct {
    // ponytail: %t %v %m %u %z stop the scan; add them when a source reads them.
    input: []const u8,
    format: []const u8,
    /// Output arguments the call has.
    outs: usize,
    at: usize = 0,
    i: usize = 0,
    result: i64 = 0,
    done: bool = false,

    /// Output argument `arg` (0 = the first after the format) takes a 64-bit
    /// 4-state value (`bits`: value and unknown planes, signed), characters
    /// (`%s`, `%c`) or a real (`%f %e %g`).
    pub const Assign = struct { arg: usize, value: union(enum) { bits: [2]u64, chars: []const u8, real: f64 } };

    /// The scan of `input` by `format`; a null one ends it at once with EOF.
    pub fn init(input: ?[]const u8, format: ?[]const u8, outs: usize) Scan {
        if (input == null or format == null) return .{ .input = "", .format = "", .outs = outs, .result = -1, .done = true };
        return .{ .input = input.?, .format = format.?, .outs = outs };
    }

    fn stop(self: *Scan, eof: bool) ?Assign {
        if (eof and self.result == 0) self.result = -1;
        self.done = true;
        return null;
    }

    /// The next assignment, or null once the scan is over and `result` is
    /// final. Null for good after the first null.
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
            if (format[self.i] == '%') {
                if (self.at >= input.len or input[self.at] != '%') return self.stop(false);
                self.at += 1;
                continue;
            }
            const suppress = format[self.i] == '*';
            if (suppress) self.i += 1;
            var width: usize = 0;
            while (self.i < format.len and std.ascii.isDigit(format[self.i])) : (self.i += 1) width = width *| 10 +| (format[self.i] - '0');
            if (self.i == format.len) return self.stop(false);
            const conv = std.ascii.toLower(format[self.i]);
            if (conv != 'c') while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) : (self.at += 1) {};
            if (self.at >= input.len) return self.stop(true);
            // "it extends to the next inappropriate character or until the
            // maximum field width, if one is specified, is exhausted".
            const field = input[self.at..if (width == 0) input.len else @min(input.len, self.at + width)];
            const n, const value: @FieldType(Assign, "value") = switch (conv) {
                'c' => .{ 1, .{ .bits = .{ field[0], 0 } } },
                's' => blk: {
                    const len = std.mem.indexOfAny(u8, field, &std.ascii.whitespace) orelse field.len;
                    break :blk .{ len, .{ .chars = field[0..len] } };
                },
                'd', 'h', 'x', 'o', 'b' => number(field, conv) orelse return self.stop(false),
                'f', 'e', 'g' => float(field) orelse return self.stop(false),
                else => return self.stop(false),
            };
            self.at += n;
            if (suppress) continue;
            const arg: usize = @intCast(self.result);
            if (arg >= self.outs) return self.stop(false);
            self.i += 1;
            self.result += 1;
            return .{ .arg = arg, .value = value };
        }
        return self.stop(false);
    }

    /// The characters of `field` one integral conversion matches, and their
    /// value, or null on a matching failure. `%d` is an optional sign and
    /// decimal digits, or a single x, z or ?; the others take their radix's
    /// digits and x, z, ?, which give §3.5.1's bits (an x or z leftmost pads
    /// the value with itself). `_` separates digits in every radix.
    fn number(field: []const u8, conv: u8) ?struct { usize, @FieldType(Assign, "value") } {
        if (conv == 'd') {
            const neg = field[0] == '-';
            const sign: usize = @intFromBool(neg or field[0] == '+');
            if (sign == 0) switch (std.ascii.toLower(field[0])) {
                'x' => return .{ 1, .{ .bits = .{ ~@as(u64, 0), ~@as(u64, 0) } } },
                'z', '?' => return .{ 1, .{ .bits = .{ 0, ~@as(u64, 0) } } },
                else => {},
            };
            var n = sign;
            var acc: u64 = 0;
            while (n < field.len and (std.ascii.isDigit(field[n]) or field[n] == '_')) : (n += 1) {
                if (field[n] != '_') acc = acc *% 10 +% (field[n] - '0');
            }
            if (std.mem.indexOfNone(u8, field[sign..n], "_") == null) return null;
            return .{ n, .{ .bits = .{ if (neg) 0 -% acc else acc, 0 } } };
        }
        const per: u6 = switch (conv) {
            'b' => 1,
            'o' => 3,
            else => 4, // else: 'h' and 'x'
        };
        var n: usize = 0;
        var v: u64 = 0;
        var u: u64 = 0;
        var top: ?[2]u64 = null;
        const ones = (@as(u64, 1) << per) - 1;
        while (n < field.len) : (n += 1) {
            const ch = std.ascii.toLower(field[n]);
            if (ch == '_') continue;
            const digit: [2]u64 = switch (ch) {
                'x' => .{ ones, ones },
                'z', '?' => .{ 0, ones },
                else => .{ (std.fmt.charToDigit(ch, @as(u8, 1) << @intCast(per)) catch break), 0 },
            };
            top = top orelse digit;
            v = v << per | digit[0];
            u = u << per | digit[1];
        }
        const first = top orelse return null;
        // §3.5.1: an unknown leftmost digit pads to the left with itself.
        if (first[1] != 0) {
            var bits: u32 = 0;
            for (field[0..n]) |ch| bits += if (ch == '_') 0 else per;
            if (bits < 64) {
                const pad = ~@as(u64, 0) << @intCast(bits);
                u |= pad;
                if (first[0] != 0) v |= pad;
            }
        }
        return .{ n, .{ .bits = .{ v, u } } };
    }

    /// "Matches a floating point number": C's sign, digits, fraction and
    /// exponent.
    fn float(field: []const u8) ?struct { usize, @FieldType(Assign, "value") } {
        var n: usize = @intFromBool(field[0] == '+' or field[0] == '-');
        var digits: usize = 0;
        while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        if (n < field.len and field[n] == '.') {
            n += 1;
            while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        }
        if (digits == 0) return null;
        if (n < field.len and (field[n] == 'e' or field[n] == 'E')) {
            var k = n + 1;
            if (k < field.len and (field[k] == '+' or field[k] == '-')) k += 1;
            if (k < field.len and std.ascii.isDigit(field[k])) {
                while (k < field.len and std.ascii.isDigit(field[k])) k += 1;
                n = k;
            }
        }
        return .{ n, .{ .real = std.fmt.parseFloat(f64, field[0..n]) catch return null } };
    }
};

/// IEEE 1364-2005 §4.2.3 a string as a value: 8 bits a character, the last
/// character in the low byte. Assigning it pads or truncates on the left.
fn stringValue(a: std.mem.Allocator, s: []const u8) Error!Int.Literal {
    const v = try filled(a, @intCast(@max(1, s.len) * 8), false, .zero);
    for (s, 0..) |ch, k| setBitsOfByte(v, @intCast((s.len - 1 - k) * 8), ch);
    return v;
}

/// §17.2.3 `$swrite` (`show` set: `$fwrite`'s text) / `$sformat` (null:
/// `display.sformat`'s) of the arguments after the first, assigned to the
/// first "using the string assignment to variable rules".
pub fn sformat(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: ?@import("display.zig").Show) Error!void {
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    if (show) |sh| try @import("display.zig").display(self, args[1..], a, sh) else try @import("display.zig").sformat(self, args[1..], a);
    self.out = saved;
    try evaluate.assign(self, a, args[0], try stringValue(a, buf.written()));
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

/// The sixteen §17.5 PLA task names, each with its `Pla`.
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

/// §17.5 one evaluation in the interpreter (`plaEval`).
pub fn pla(self: *Run, a: std.mem.Allocator, p: Pla, args: []const Ast.ExprId) Error!void {
    const base = try self.slot(args[0]);
    const arr = self.arrays.get(base).?; // compile proved it is an array
    const in = try evaluate.eval(self, a, args[1], 0);
    const out = try filled(a, (try evaluate.targetType(self, args[2])).width, false, .x);
    plaEval(p, self.values[base..][0..arr.count], in, out);
    try evaluate.assign(self, a, args[2], out);
}

/// §17.5 one evaluation into `out`, which starts all x: row k of the
/// personality `rows` (lowest address first) computes output bit k; within
/// a row, bit j of the personality governs input j, both counted from the
/// left. An unknown input selected by a row makes it unknown unless the
/// row's controlling value decides it.
pub fn plaEval(p: Pla, rows: []const Int.Literal, in: Int.Literal, out: Int.Literal) void {
    // ponytail: rows are taken lowest address first, which is the declaration
    // order of the ascending memories §17.5's examples use.
    const and_like = p.logic == .@"and" or p.logic == .nand;
    for (0..@min(rows.len, out.width)) |k| {
        const row = rows[k];
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
        setBit(out, @intCast(out.width - 1 - k), if (!inverted) value else switch (value) {
            .zero => .one,
            .one => .zero,
            else => .x,
        });
    }
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
