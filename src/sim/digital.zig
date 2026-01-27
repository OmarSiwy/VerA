//! Shared frontend -> finite initial-process execution. IEEE1364-2005 §§9,11.
//! This deliberately rejects unsupported source forms before executing a task.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = Front.Integer;
const diag = @import("diag");
const Scheduler = @import("scheduler.zig").Scheduler;
const Time = @import("time.zig");

pub const Error = error{DigitalFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;
pub const Options = struct {
    file_name: []const u8 = "<digital>",
    include_dirs: []const []const u8 = &.{},
    /// Only IEEE 1364-2005 §17.2.9's `$readmemb`/`$readmemh` reach the
    /// filesystem while a process is running, so this is optional: a caller
    /// with no `Io` gets a diagnostic from those two tasks and an unchanged
    /// engine everywhere else. The unit tests are that caller.
    io: ?std.Io = null,
};

// Each dispatch consumes all fields of one pending write. NBA snapshots own
// their planes in the run arena, never point into mutable variable storage.
const Pending = union(enum) {
    run_process: u32,
    write: struct { target: u32, value: Int.Literal },
    /// §17.1.2 one $strobe call, evaluated when the `.monitor` region runs and
    /// not when the call executed — the whole point of the task is that it
    /// reports the settled value.
    strobe: struct { args: []const Ast.ExprId, show: Show },
    /// §17.1.3 "something changed this timestep, ask the standing monitor".
    /// One per timestep, coalesced by `monitor_pending`.
    monitor_tick,
};
const Type = struct { width: u32, signed: bool };
// All fields in a row are consumed by one dispatch; expressions stay in the AST.
const Instruction = union(enum(u4)) {
    statement: Ast.StmtId,
    // §6.1 one continuous assignment: evaluate, drive, resolve, then suspend
    // on its own operands. Its resumption point is its own pc.
    continuous: u32,
    branch: struct { condition: Ast.ExprId, otherwise: u32 },
    jump: u32,
    case_select: struct { statement: Ast.StmtId, targets: u32, fallback: u32, ty: Type },
    repeat_start: struct { count: Ast.ExprId, counter: u32, end: u32 },
    repeat_next: struct { counter: u32, body: u32 },
    // §5.10.1 suspend until one watched variable takes a matching edge.
    wait_event: Ast.ExprId,
    // §9.9.2 an `always` body returning to its own start.
    restart: struct { target: u32, tok: u32 },
    stop,
};
// §5.10.1: an edge is a change toward 1 (posedge) or away from 1 (negedge),
// with x and z as the intermediate value on either side of the transition.
const Edge = enum(u2) {
    any,
    posedge,
    negedge,
    fn matches(self: Edge, before: Int.Bit, after: Int.Bit) bool {
        // A plain `@(v)` term watches the whole value, which the caller has
        // already proved changed; the other two read the LSB the table covers.
        if (self == .any) return true;
        if (before == after) return false;
        return switch (self) {
            .posedge => before == .zero or after == .one,
            .negedge => before == .one or after == .zero,
            .any => unreachable,
        };
    }
};
// One suspended process, keyed by the variable it watches. `pc` is both the
// resumption point and the process's identity while it is suspended: the terms
// of one `or` share it, and retire together when any one of them fires.
const Waiter = struct { slot: u32, edge: Edge, pc: u32 };
// §3.9 an unpacked array is `count` consecutive element slots; the declared
// name maps to the first. `low`/`high` are the declared address bounds, in
// either order of declaration — no operation here observes element ORDER, only
// which address names which element.
const Array = struct { count: u32, low: i64, high: i64 };
// §7.9 one net: its resolution function, its storage, and the drivers whose
// wired-logic combination IS its value. `resolved` is the scratch the fold
// writes before publishing through `store`; it is sized once, at setup.
const Net = struct { kind: Ast.NetKind, slot: u32, resolved: Int.Literal, drivers: []const u32 = &.{} };
// §6.1 one driver. It keeps its OWN value — the net's is the resolution of all
// of them — and re-evaluates whenever one of its operands changes.
const Driver = struct { net: u32, value: Ast.ExprId, sensitivity: []const u32, current: Int.Literal };

/// A four-state value of `width` bits, every bit `fill`. This is the one place
/// declared state gets its starting value: X for a variable, Z for an undriven
/// net (§3.7 — that difference IS the net/variable difference).
fn filled(a: std.mem.Allocator, width: u32, signed: bool, fill: Int.Bit) Error!Int.Literal {
    const words = (@as(usize, width) - 1) / 64 + 1;
    const planes = try a.alloc(u64, words * 2);
    @memset(planes[0..words], if (@intFromEnum(fill) & 1 != 0) std.math.maxInt(u64) else 0);
    @memset(planes[words..], if (@intFromEnum(fill) >> 1 != 0) std.math.maxInt(u64) else 0);
    const tail: u6 = @truncate(width);
    if (tail != 0) {
        const keep = (@as(u64, 1) << tail) - 1;
        planes[words - 1] &= keep;
        planes[2 * words - 1] &= keep;
    }
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

/// Write one packed bit. The read side is `Int.Literal.bit`; only the §7.9
/// resolution fold writes bit by bit.
fn setBit(value: Int.Literal, index: u32, b: Int.Bit) void {
    const at = @as(u64, 1) << @truncate(index);
    const word = index / 64;
    if (@intFromEnum(b) & 1 != 0) value.values()[word] |= at else value.values()[word] &= ~at;
    if (@intFromEnum(b) >> 1 != 0) value.unknowns()[word] |= at else value.unknowns()[word] &= ~at;
}

/// IEEE1364-2005 §7.9 wired logic, Tables 7-4/7-6/7-7: fold one more driver's
/// bit into a net's accumulated bit. `z` is the identity of all three tables,
/// which is exactly why an undriven net reads z.
///
/// ponytail: every driver here is at the SAME strength, so §7.10's eight drive
/// strengths and §7.11's strength resolution are not implemented — two drivers
/// that disagree conflict to x whether or not one of them would have won. The
/// declared strength of `supply0`/`supply1`/`tri0`/`tri1` is the only part of
/// that model which survives, and it survives as the special cases in
/// `resolve`, not as a strength. The upgrade path is to carry a (strength0,
/// strength1) pair per driver bit instead of one `Int.Bit`, fold by taking the
/// maximum of each component across a net's drivers, and collapse to four
/// states only on read: strength1 above strength0 is 1, the reverse is 0,
/// equal and nonzero is x, both zero is z. That also needs A.2.2.3's
/// `strong0`/`weak1`/`pull0`/`highz1`/... as lexer tags and A.6.1's
/// `drive_strength` in `parseModuleItem`.
fn wired(kind: Ast.NetKind, acc: Int.Bit, b: Int.Bit) Int.Bit {
    if (acc == .z) return b;
    if (b == .z) return acc;
    return switch (kind) {
        .wand, .triand => if (acc == .zero or b == .zero) .zero else if (acc == .one and b == .one) .one else .x,
        .wor, .trior => if (acc == .one or b == .one) .one else if (acc == .zero and b == .zero) .zero else .x,
        // wire/tri/uwire/tri0/tri1/trireg/supply*: agreement, else conflict.
        else => if (acc == b) acc else .x,
    };
}

/// §3.7 the value a net of this type shows with no driver at all: the pull of
/// `tri0`/`tri1`, the constant of a supply net, the X a `trireg` starts at
/// before it has any charge to hold, and Z for everything else.
fn undriven(kind: Ast.NetKind) Int.Bit {
    return switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        else => .z,
    };
}
const Cast = enum(u1) { make_signed, make_unsigned };
const casts = std.StaticStringMap(Cast).initComptime(.{ .{ "$signed", .make_signed }, .{ "$unsigned", .make_unsigned } });

/// §9.14 Table 9-11's integral system functions, and the two of IEEE 1364
/// §17.7 that read the clock. Separate from `casts` because these take their
/// own arguments and have their own return widths; separate from `tasks`
/// because they are EXPRESSIONS.
const SysFn = enum {
    /// §17.7.1, 64 bits: "the time unit of the module that invoked it".
    time,
    /// §17.7.1's 32-bit half, "the low order 32 bits of the current
    /// simulation time".
    stime,
    /// §9.14 Table 9-11 / IEEE 1364 §17.11: ceiling of log base 2.
    clog2,

    /// Does this read the simulation clock? Such a call is not a constant
    /// expression however constant its arguments are, which a replication
    /// count and a case label both depend on.
    fn reads_clock(self: SysFn) bool {
        return self != .clog2;
    }
};
const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },
    .{ "$stime", .stime },
    .{ "$clog2", .clog2 },
});

/// IEEE 1364-2005 §17.2.9's memory-file lexer: white space and §2.4 comments
/// separate tokens, and a token is either an `@`-address or one data word.
const MemTokens = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *MemTokens) ?[]const u8 {
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.at += 1;
                continue;
            }
            if (c == '/' and self.at + 1 < self.text.len) {
                if (self.text[self.at + 1] == '/') {
                    self.at = std.mem.indexOfScalarPos(u8, self.text, self.at, '\n') orelse self.text.len;
                    continue;
                }
                if (self.text[self.at + 1] == '*') {
                    self.at = if (std.mem.indexOfPos(u8, self.text, self.at + 2, "*/")) |e| e + 2 else self.text.len;
                    continue;
                }
            }
            const start = self.at;
            while (self.at < self.text.len) : (self.at += 1) {
                const d = self.text[self.at];
                if (d == ' ' or d == '\t' or d == '\r' or d == '\n') break;
                // A comment may abut a word: `/* ... */ d4` is one word, and so
                // is `d4// trailing`.
                if (d == '/' and self.at + 1 < self.text.len and
                    (self.text[self.at + 1] == '/' or self.text[self.at + 1] == '*')) break;
            }
            if (self.at > start) return self.text[start..self.at];
        }
        return null;
    }
};

/// One data word, right-justified into the memory's declared width. §17.2.9
/// says the digits may be `x` or `z` for either task, and an unknown DIGIT is
/// unknown in every bit it covers — which is why this shares `Radix.perDigit`
/// with the printer rather than parsing a number and losing the states.
fn memWord(a: std.mem.Allocator, token: []const u8, radix: Radix, width: u32) !Int.Literal {
    const per = radix.perDigit();
    const value = try filled(a, width, false, .zero);
    var bit: u32 = 0;
    var i = token.len;
    while (i != 0 and bit < width) {
        i -= 1;
        const c = std.ascii.toLower(token[i]);
        // §2.6's readability separator is legal in a data word too.
        if (c == '_') continue;
        const fill: ?Int.Bit = switch (c) {
            'x', '?' => .x,
            'z' => .z,
            else => null,
        };
        const digit: u32 = if (fill != null) 0 else switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return error.BadDigit,
        };
        if (digit >= @intFromEnum(radix)) return error.BadDigit;
        var k: u32 = 0;
        while (k < per and bit < width) : ({
            k += 1;
            bit += 1;
        }) setBit(value, bit, fill orelse @enumFromInt(@as(u2, @intCast((digit >> @intCast(k)) & 1))));
    }
    return value;
}

/// §17.7.2 `$realtime` — the only REAL-valued expression the digital engine
/// has, and it exists only in a display argument. There are no real variables
/// to put it in yet (that is M04's work), so it is recognised where it can be
/// printed and nowhere else.
const realtime_name = "$realtime";
/// §9.4.3 Table 9-22's four conversions. The value is the base, so a digit is
/// `@ctz(base)` bits wide for the three power-of-two members and decimal is the
/// one that is not a bit group.
const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    /// Bits consumed per printed digit; meaningless for `.decimal`, which reads
    /// the whole operand at once.
    fn perDigit(self: Radix) u32 {
        return switch (self) {
            .binary => 1,
            .octal => 3,
            .hex => 4,
            .decimal => unreachable,
        };
    }
};

/// §9.4.1 Table 9-1's display family, which is one task with two axes: the
/// radix an argument with NO format specification is printed in, and whether
/// the call ends with a newline. "The $write task provides the same
/// capabilities as $display, but with no newline."
const Show = struct { radix: Radix, newline: bool };

/// The four display families of §9.4.1 Table 9-1 differ in WHEN they run, not
/// in what they print — every one of them formats through `display`.
///
///   show    now, in the active region
///   strobe  at the end of the timestep (IEEE 1364-2005 §17.1.2: "display
///           simulation data at a selected time ... at the end of the current
///           timestep"), which is the `.monitor` scheduler region
///   monitor the same end-of-timestep print, but standing: it re-runs whenever
///           a value changes until another $monitor replaces it (§17.1.3)
const Task = union(enum) {
    show: Show,
    strobe: Show,
    monitor: Show,
    /// $monitoron / $monitoroff. "$monitoron ... produces a display
    /// immediately", so the flag's own transition is observable.
    monitor_enable: bool,
    /// §17.3, the `%t` format state.
    timeformat,
    /// §9.5 Table 9-2 / IEEE 1364 §17.2.9. The radix is the whole difference
    /// between `$readmemb` and `$readmemh`.
    readmem: Radix,
    finish,
};
fn showAs(radix: Radix, newline: bool) Show {
    return .{ .radix = radix, .newline = newline };
}
const tasks = std.StaticStringMap(Task).initComptime(.{
    .{ "$display", Task{ .show = showAs(.decimal, true) } },
    .{ "$displayb", Task{ .show = showAs(.binary, true) } },
    .{ "$displayo", Task{ .show = showAs(.octal, true) } },
    .{ "$displayh", Task{ .show = showAs(.hex, true) } },
    .{ "$write", Task{ .show = showAs(.decimal, false) } },
    .{ "$writeb", Task{ .show = showAs(.binary, false) } },
    .{ "$writeo", Task{ .show = showAs(.octal, false) } },
    .{ "$writeh", Task{ .show = showAs(.hex, false) } },
    .{ "$strobe", Task{ .strobe = showAs(.decimal, true) } },
    .{ "$strobeb", Task{ .strobe = showAs(.binary, true) } },
    .{ "$strobeo", Task{ .strobe = showAs(.octal, true) } },
    .{ "$strobeh", Task{ .strobe = showAs(.hex, true) } },
    .{ "$monitor", Task{ .monitor = showAs(.decimal, true) } },
    .{ "$monitorb", Task{ .monitor = showAs(.binary, true) } },
    .{ "$monitoro", Task{ .monitor = showAs(.octal, true) } },
    .{ "$monitorh", Task{ .monitor = showAs(.hex, true) } },
    .{ "$monitoron", Task{ .monitor_enable = true } },
    .{ "$monitoroff", Task{ .monitor_enable = false } },
    .{ "$timeformat", .timeformat },
    .{ "$readmemb", Task{ .readmem = .binary } },
    .{ "$readmemh", Task{ .readmem = .hex } },
    .{ "$finish", .finish },
});

/// §17.3 `$timeformat(units_number, precision, suffix, min_width)`, with the
/// clause's own defaults: the units are the simulation's precision, nothing
/// after the decimal point, no suffix, and a 20-column field.
const TimeFormat = struct {
    units: i32 = 0,
    precision: u32 = 0,
    suffix: []const u8 = "",
    width: u32 = 20,
};
const Run = struct {
    arena: std.mem.Allocator,
    file: *const Ast.SourceFile,
    starts: []const u32,
    bag: *diag.Bag,
    out: *std.Io.Writer,
    names: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty,
    /// Variables, array elements and nets share one slot space, so one `store`
    /// wakes event waiters for all three. Nets occupy `net_base..values.len`.
    values: []Int.Literal,
    net_base: u32 = 0,
    nets: []Net = &.{},
    drivers: []Driver = &.{},
    /// Keyed by the base slot of an unpacked array (§3.9).
    arrays: std.AutoHashMapUnmanaged(u32, Array) = .empty,
    // Natural types, indexed by AST ExprId; width zero marks an unvisited row.
    types: []Type = &.{},
    replications: std.AutoHashMapUnmanaged(Ast.ExprId, u32) = .empty,
    code: std.ArrayList(Instruction) = .empty,
    case_targets: std.ArrayList(u32) = .empty,
    // One counter per lexical repeat is sufficient without recursive processes.
    repeats: std.ArrayList(u64) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    waiters: std.ArrayList(Waiter) = .empty,
    scheduler: Scheduler,
    /// The source's own path, so §17.2.9's memory file resolves beside the
    /// module that names it.
    file_name: []const u8 = "",
    io: ?std.Io = null,
    scale: ?Time.Scale = null,
    /// The module's TIME UNIT as a power of ten of a second, which `Scale`
    /// deliberately does not keep — it stores ratios, and `%t` needs the
    /// absolute magnitude to reach §17.3's `units_number`.
    unit_exp: i32 = 0,
    time_format: TimeFormat = .{},
    /// §17.1.3 the one standing monitor. A second `$monitor` replaces it;
    /// there is no stack.
    monitor: ?struct { args: []const Ast.ExprId, show: Show } = null,
    monitor_on: bool = true,
    /// One `.monitor` event per timestep however many values moved.
    monitor_pending: bool = false,
    /// What the monitor last printed. §17.1.3 fires "whenever any argument
    /// changes", and comparing the rendered line is how that is decided —
    /// see `monitorTick`.
    monitor_last: ?[]const u8 = null,

    fn fail(self: *Run, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const start = self.starts[@min(tok, self.starts.len - 1)];
        self.bag.add(.lower, .E1100, .{ .start = start, .end = start }, fmt, args) catch return error.OutOfMemory;
        return error.DigitalFailed;
    }
    fn exprFail(self: *Run, e: Ast.ExprId, comptime msg: []const u8) Error {
        return self.fail(self.file.exprs.mainTok(e), "{s}", .{msg});
    }
    fn slot(self: *Run, e: Ast.ExprId) Error!u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .ident) return self.exprFail(e, "only whole-variable lvalues are implemented");
        return self.names.get(ex.strOf(e)) orelse self.exprFail(e, "undeclared digital variable");
    }
    /// One declared bound. Digital execution takes literal bounds only: the
    /// parameters and constant functions §3.9 also admits are not declared yet.
    fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64 {
        if (self.file.exprs.tag(e) != .int_literal) return self.fail(tok, "declaration bounds must be literal integers", .{});
        return self.file.exprs.intValue(e);
    }
    /// §3.3/§6.5.2 a packed `[msb:lsb]` range as a bit width.
    fn declaredWidth(self: *Run, range: Ast.Dim, tok: u32) Error!u32 {
        const hi = try self.declaredBound(range.msb, tok);
        const lo = try self.declaredBound(range.lsb, tok);
        if (hi < 0 or lo < 0 or @abs(hi - lo) >= std.math.maxInt(u32)) return self.fail(tok, "packed range is outside the supported u32 width", .{});
        return @intCast(@abs(hi - lo) + 1);
    }
    fn bind(self: *Run, name: Ast.StrId, at: u32, tok: u32) Error!void {
        const entry = try self.names.getOrPut(self.arena, name);
        if (entry.found_existing) return self.fail(tok, "duplicate digital variable", .{});
        entry.value_ptr.* = at;
    }
    /// A reference to ONE whole value. §3.9's unpacked array has no value of
    /// its own — only its elements do — so a bare array name is refused here.
    fn scalarSlot(self: *Run, e: Ast.ExprId) Error!u32 {
        const at = try self.slot(e);
        if (self.arrays.contains(at)) return self.exprFail(e, "an unpacked array reference requires an element index");
        return at;
    }
    /// The array an `.index` selects from, or null when this is not an element
    /// reference (a bit or part select, which is not implemented).
    fn indexedArray(self: *Run, e: Ast.ExprId) Error!?Array {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .index or ex.tag(ex.lhs(e)) != .ident) return null;
        return self.arrays.get(try self.slot(ex.lhs(e)));
    }
    fn leafType(self: *Run, e: Ast.ExprId) Error!Type {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .ident => blk: {
                const v = self.values[try self.scalarSlot(e)];
                break :blk .{ .width = v.width, .signed = v.signed };
            },
            .int_literal => blk: {
                const n = ex.intLiteral(e);
                if (n.width == 0 and (if (n.signed) n.value < std.math.minInt(i32) or n.value > std.math.maxInt(i32) else n.value < 0 or n.value > std.math.maxInt(u32)))
                    return self.exprFail(e, "unsized constants outside the implemented 32-bit integer width are not supported; use an explicit size");
                break :blk .{ .width = if (n.width == 0) 32 else n.width, .signed = n.signed };
            },
            .logic_literal => blk: {
                const n = ex.logicValue(e);
                if (!n.sized) return self.exprFail(e, "unsized four-state literal context fill is not implemented; use an explicit size");
                break :blk .{ .width = n.width, .signed = n.signed };
            },
            else => self.exprFail(e, "this expression requires digital context typing beyond the implemented leaf operands"),
        };
    }
    fn common(a: Type, b: Type) Type {
        return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
    }
    fn typeOf(self: *Run, e: Ast.ExprId) Type {
        const ty = self.types[@intFromEnum(e)];
        std.debug.assert(ty.width != 0 or self.replications.contains(e)); // zero only for validated replication
        return ty;
    }
    fn checkExpr(self: *Run, e: Ast.ExprId) Error!void {
        _ = try self.inferValue(e, 0);
    }
    fn inferValue(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
        const ty = try self.infer(e, depth);
        if (ty.width == 0) return self.exprFail(e, "zero replication requires an immediately enclosing concatenation with a positive-width operand");
        return ty;
    }
    fn constantExpression(self: *Run, e: Ast.ExprId) bool {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .int_literal, .logic_literal => true,
            .unary => self.constantExpression(ex.lhs(e)),
            .binary, .multi_concat => self.constantExpression(ex.lhs(e)) and self.constantExpression(ex.rhs(e)),
            .ternary => self.constantExpression(ex.lhs(e)) and self.constantExpression(ex.rhs(e)) and self.constantExpression(ex.ternaryElse(e)),
            .sys_call, .concat => blk: {
                // §17.7: a call that reads the clock is never constant, however
                // constant its (absent) arguments are. Without this `$time`
                // would be accepted as a replication count.
                if (ex.tag(e) == .sys_call) {
                    if (sys_fns.get(self.file.str(ex.strOf(e)))) |f| {
                        if (f.reads_clock()) break :blk false;
                    }
                }
                for (ex.args(e)) |arg| if (!self.constantExpression(arg)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }
    // Bare unsized numbers are prohibited by §5.1.14. Its application to
    // arithmetic expressions is disputed; retain an explicit unsupported
    // boundary until qualified, stopping at self-determined expression results.
    fn unsizedConcatOperand(self: *Run, e: Ast.ExprId) bool {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .int_literal => ex.intLiteral(e).width == 0,
            .logic_literal => !ex.logicValue(e).sized,
            .unary => switch (ex.unOp(e)) {
                .plus, .minus, .bit_not => self.unsizedConcatOperand(ex.lhs(e)),
                else => false,
            },
            .binary => switch (ex.binOp(e)) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => self.unsizedConcatOperand(ex.lhs(e)) or self.unsizedConcatOperand(ex.rhs(e)),
                .shl, .shr, .ashl, .ashr, .pow => self.unsizedConcatOperand(ex.lhs(e)),
                else => false,
            },
            .ternary => self.unsizedConcatOperand(ex.rhs(e)) or self.unsizedConcatOperand(ex.ternaryElse(e)),
            else => false,
        };
    }
    fn replicationCount(self: *Run, e: Ast.ExprId) Error!u32 {
        if (!self.constantExpression(e)) return self.exprFail(e, "integral replication requires a constant expression");
        var scratch = std.heap.ArenaAllocator.init(self.arena);
        defer scratch.deinit();
        const value = try self.eval(scratch.allocator(), e, 0);
        if (value.hasUnknown()) return self.exprFail(e, "replication count cannot contain X or Z");
        if (value.signed and value.bit(value.width - 1) == .one) return self.exprFail(e, "replication count cannot be negative");
        for (value.values()[1..]) |word| if (word != 0) return self.exprFail(e, "replication count exceeds the supported u32 range");
        if (value.values()[0] > std.math.maxInt(u32)) return self.exprFail(e, "replication count exceeds the supported u32 range");
        return @intCast(value.values()[0]);
    }
    // IEEE1364-2005 Table 5-22, §5.5.1: infer natural size/type bottom-up.
    // ponytail: recursive evaluation is bounded to 256 AST levels; an explicit
    // stack can remove this ceiling when deeper expressions are needed.
    fn infer(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
        if (e == .none) return self.fail(0, "omitted expressions are not implemented", .{});
        if (depth == 256) return self.exprFail(e, "digital expressions deeper than 256 AST levels are not implemented");
        const entry = &self.types[@intFromEnum(e)];
        if (entry.width != 0 or self.replications.contains(e)) return entry.*;
        const ex = &self.file.exprs;
        const ty: Type = switch (ex.tag(e)) {
            .int_literal, .logic_literal, .ident => try self.leafType(e),
            // §3.9 an array element has the element's declared type; the index
            // is self-determined and never widens the result.
            .index => blk: {
                if (try self.indexedArray(e) == null) return self.exprFail(e, "bit and part selects are not implemented; only unpacked array elements are indexed");
                const index = try self.inferValue(ex.rhs(e), depth + 1);
                if (index.width > 64) return self.exprFail(ex.rhs(e), "array indices wider than 64 bits are not implemented");
                const v = self.values[try self.slot(ex.lhs(e))];
                break :blk .{ .width = v.width, .signed = v.signed };
            },
            .unary => blk: {
                const operand = try self.inferValue(ex.lhs(e), depth + 1);
                break :blk switch (ex.unOp(e)) {
                    .plus, .minus, .bit_not => operand,
                    .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
                };
            },
            .binary => blk: {
                const lhs = try self.inferValue(ex.lhs(e), depth + 1);
                const rhs = try self.inferValue(ex.rhs(e), depth + 1);
                break :blk switch (ex.binOp(e)) {
                    .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(lhs, rhs),
                    .shl, .shr, .ashl, .ashr, .pow => lhs,
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
                };
            },
            .ternary => blk: {
                _ = try self.inferValue(ex.lhs(e), depth + 1);
                const yes = try self.inferValue(ex.rhs(e), depth + 1);
                const no = try self.inferValue(ex.ternaryElse(e), depth + 1);
                break :blk common(yes, no);
            },
            .sys_call => blk: {
                const name = self.file.str(ex.strOf(e));
                if (sys_fns.get(name)) |f| {
                    const args = ex.args(e);
                    switch (f) {
                        // §17.7.1 gives `$time` the 64-bit `time` type and
                        // `$stime` its low 32 bits. Both unsigned: simulation
                        // time has no negative half.
                        .time, .stime => {
                            if (args.len != 0) return self.exprFail(e, "$time and $stime take no arguments");
                            if (self.scale == null) return self.exprFail(e, "the time queries require an explicit valid timescale before the module");
                            break :blk .{ .width = if (f == .time) 64 else 32, .signed = false };
                        },
                        // §17.11's result is an `integer`, which §3.2 makes a
                        // 32-bit SIGNED type — so `$clog2(x) - 1` at x = 0 is
                        // -1 and not 4294967295.
                        .clog2 => {
                            if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$clog2 takes exactly one argument");
                            _ = try self.inferValue(args[0], depth + 1);
                            break :blk .{ .width = 32, .signed = true };
                        },
                    }
                }
                const cast = casts.get(name) orelse return self.exprFail(e, "this digital expression form is not implemented");
                const args = ex.args(e);
                if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                const operand = try self.inferValue(args[0], depth + 1);
                break :blk .{ .width = operand.width, .signed = cast == .make_signed };
            },
            .concat => blk: {
                var width: u32 = 0;
                for (ex.args(e)) |arg| {
                    const operand = try self.infer(arg, depth + 1);
                    if (self.unsizedConcatOperand(arg)) {
                        if (ex.tag(arg) == .int_literal or ex.tag(arg) == .logic_literal)
                            return self.exprFail(arg, "unsized constant numbers are not allowed as concatenation operands");
                        return self.exprFail(arg, "concatenation operands with unsized arithmetic are not implemented");
                    }
                    width = std.math.add(u32, width, operand.width) catch return self.exprFail(e, "concatenation width exceeds the supported u32 range");
                }
                if (width == 0) return self.exprFail(e, "a concatenation requires a positive-width operand; zero-only and empty concatenations are invalid");
                break :blk .{ .width = width, .signed = false };
            },
            .multi_concat => blk: {
                _ = try self.inferValue(ex.lhs(e), depth + 1);
                const operand = try self.inferValue(ex.rhs(e), depth + 1);
                const count = try self.replicationCount(ex.lhs(e));
                const width = std.math.mul(u32, count, operand.width) catch return self.exprFail(e, "replication width exceeds the supported u32 range");
                try self.replications.put(self.arena, e, count);
                break :blk .{ .width = width, .signed = false };
            },
            else => return self.exprFail(e, "this digital expression form is not implemented"),
        };
        entry.* = ty;
        return ty;
    }
    /// §3.9 the element an `.index` names right now, or the whole value a
    /// scalar reference names. `null` is an out-of-bounds or X/Z index: it
    /// names no storage, so a read of one is X and a write to one is discarded.
    fn address(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .index) return try self.slot(e);
        const base = try self.slot(ex.lhs(e));
        const arr = self.arrays.get(base).?; // infer proved this is an array
        const at = (try self.eval(a, ex.rhs(e), 0)).asInt() orelse return null;
        if (at < arr.low or at > arr.high) return null;
        return base + @as(u32, @intCast(at - arr.low));
    }
    fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
        const ex = &self.file.exprs;
        return switch (ex.tag(e)) {
            .ident => self.values[try self.slot(e)],
            .index => blk: {
                const ty = self.typeOf(e);
                const at = (try self.address(a, e)) orelse break :blk try filled(a, ty.width, ty.signed, .x);
                break :blk self.values[at];
            },
            .logic_literal => ex.logicValue(e),
            .int_literal => blk: {
                const n = ex.intLiteral(e);
                const planes = try a.alloc(u64, 2);
                planes[0] = @bitCast(n.value);
                planes[1] = 0;
                const width = if (n.width == 0) 32 else n.width;
                if (width < 64) planes[0] &= (@as(u64, 1) << @intCast(width)) - 1;
                break :blk .{ .width = width, .signed = n.signed, .sized = n.width != 0, .planes = planes };
            },
            else => unreachable, // preflight checkExpr
        };
    }
    fn normalize(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
        var result = value.resize(a, ty.width, if (ty.signed) .sign else .zero) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ZeroSize => unreachable,
        };
        result.signed = ty.signed;
        return result;
    }
    fn scalar(a: std.mem.Allocator, bit: Int.Bit) Error!Int.Literal {
        return filled(a, 1, false, bit);
    }
    // Assignment supplies width only (§5.5.3); its signedness cannot change
    // the RHS type. Operator contexts below propagate BOTH width and type.
    fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal {
        var ty = self.typeOf(e);
        ty.width = @max(ty.width, width);
        return self.evalContext(a, e, ty);
    }
    fn scalarContext(a: std.mem.Allocator, bit: Int.Bit, ty: Type) Error!Int.Literal {
        return normalize(a, try scalar(a, bit), ty);
    }
    // IEEE1364-2005 §5.5.2: propagate context before evaluating operands.
    // Fixed one-bit results stop propagation; their operands get the separate
    // self-determined or common comparison context prescribed by Table 5-22.
    fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .int_literal, .logic_literal, .ident, .index => return normalize(a, try self.leaf(a, e), ty),
            .unary => {
                const op = ex.unOp(e);
                switch (op) {
                    .plus, .minus, .bit_not => {
                        const value = try self.evalContext(a, ex.lhs(e), ty);
                        return switch (op) {
                            .plus => value,
                            .minus => value.negate(a),
                            .bit_not => value.bitwiseNot(a),
                            else => unreachable,
                        };
                    },
                    else => {
                        const value = try self.eval(a, ex.lhs(e), 0);
                        const bit = if (op == .logical_not) value.logicalNot() else value.reduce(switch (op) {
                            .reduce_and => .and_bits,
                            .reduce_nand => .nand_bits,
                            .reduce_or => .or_bits,
                            .reduce_nor => .nor_bits,
                            .reduce_xor => .xor_bits,
                            .reduce_xnor => .xnor_bits,
                            else => unreachable,
                        });
                        return scalarContext(a, bit, ty);
                    },
                }
            },
            .binary => {
                const op = ex.binOp(e);
                switch (op) {
                    .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                        const operand_type = common(self.typeOf(ex.lhs(e)), self.typeOf(ex.rhs(e)));
                        const lhs = try self.evalContext(a, ex.lhs(e), operand_type);
                        const rhs = try self.evalContext(a, ex.rhs(e), operand_type);
                        const bit = switch (op) {
                            .eq, .neq, .case_eq, .case_neq => lhs.equality(switch (op) {
                                .eq => .equal,
                                .neq => .not_equal,
                                .case_eq => .case_equal,
                                else => .case_not_equal,
                            }, rhs),
                            else => lhs.relational(switch (op) {
                                .lt => .less,
                                .le => .less_equal,
                                .gt => .greater,
                                else => .greater_equal,
                            }, rhs),
                        };
                        return scalarContext(a, bit, ty);
                    },
                    .logical_and, .logical_or => {
                        const lhs = try self.eval(a, ex.lhs(e), 0);
                        const truth = lhs.truth();
                        if ((op == .logical_and and truth == .zero) or (op == .logical_or and truth == .one))
                            return scalarContext(a, truth, ty);
                        const rhs = try self.eval(a, ex.rhs(e), 0);
                        return scalarContext(a, lhs.logical(if (op == .logical_and) .and_bits else .or_bits, rhs), ty);
                    },
                    .shl, .shr, .ashl, .ashr, .pow => {
                        const lhs = try self.evalContext(a, ex.lhs(e), ty);
                        const rhs = try self.eval(a, ex.rhs(e), 0);
                        if (op == .pow) return lhs.power(a, rhs);
                        return lhs.shift(a, switch (op) {
                            .shl => .left,
                            .shr => .right,
                            .ashl => .arithmetic_left,
                            else => .arithmetic_right,
                        }, rhs);
                    },
                    else => {},
                }
                const lhs = try self.evalContext(a, ex.lhs(e), ty);
                const rhs = try self.evalContext(a, ex.rhs(e), ty);
                return switch (op) {
                    .add, .sub, .mul, .div, .mod => lhs.arithmetic(a, switch (op) {
                        .add => .add,
                        .sub => .subtract,
                        .mul => .multiply,
                        .div => .divide,
                        else => .remainder,
                    }, rhs),
                    .bit_and, .bit_or, .bit_xor, .bit_xnor => lhs.bitwise(a, switch (op) {
                        .bit_and => .and_bits,
                        .bit_or => .or_bits,
                        .bit_xor => .xor_bits,
                        else => .xnor_bits,
                    }, rhs),
                    else => unreachable,
                };
            },
            .ternary => {
                const condition = try self.eval(a, ex.lhs(e), 0);
                return switch (condition.truth()) {
                    .one => self.evalContext(a, ex.rhs(e), ty),
                    .zero => self.evalContext(a, ex.ternaryElse(e), ty),
                    .x, .z => condition.conditional(a, try self.evalContext(a, ex.rhs(e), ty), try self.evalContext(a, ex.ternaryElse(e), ty)),
                };
            },
            .sys_call => {
                const name = self.file.str(ex.strOf(e));
                if (sys_fns.get(name)) |f| {
                    const natural = self.typeOf(e);
                    const raw: u64 = switch (f) {
                        .time, .stime => blk: {
                            const units = self.scale.?.unitsAt(self.scheduler.now);
                            break :blk if (f == .stime) units & 0xffff_ffff else units;
                        },
                        .clog2 => blk: {
                            const n = try self.eval(a, ex.args(e)[0], 0);
                            // §17.11: "the ceiling of the log base 2", with
                            // $clog2(0) and $clog2(1) both 0. An unknown
                            // operand has no log; 1364 leaves it undefined and
                            // zero is the value every other unknown-input
                            // reduction here answers with.
                            if (n.hasUnknown() or n.width > 64) break :blk 0;
                            const x = n.values()[0];
                            if (x <= 1) break :blk 0;
                            break :blk 64 - @clz(x - 1);
                        },
                    };
                    const planes = try a.alloc(u64, 2);
                    planes[0] = if (natural.width >= 64) raw else raw & ((@as(u64, 1) << @intCast(natural.width)) - 1);
                    planes[1] = 0;
                    const value: Int.Literal = .{ .width = natural.width, .signed = natural.signed, .sized = true, .planes = planes };
                    return normalize(a, value, ty);
                }
                const cast = casts.get(name).?;
                var value = try self.eval(a, ex.args(e)[0], 0);
                value.signed = cast == .make_signed;
                return normalize(a, value, ty);
            },
            .concat => {
                var parts: std.ArrayList(Int.Literal) = .empty;
                for (ex.args(e)) |arg| {
                    if (self.typeOf(arg).width == 0) {
                        // §5.1.14 evaluates the repeated operand once even for
                        // count zero. No zero-width Literal enters value helpers.
                        std.debug.assert(ex.tag(arg) == .multi_concat);
                        _ = try self.eval(a, ex.rhs(arg), 0);
                    } else try parts.append(a, try self.eval(a, arg, 0));
                }
                const value = Int.Literal.concatenate(a, parts.items) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ZeroSize, error.Overflow => unreachable, // preflight checked exact widths
                };
                return normalize(a, value, ty);
            },
            .multi_concat => {
                const value = try self.eval(a, ex.rhs(e), 0);
                const repeated = value.replicate(a, self.replications.get(e).?) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ZeroSize, error.Overflow => unreachable, // zero only consumed by .concat above
                };
                return normalize(a, repeated, ty);
            },
            else => unreachable, // infer rejects unsupported forms before execution
        }
    }
    fn position(self: *Run) u32 {
        return @intCast(self.code.items.len);
    }
    fn append(self: *Run, instruction: Instruction) Error!u32 {
        if (self.code.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital instructions", .{});
        const at = self.position();
        try self.code.append(self.arena, instruction);
        return at;
    }
    fn compileStmt(self: *Run, id: Ast.StmtId, depth: u16) Error!void {
        const tok = self.file.stmtTok(id);
        if (depth == 256) return self.fail(tok, "digital statements deeper than 256 AST levels are not implemented", .{});
        switch (self.file.stmt(id)) {
            .empty => {},
            .block => |b| {
                if (b.name != .none or b.vars.len != 0 or b.params.len != 0) return self.fail(tok, "block declarations/named scopes are not implemented", .{});
                for (b.body) |s| try self.compileStmt(s, depth + 1);
            },
            .if_stmt => |s| {
                if (s.is_generate) return self.fail(tok, "conditional generate is not implemented", .{});
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.then_s, depth + 1);
                if (s.else_s == .none) {
                    self.code.items[test_pc].branch.otherwise = self.position();
                } else {
                    const end_pc = try self.append(.{ .jump = 0 });
                    self.code.items[test_pc].branch.otherwise = self.position();
                    try self.compileStmt(s.else_s, depth + 1);
                    self.code.items[end_pc].jump = self.position();
                }
            },
            .while_stmt => |s| {
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.body, depth + 1);
                _ = try self.append(.{ .jump = test_pc });
                self.code.items[test_pc].branch.otherwise = self.position();
            },
            .for_stmt => |s| {
                try self.compileStmt(s.init, depth + 1);
                try self.checkExpr(s.cond);
                const test_pc = try self.append(.{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
                try self.compileStmt(s.body, depth + 1);
                try self.compileStmt(s.step, depth + 1);
                _ = try self.append(.{ .jump = test_pc });
                self.code.items[test_pc].branch.otherwise = self.position();
            },
            .repeat_stmt => |s| {
                try self.checkExpr(s.count);
                if (self.typeOf(s.count).width > 64) return self.exprFail(s.count, "repeat counts wider than 64 bits are not implemented");
                if (self.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
                const counter: u32 = @intCast(self.repeats.items.len);
                try self.repeats.append(self.arena, 0);
                const test_pc = try self.append(.{ .repeat_start = .{ .count = s.count, .counter = counter, .end = 0 } });
                const body_pc = self.position();
                try self.compileStmt(s.body, depth + 1);
                _ = try self.append(.{ .repeat_next = .{ .counter = counter, .body = body_pc } });
                self.code.items[test_pc].repeat_start.end = self.position();
            },
            .case_stmt => |s| {
                if (s.is_generate) return self.fail(tok, "case generate is not implemented", .{});
                if (s.arms.len == 0) return self.fail(tok, "a case statement requires at least one item", .{});
                try self.checkExpr(s.scrutinee);
                var ty = self.typeOf(s.scrutinee);
                var have_default = false;
                for (s.arms) |arm| {
                    if (arm.labels.len == 0) {
                        if (have_default) return self.fail(tok, "a case statement cannot have multiple default items", .{});
                        have_default = true;
                    }
                    for (arm.labels) |label| {
                        try self.checkExpr(label);
                        ty = common(ty, self.typeOf(label));
                    }
                }
                if (s.arms.len > std.math.maxInt(u32) - self.case_targets.items.len) return self.fail(tok, "too many case targets", .{});
                const targets: u32 = @intCast(self.case_targets.items.len);
                try self.case_targets.appendNTimes(self.arena, 0, s.arms.len);
                const dispatch = try self.append(.{ .case_select = .{ .statement = id, .targets = targets, .fallback = 0, .ty = ty } });
                const exits = try self.arena.alloc(u32, s.arms.len);
                for (s.arms, 0..) |arm, i| {
                    self.case_targets.items[targets + i] = self.position();
                    if (arm.labels.len == 0) self.code.items[dispatch].case_select.fallback = self.position();
                    try self.compileStmt(arm.body, depth + 1);
                    exits[i] = try self.append(.{ .jump = 0 });
                }
                const end = self.position();
                if (!have_default) self.code.items[dispatch].case_select.fallback = end;
                for (exits) |at| self.code.items[at].jump = end;
            },
            .assign => |s| {
                try self.checkTarget(s.target);
                try self.checkExpr(s.value);
                _ = try self.append(.{ .statement = id });
            },
            .event_control => |s| {
                if (!s.is_delay) {
                    try self.checkEvent(s.event);
                    _ = try self.append(.{ .wait_event = s.event });
                    return self.compileStmt(s.body, depth + 1);
                }
                if (self.scale == null) return self.fail(tok, "digital delays require an explicit valid timescale before the module", .{});
                // §9.7.1 a delay is a "delay_value", and A.8.3 makes that
                // `unsigned_number | real_number | ...` — so `#0.5` is as
                // ordinary as `#1`. It is rounded to the module's PRECISION
                // rather than truncated to its unit, which `Scale.realDelay`
                // already does, and which is the only thing that makes a
                // sub-unit delay mean anything.
                if (self.file.exprs.tag(s.event) != .real_literal) {
                    try self.checkExpr(s.event);
                    if (self.typeOf(s.event).width > 64) return self.exprFail(s.event, "delay values wider than 64 bits are not implemented");
                }
                _ = try self.append(.{ .statement = id });
                try self.compileStmt(s.body, depth + 1);
            },
            .sys_task => |s| {
                const name = self.file.str(s.name);
                const task = tasks.get(name) orelse return self.fail(tok, "digital system task `{s}` is not implemented", .{name});
                switch (task) {
                    // All three format the same surface, so all three are
                    // validated by the same dry run.
                    .show, .strobe, .monitor => |sh| try self.display(s.args, null, sh),
                    .monitor_enable => if (s.args.len != 0)
                        return self.fail(tok, "$monitoron and $monitoroff take no arguments", .{}),
                    .timeformat => {
                        // §17.3's four arguments are simulator SETTINGS, read
                        // once when the task runs; a source that computed them
                        // from a net would be asking the format to track a
                        // value, which the clause does not define.
                        const ex = &self.file.exprs;
                        if (s.args.len != 4) return self.fail(tok, "$timeformat takes exactly four arguments", .{});
                        for (s.args[0..2]) |a| if (a == .none or !self.constantExpression(a))
                            return self.exprFail(a, "$timeformat's units and precision must be constant");
                        if (s.args[2] == .none or ex.tag(s.args[2]) != .str_literal)
                            return self.exprFail(s.args[2], "$timeformat's suffix must be a string literal");
                        if (s.args[3] == .none or !self.constantExpression(s.args[3]))
                            return self.exprFail(s.args[3], "$timeformat's minimum width must be constant");
                        for (s.args[0..2]) |a| try self.checkExpr(a);
                        try self.checkExpr(s.args[3]);
                    },
                    .readmem => {
                        const ex = &self.file.exprs;
                        if (s.args.len != 2 and s.args.len != 4)
                            return self.fail(tok, "$readmemb/$readmemh take (file, memory) or (file, memory, start, finish)", .{});
                        if (s.args[0] == .none or ex.tag(s.args[0]) != .str_literal)
                            return self.exprFail(s.args[0], "the memory file name must be a string literal");
                        if (s.args[1] == .none or ex.tag(s.args[1]) != .ident or !self.arrays.contains(try self.slot(s.args[1])))
                            return self.exprFail(s.args[1], "$readmemb/$readmemh load an unpacked array");
                        for (s.args[2..]) |a| {
                            if (a == .none or !self.constantExpression(a))
                                return self.exprFail(a, "the $readmem address bounds must be constant");
                            try self.checkExpr(a);
                        }
                    },
                    .finish => {
                        if (s.args.len > 1) return self.fail(tok, "$finish accepts zero or one argument", .{});
                        if (s.args.len == 1) {
                            const ex = &self.file.exprs;
                            if (ex.tag(s.args[0]) != .int_literal or ex.intValue(s.args[0]) < 0 or ex.intValue(s.args[0]) > 1)
                                return self.fail(tok, "only $finish(0), $finish(1), and $finish are implemented", .{});
                        }
                    },
                }
                _ = try self.append(.{ .statement = id });
            },
            else => return self.fail(tok, "this digital statement is not implemented", .{}),
        }
    }
    // null allocator validates the complete format/expression surface without
    // producing output. Every conversion is width-exact per IEEE 1364-2005
    // §17.1.1.3, including separate X and Z states (§17.1.1.4).
    fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show) Error!void {
        const ex = &self.file.exprs;
        var arg: usize = 0;
        while (arg < args.len) : (arg += 1) {
            const e = args[arg];
            // §9.4.1: "Any null argument produces a single space character in
            // the display. (A null argument is characterized by two adjacent
            // commas (,,) in the argument list.)"
            if (e == .none) {
                if (allocator != null) try self.out.writeByte(' ');
                continue;
            }
            // Only a STRING is a format. §9.4.3's last sentence before Table
            // 9-23: "Any expression argument with no corresponding format
            // specification is displayed using the default decimal format" —
            // default for THIS task, so $displayh's bare argument is hex.
            if (ex.tag(e) != .str_literal) {
                try self.checkExpr(e);
                if (allocator) |a| try self.emitValue(try self.eval(a, e, 0), show.radix, null);
                continue;
            }
            const format = self.file.str(ex.strOf(e));
            var i: usize = 0;
            while (i < format.len) : (i += 1) {
                if (format[i] != '%') {
                    if (allocator != null) try self.out.writeByte(format[i]);
                    continue;
                }
                i += 1;
                if (i == format.len) return self.exprFail(e, "unterminated display format");
                if (format[i] == '%') {
                    if (allocator != null) try self.out.writeByte('%');
                    continue;
                }
                // §17.1.1.2's optional field width. `%0d` is the one every
                // source writes and means "minimum width"; a non-zero width is
                // an explicit column count. Absent means §17.1.1.3's automatic
                // sizing, which is `null` here and computed from the operand.
                var width: ?u32 = null;
                while (i < format.len and format[i] >= '0' and format[i] <= '9') : (i += 1) {
                    const d = format[i] - '0';
                    width = (width orelse 0) *| 10 +| d;
                }
                if (i == format.len) return self.exprFail(e, "unterminated display format");
                const radix: ?Radix = switch (format[i]) {
                    'b', 'B' => .binary,
                    'o', 'O' => .octal,
                    'h', 'H' => .hex,
                    'd', 'D' => .decimal,
                    // §9.4.3 Table 9-22's real conversions. All three print the
                    // same here: Zig's shortest round-tripping form is what %g
                    // asks for, and the suite's reals are exact halves and
                    // integers where %e and %f would agree with it anyway.
                    'e', 'E', 'f', 'F', 'g', 'G' => null,
                    // §17.3 `%t` is not a radix at all — it reads the
                    // $timeformat state and formats a TIME, whose operand is
                    // in the module's own time unit.
                    't', 'T' => {
                        arg += 1;
                        if (arg == args.len) return self.exprFail(e, "missing display argument");
                        try self.checkExpr(args[arg]);
                        if (allocator) |a| try self.emitTime(try self.eval(a, args[arg], 0));
                        continue;
                    },
                    else => return self.exprFail(
                        e,
                        "only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g and %%) are implemented",
                    ),
                };
                arg += 1;
                if (arg == args.len) return self.exprFail(e, "missing display argument");
                if (radix) |r| {
                    try self.checkExpr(args[arg]);
                    if (allocator) |a| try self.emitValue(try self.eval(a, args[arg], 0), r, width);
                } else {
                    const real = try self.evalReal(args[arg]);
                    if (allocator != null) {
                        var buf: [64]u8 = undefined;
                        const text = std.fmt.bufPrint(&buf, "{d}", .{real}) catch unreachable;
                        if (width) |w| if (text.len < w) try self.out.splatByteAll(' ', w - text.len);
                        try self.out.writeAll(text);
                    }
                }
            }
        }
        if (allocator != null and show.newline) try self.out.writeByte('\n');
    }

    /// The real half of the display surface, which is `$realtime` and nothing
    /// else today. It is validated and evaluated by the same call because there
    /// is no state to read: the answer is the clock.
    ///
    /// ponytail: one name, no real variables and no real arithmetic. §17.7.2 is
    /// the only real a source can name until M04 gives the engine `real` and
    /// `wreal`; when it does, this is the seam that grows an evaluator.
    fn evalReal(self: *Run, e: Ast.ExprId) Error!f64 {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .sys_call or !std.mem.eql(u8, self.file.str(ex.strOf(e)), realtime_name))
            return self.exprFail(e, "a real display conversion takes a real expression, and `$realtime` is the only one implemented");
        if (ex.args(e).len != 0) return self.exprFail(e, "$realtime takes no arguments");
        const scale = self.scale orelse return self.exprFail(e, "the time queries require an explicit valid timescale before the module");
        return scale.realAt(self.scheduler.now);
    }

    /// IEEE 1364-2005 §17.2.9 `$readmemb` / `$readmemh`.
    ///
    /// The clause's four rules, and all four are observable:
    ///   - the file holds white space, comments and numbers in the task's radix;
    ///   - with no address arguments the load starts at the memory's LEFT
    ///     declared index and runs toward the right one;
    ///   - `@<hex>` relocates the load point, and loading continues from there;
    ///   - an address the file never reaches is LEFT ALONE. The task loads; it
    ///     does not clear, so an unwritten word keeps the X it started at.
    ///
    /// With a start and a finish the load runs from one toward the other, which
    /// is DOWNWARD when start > finish — the direction is the argument order
    /// and not the declaration's.
    fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void {
        const ex = &self.file.exprs;
        const base = try self.slot(args[1]);
        const arr = self.arrays.get(base).?;
        const name = self.file.str(ex.strOf(args[0]));
        const text = self.readSideFile(a, name) catch
            return self.exprFail(args[0], "the memory file cannot be read");

        // §17.2.9: with no bounds the walk is the DECLARED range, left index
        // first. `Array.low`/`.high` are sorted, so the left index is `low`
        // for `[0:7]` and the runner has no `[7:0]` memory to distinguish yet.
        var at: i64 = arr.low;
        var last: i64 = arr.high;
        if (args.len == 4) {
            at = (try self.eval(a, args[2], 0)).asInt() orelse arr.low;
            last = (try self.eval(a, args[3], 0)).asInt() orelse arr.high;
        }
        const down = last < at;

        var it = MemTokens{ .text = text };
        while (it.next()) |token| {
            if (token[0] == '@') {
                at = std.fmt.parseInt(i64, token[1..], 16) catch
                    return self.exprFail(args[0], "the memory file has a malformed `@` address");
                continue;
            }
            // Outside the declared range the word has nowhere to go. Not an
            // error: a file longer than the memory is the clause's own
            // "more data than the range" case.
            if (at >= arr.low and at <= arr.high) {
                const dest = self.values[base + @as(u32, @intCast(at - arr.low))];
                const value = memWord(a, token, radix, dest.width) catch
                    return self.exprFail(args[0], "the memory file has a malformed data word");
                try self.store(base + @as(u32, @intCast(at - arr.low)), value.planes);
            }
            if (down) {
                if (at <= last) break;
                at -= 1;
            } else {
                if (at >= last) break;
                at += 1;
            }
        }
    }

    /// The data file sits beside the source that names it, which is what makes
    /// a fixture self-contained. The working directory is tried second, so a
    /// path written relative to where the simulator was launched still works.
    fn readSideFile(self: *Run, a: std.mem.Allocator, name: []const u8) ![]const u8 {
        const io = self.io orelse return error.NoIo;
        const limit: usize = 1 << 22;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.file_name)) |dir| {
            const joined = try std.fs.path.join(a, &.{ dir, name });
            if (cwd.readFileAlloc(io, joined, a, .limited(limit))) |text| return text else |_| {}
        }
        return cwd.readFileAlloc(io, name, a, .limited(limit));
    }

    /// §17.3 `%t`. The operand is a time in the INVOKING MODULE'S TIME UNIT —
    /// which is what `$time` returns and what a literal `1` in that position
    /// means — and `$timeformat`'s `units_number` says which power of ten of a
    /// second to report it in. So the printed number is
    ///
    ///     value · 10^(unit_exp − units_number)
    ///
    /// and nothing here needs the precision: scaling a unit count by a ratio of
    /// decades is exact in the only direction that matters.
    fn emitTime(self: *Run, v: Int.Literal) Error!void {
        const f = self.time_format;
        const raw: f64 = if (v.hasUnknown())
            0
        else if (v.signed)
            @floatFromInt(v.asInt() orelse 0)
        else
            @floatFromInt(v.values()[0]);
        const scaled = raw * std.math.pow(f64, 10, @floatFromInt(self.unit_exp - f.units));
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("{d:.[1]}", .{ scaled, f.precision }) catch unreachable;
        w.writeAll(f.suffix) catch unreachable;
        const text = w.buffered();
        if (text.len < f.width) try self.out.splatByteAll(' ', f.width - text.len);
        try self.out.writeAll(text);
    }

    /// One operand, in one radix, sized by IEEE 1364-2005 §17.1.1.3 unless the
    /// format gave an explicit width.
    ///
    /// The three power-of-two radices are a GROUP walk and decimal is not, and
    /// that is the whole split: a hex digit is four bits of this operand and
    /// says nothing about the other bits, so a group that is entirely unknown
    /// prints as unknown while its neighbours print normally. A decimal
    /// rendering has no such locality — one unknown bit makes the whole number
    /// unknown — which is why §17.1.1.4 gives it its own rule.
    fn emitValue(self: *Run, v: Int.Literal, radix: Radix, width: ?u32) Error!void {
        var buf: [1024]u8 = undefined;
        const text = if (radix == .decimal)
            try self.decimalText(&buf, v)
        else
            groupText(&buf, v, radix);
        // §17.1.1.3's automatic size. Right-justified with LEADING SPACES, not
        // zeros: `%d` of an 8-bit 7 is "  7" and not "007". A group radix is
        // already exactly its own width, so padding only ever shows up under
        // decimal or an explicit format width.
        const field = width orelse autoWidth(v, radix);
        if (text.len < field) try self.out.splatByteAll(' ', field - text.len);
        try self.out.writeAll(text);
    }

    /// §17.1.1.3: "a radix conversion is sized to the operand's declared width,
    /// and the default decimal field is sized to the largest value the operand
    /// can hold". For a signed operand the largest PRINTED value is the
    /// negative one, because of its sign: a 32-bit `integer` is 11 columns
    /// ("-2147483648"), not 10.
    fn autoWidth(v: Int.Literal, radix: Radix) u32 {
        if (radix != .decimal) {
            const per = radix.perDigit();
            return (v.width + per - 1) / per;
        }
        // The count of decimal digits in 2^n - 1 (unsigned) or 2^(n-1)
        // (signed magnitude, plus one column for the sign).
        const bits: u32 = if (v.signed and v.width != 0) v.width - 1 else v.width;
        var digits: u32 = 1;
        var limit: u128 = 9;
        // 2^bits - 1 > limit, written so that bits = 128 does not overflow.
        while (bits < 127 and (@as(u128, 1) << @intCast(@min(bits, 126))) - 1 > limit) : (digits += 1) {
            if (limit > std.math.maxInt(u128) / 10) break;
            limit = limit * 10 + 9;
        }
        return digits + @intFromBool(v.signed);
    }

    /// A power-of-two radix, most significant group first. Bits past the
    /// operand's width are absent, not zero: they contribute nothing to the
    /// digit's value AND nothing to its unknown-ness, which is what makes an
    /// all-x 8-bit operand print "xxx" in octal rather than "Xxx" — the top
    /// group holds two x bits and no third bit at all.
    fn groupText(buf: []u8, v: Int.Literal, radix: Radix) []const u8 {
        const per = radix.perDigit();
        const digits = (v.width + per - 1) / per;
        var out: usize = 0;
        var d = digits;
        while (d != 0) {
            d -= 1;
            var value: u32 = 0;
            var xs: u32 = 0;
            var zs: u32 = 0;
            var present: u32 = 0;
            var k: u32 = 0;
            while (k < per) : (k += 1) {
                const index = d * per + k;
                if (index >= v.width) continue;
                present += 1;
                switch (v.bit(index)) {
                    .zero => {},
                    .one => value |= @as(u32, 1) << @intCast(k),
                    .x => xs += 1,
                    .z => zs += 1,
                }
            }
            // §17.1.1.4: all unknown prints lowercase, partly unknown prints
            // uppercase — the case is the whole signal that the digit's known
            // bits were thrown away.
            buf[out] = if (xs == present) 'x' //
            else if (zs == present) 'z' //
            else if (xs != 0) 'X' //
            else if (zs != 0) 'Z' //
            else "0123456789abcdef"[value];
            out += 1;
        }
        return buf[0..out];
    }

    /// Decimal, where one unknown bit poisons the whole number (§17.1.1.4).
    ///
    /// ponytail: 64 bits. A wider `%d` needs a bignum divide, and nothing in
    /// the LRM's own examples or this suite prints one; the refusal is explicit
    /// rather than a silent truncation.
    fn decimalText(self: *Run, buf: []u8, v: Int.Literal) Error![]const u8 {
        if (v.hasUnknown()) {
            var xs: u32 = 0;
            var zs: u32 = 0;
            for (0..v.width) |i| switch (v.bit(@intCast(i))) {
                .x => xs += 1,
                .z => zs += 1,
                else => {},
            };
            buf[0] = if (xs == v.width) 'x' //
            else if (zs == v.width) 'z' //
            else if (xs != 0) 'X' //
            else 'Z';
            return buf[0..1];
        }
        if (v.width > 64) return self.fail(0, "decimal display of an operand wider than 64 bits is not implemented", .{});
        const raw = v.values()[0];
        if (v.signed) return std.fmt.bufPrint(buf, "{d}", .{v.asInt().?}) catch unreachable;
        // Not `asInt`: it bit-casts, so an unsigned 64-bit operand at or above
        // 2^63 would print negative. $time is exactly that operand.
        return std.fmt.bufPrint(buf, "{d}", .{raw}) catch unreachable;
    }

    /// The one write path for both the active and NBA regions, so §5.10.1
    /// resumption cannot be bypassed by whichever region a source used.
    fn store(self: *Run, target: u32, planes: []const u64) Error!void {
        const dest = self.values[target];
        const before = dest.bit(0);
        const changed = !std.mem.eql(u64, dest.planes, planes);
        @memcpy(dest.planes, planes);
        // §17.1.3: a standing monitor reports at the end of a timestep in which
        // something moved. One event however many values moved — the monitor
        // prints its whole argument list, so a second tick could only reprint
        // the same line.
        if (changed and self.monitor != null and self.monitor_on and !self.monitor_pending) {
            self.monitor_pending = true;
            try self.enqueueMonitor(.monitor_tick);
        }
        if (!changed or self.waiters.items.len == 0) return;
        const after = dest.bit(0);
        // ponytail: linear scan. The list holds only currently-suspended
        // processes, so it is bounded by the source's process count; index it
        // by slot if a design ever suspends in bulk.
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const w = self.waiters.items[i];
            if (w.slot != target or !w.edge.matches(before, after)) {
                i += 1;
                continue;
            }
            // Retire every term of this process's event expression. Scanning
            // down keeps the not-yet-examined prefix intact, so each swapped-in
            // entry has already been checked; the scan then restarts because
            // removal moved the tail. Every pass drops at least one entry.
            var j = self.waiters.items.len;
            while (j != 0) {
                j -= 1;
                if (self.waiters.items[j].pc == w.pc) _ = self.waiters.swapRemove(j);
            }
            try self.enqueue(.{ .run_process = w.pc }, null, false);
            i = 0;
        }
    }
    /// §7.9: a net's value is the wired-logic resolution of ALL its drivers, so
    /// it is recomputed whole on every driver update and published through
    /// `store` — the same path a variable write takes, which is what lets
    /// `@(posedge w)` resume on a net.
    fn resolve(self: *Run, net: u32) Error!void {
        const n = self.nets[net];
        const current = self.values[n.slot];
        // ponytail: one bit at a time. The tables are 4x4 over two planes, so a
        // plane-parallel fold is possible; do it when a wide bus resolves often
        // enough to show up, not before.
        for (0..n.resolved.width) |i| {
            const at: u32 = @intCast(i);
            // §7.9: a supply net drives at supply strength, which no continuous
            // assignment can reach, so its own drivers never win.
            var bit = undriven(n.kind);
            if (n.kind != .supply0 and n.kind != .supply1) {
                bit = .z;
                for (n.drivers) |d| bit = wired(n.kind, bit, self.drivers[d].current.bit(at));
                // §7.9/§7.10: where no driver supplied a value, the net type
                // does — and a `trireg` supplies the charge it last held.
                if (bit == .z) bit = if (n.kind == .trireg) current.bit(at) else undriven(n.kind);
            }
            setBit(n.resolved, at, bit);
        }
        try self.store(n.slot, n.resolved.planes);
    }
    /// §6.1 "a continuous assignment is evaluated whenever an operand changes".
    /// The operands are the slots its expression reads; they resolve at compile
    /// time, like an event term, so a resumption cannot fail mid-dispatch.
    ///
    /// ponytail: an array element operand watches EVERY element of that array,
    /// because the element a dynamic index names is not known until it is read.
    /// A per-array wake list would replace that if a big memory ever feeds one.
    fn sensitivity(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .int_literal, .logic_literal => {},
            .ident => try self.watch(try self.slot(e), out),
            .index => {
                const base = try self.slot(ex.lhs(e));
                const arr = self.arrays.get(base).?; // infer proved this is an array
                for (0..arr.count) |i| try self.watch(base + @as(u32, @intCast(i)), out);
                try self.sensitivity(ex.rhs(e), out);
            },
            .unary => try self.sensitivity(ex.lhs(e), out),
            .binary, .multi_concat => {
                try self.sensitivity(ex.lhs(e), out);
                try self.sensitivity(ex.rhs(e), out);
            },
            .ternary => {
                try self.sensitivity(ex.lhs(e), out);
                try self.sensitivity(ex.rhs(e), out);
                try self.sensitivity(ex.ternaryElse(e), out);
            },
            .sys_call, .concat => for (ex.args(e)) |arg| try self.sensitivity(arg, out),
            else => unreachable, // checkExpr admitted only the forms above
        }
    }
    fn watch(self: *Run, at: u32, out: *std.ArrayList(u32)) Error!void {
        for (out.items) |seen| if (seen == at) return;
        try out.append(self.arena, at);
    }
    /// §6.2.2/§6.1: a net is driven by a continuous assignment and a variable by
    /// a procedural one; neither accepts the other's form.
    fn checkTarget(self: *Run, e: Ast.ExprId) Error!void {
        const ex = &self.file.exprs;
        if (try self.indexedArray(e) != null) {
            try self.checkExpr(ex.rhs(e));
            if (self.typeOf(ex.rhs(e)).width > 64) return self.exprFail(ex.rhs(e), "array indices wider than 64 bits are not implemented");
            return;
        }
        if (try self.scalarSlot(e) >= self.net_base)
            return self.exprFail(e, "a net is driven by a continuous assignment; there is no procedural assignment to a net");
    }
    /// Event terms resolve to watched slots at compile time, so a resumption
    /// never has to fail in the middle of a dispatch.
    fn checkEvent(self: *Run, e: Ast.ExprId) Error!void {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .event_or => {
                try self.checkEvent(ex.lhs(e));
                try self.checkEvent(ex.rhs(e));
            },
            .event_posedge, .event_negedge => _ = try self.scalarSlot(ex.lhs(e)),
            .ident => _ = try self.scalarSlot(e),
            else => return self.exprFail(e, "only variable and posedge/negedge event terms are implemented"),
        }
    }
    fn suspendOn(self: *Run, e: Ast.ExprId, resume_pc: u32) Error!void {
        const ex = &self.file.exprs;
        const edge: Edge = switch (ex.tag(e)) {
            .event_or => {
                try self.suspendOn(ex.lhs(e), resume_pc);
                return self.suspendOn(ex.rhs(e), resume_pc);
            },
            .event_posedge => .posedge,
            .event_negedge => .negedge,
            else => .any,
        };
        const watched = if (edge == .any) e else ex.lhs(e);
        try self.waiters.append(self.arena, .{ .slot = try self.slot(watched), .edge = edge, .pc = resume_pc });
    }
    /// The `.monitor` region at the CURRENT time — §17.1.2/§17.1.3's "end of
    /// the timestep", which the scheduler already orders after active,
    /// inactive and NBA.
    fn enqueueMonitor(self: *Run, item: Pending) Error!void {
        if (self.pending.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital events", .{});
        const payload: u32 = @intCast(self.pending.items.len);
        try self.pending.append(self.arena, item);
        _ = self.scheduler.schedule(.monitor, payload) catch |e|
            return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
    }

    /// Render the standing monitor and print it if §17.1.3's "any argument
    /// changed" holds.
    ///
    /// ponytail: the test is on the RENDERED LINE, not on a sensitivity list
    /// over the argument expressions. Two consequences, both benign: a value
    /// that changes and changes back within one timestep correctly prints
    /// nothing, and a change to something the monitor does not name costs one
    /// wasted render. Build the sensitivity list if a design ever monitors a
    /// handful of signals out of thousands.
    fn monitorPrint(self: *Run, a: std.mem.Allocator, force: bool) Error!void {
        const m = self.monitor orelse return;
        if (!self.monitor_on and !force) return;
        var buffer = std.Io.Writer.Allocating.init(a);
        const saved = self.out;
        self.out = &buffer.writer;
        self.display(m.args, a, m.show) catch |e| {
            self.out = saved;
            return e;
        };
        self.out = saved;
        const text = buffer.written();
        if (!force) {
            if (self.monitor_last) |last| if (std.mem.eql(u8, last, text)) return;
        }
        self.monitor_last = try self.arena.dupe(u8, text);
        try self.out.writeAll(text);
    }

    fn enqueue(self: *Run, item: Pending, delay: ?u64, nba: bool) Error!void {
        if (self.pending.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital events", .{});
        const payload: u32 = @intCast(self.pending.items.len);
        try self.pending.append(self.arena, item);
        _ = if (delay) |d|
            self.scheduler.scheduleAfter(d, if (nba) .nba else .inactive, payload) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital timing failure: {t}", .{e})
        else
            self.scheduler.schedule(if (nba) .nba else .active, payload) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else self.fail(0, "digital scheduling failure: {t}", .{e});
    }
    fn caseMatches(kind: Ast.CaseKind, value: Int.Literal, label: Int.Literal) bool {
        std.debug.assert(value.width == label.width);
        if (kind == .normal) return value.equality(.case_equal, label) == .one;
        // IEEE1364-2005 §9.5.1: wildcards apply symmetrically to either value.
        for (0..value.width) |i| {
            const a = value.bit(@intCast(i));
            const b = label.bit(@intCast(i));
            if (a == .z or b == .z or (kind == .casex and (a == .x or b == .x))) continue;
            if (a != b) return false;
        }
        return true;
    }
    fn execute(self: *Run, scratch_arena: *std.heap.ArenaAllocator, start: u32) Error!void {
        var pc = start;
        var restarted = false;
        while (true) {
            // Each instruction completes its copies/captures before scratch is
            // reused; an untimed loop therefore retains no iteration temporaries.
            _ = scratch_arena.reset(.retain_capacity);
            const scratch = scratch_arena.allocator();
            const id = switch (self.code.items[pc]) {
                .stop => return,
                .statement => |id| id,
                .jump => |target| {
                    pc = target;
                    continue;
                },
                .wait_event => |e| return self.suspendOn(e, pc + 1),
                // §6.1: drive this assignment's own value, resolve the net from
                // every driver of it, then suspend on the operands. The
                // resumption point is this same pc, so a change re-drives.
                .continuous => |at| {
                    const d = self.drivers[at];
                    const rhs = try self.eval(scratch, d.value, d.current.width);
                    const value = try normalize(scratch, rhs, .{ .width = d.current.width, .signed = rhs.signed });
                    @memcpy(d.current.planes, value.planes);
                    try self.resolve(d.net);
                    for (d.sensitivity) |s| try self.waiters.append(self.arena, .{ .slot = s, .edge = .any, .pc = pc });
                    return;
                },
                .restart => |s| {
                    // A suspension returns from this dispatch, so reaching the
                    // restart a second time within one proves a whole body ran
                    // with no timing control. That spins the scheduler forever
                    // at one timestamp, so it is reported instead of hanging.
                    if (restarted) return self.fail(s.tok, "this always process completed an iteration without suspending; it needs a delay or event control", .{});
                    restarted = true;
                    pc = s.target;
                    continue;
                },
                .branch => |s| {
                    const value = try self.eval(scratch, s.condition, 0);
                    pc = if (value.truth() == .one) pc + 1 else s.otherwise;
                    continue;
                },
                .repeat_start => |s| {
                    const value = try self.eval(scratch, s.count, 0);
                    const count = if (value.hasUnknown()) 0 else blk: {
                        if (value.signed and value.asInt().? < 0)
                            return self.exprFail(s.count, "negative repeat counts are not implemented; IEEE1364-2005 does not define this case explicitly");
                        break :blk value.values()[0];
                    };
                    self.repeats.items[s.counter] = count;
                    pc = if (count == 0) s.end else pc + 1;
                    continue;
                },
                .repeat_next => |s| {
                    self.repeats.items[s.counter] -= 1;
                    pc = if (self.repeats.items[s.counter] != 0) s.body else pc + 1;
                    continue;
                },
                .case_select => |s| {
                    const case = self.file.stmt(s.statement).case_stmt;
                    const value = try self.evalContext(scratch, case.scrutinee, s.ty);
                    pc = s.fallback;
                    search: for (case.arms, 0..) |arm, i| {
                        for (arm.labels) |label| {
                            const item = try self.evalContext(scratch, label, s.ty);
                            if (caseMatches(case.kind, value, item)) {
                                pc = self.case_targets.items[s.targets + i];
                                break :search;
                            }
                        }
                    }
                    continue;
                },
            };
            switch (self.file.stmt(id)) {
                .assign => |s| {
                    // §3.9: an out-of-range or X/Z index names no element, so
                    // the write is discarded rather than landing somewhere.
                    if (try self.address(scratch, s.target)) |target| {
                        const dest = self.values[target];
                        const rhs = try self.eval(scratch, s.value, dest.width);
                        const value = try normalize(if (s.nonblocking) self.arena else scratch, rhs, .{ .width = dest.width, .signed = rhs.signed });
                        if (s.nonblocking) try self.enqueue(.{ .write = .{ .target = target, .value = value } }, null, true) else try self.store(target, value.planes);
                    }
                },
                .event_control => |s| {
                    // §9.7.1 `#0.5`: rounded to the module's precision, not
                    // truncated to its unit. `compileStmt` let this through
                    // without a type, so it never reaches `eval`.
                    if (self.file.exprs.tag(s.event) == .real_literal) {
                        const delay = self.scale.?.realDelay(self.file.exprs.realValue(s.event)) catch |e|
                            return self.fail(self.file.stmtTok(id), "digital delay cannot be represented: {t}", .{e});
                        try self.enqueue(.{ .run_process = pc + 1 }, delay, false);
                        return;
                    }
                    const value = try self.eval(scratch, s.event, 0);
                    const delay: u64 = if (value.hasUnknown()) 0 else blk: {
                        if (value.width > 64) return self.exprFail(s.event, "delay values wider than 64 bits are not implemented");
                        break :blk (if (value.signed) self.scale.?.signedDelay(value.asInt().?) else self.scale.?.unsignedDelay(value.values()[0])) catch |e|
                            return self.fail(self.file.stmtTok(id), "digital delay cannot be represented: {t}", .{e});
                    };
                    try self.enqueue(.{ .run_process = pc + 1 }, delay, false);
                    return;
                },
                .sys_task => |s| switch (tasks.get(self.file.str(s.name)).?) {
                    .show => |sh| try self.display(s.args, scratch, sh),
                    // §17.1.2: the arguments are NOT captured, the call is.
                    // What it reports is the value at the end of the timestep,
                    // so evaluation waits for the `.monitor` region.
                    .strobe => |sh| try self.enqueueMonitor(.{ .strobe = .{ .args = s.args, .show = sh } }),
                    .monitor => |sh| {
                        self.monitor = .{ .args = s.args, .show = sh };
                        self.monitor_last = null;
                        try self.monitorPrint(scratch, true);
                    },
                    .monitor_enable => |on| {
                        const was = self.monitor_on;
                        self.monitor_on = on;
                        // "$monitoron ... produces a display immediately", so
                        // the re-enable itself is an event. Turning it off is
                        // silent, and turning on what was already on is not a
                        // transition.
                        if (on and !was) try self.monitorPrint(scratch, true);
                    },
                    .timeformat => {
                        const ex = &self.file.exprs;
                        const units = try self.eval(scratch, s.args[0], 0);
                        const precision = try self.eval(scratch, s.args[1], 0);
                        const width = try self.eval(scratch, s.args[3], 0);
                        self.time_format = .{
                            .units = std.math.lossyCast(i32, units.asInt() orelse 0),
                            .precision = std.math.lossyCast(u32, precision.asInt() orelse 0),
                            .suffix = self.file.str(ex.strOf(s.args[2])),
                            .width = std.math.lossyCast(u32, width.asInt() orelse 0),
                        };
                    },
                    .readmem => |radix| try self.readMemory(scratch, s.args, radix),
                    .finish => {
                        const verbose = s.args.len == 0 or self.file.exprs.intValue(s.args[0]) != 0;
                        if (verbose) {
                            const start_byte = self.starts[self.file.stmtTok(id)];
                            const loc = self.bag.locate(.{ .start = start_byte, .end = start_byte }, null);
                            try self.out.print("$finish at tick {d}, {s} byte {d}\n", .{ self.scheduler.now, self.bag.fileName(loc.file), loc.offset });
                        }
                        self.scheduler.finish();
                        return;
                    },
                },
                else => unreachable,
            }
            pc += 1;
        }
    }
};

/// Callers own the run arena and diagnostic source lifetime. No analog lowering,
/// generated-device interpretation, external compiler, or secondary lexer is used.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var times: []const Front.Preprocessor.TimescaleEvent = &.{};
    const text = Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .timescale_events = &times, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    const file = parser.parseSourceFile() catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseError => error.DigitalFailed,
    };
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = &file, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = Scheduler.init(arena), .file_name = opts.file_name, .io = opts.io };
    if (file.modules.len != 1 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires exactly one ordinary module", .{});
    const m = file.modules[0];
    if (m.is_connect or m.ports.len != 0 or m.params.len != 0 or m.aliasparams.len != 0 or m.branches.len != 0 or m.instances.len != 0 or m.defparams.len != 0 or m.genvars.len != 0 or m.events.len != 0 or m.functions.len != 0 or m.analog.len != 0 or m.attrs.len != 0)
        return r.fail(m.main_tok, "digital execution currently requires a portless module with only variables and initial processes", .{});
    for (times) |event| {
        if (event.at > r.starts[m.main_tok]) return r.fail(m.main_tok, "timescale/resetall after module start is not implemented for digital execution", .{});
        // A null scale is now only ever IEEE 1364 §19.6's `resetall, which
        // returns `timescale to "none specified". A MALFORMED directive no
        // longer reaches here at all: the preprocessor refuses it where it is
        // written (E0142), which is a better place to hear about it than a
        // consumer three stages away.
        const t = event.scale orelse return r.fail(m.main_tok, "a resetall timing state is not supported by digital execution", .{});
        const unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(m.main_tok, "unsupported time unit", .{});
        const precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(m.main_tok, "unsupported time precision", .{});
        r.scale = Time.Scale.init(unit, precision, precision) catch return r.fail(m.main_tok, "invalid timescale", .{});
        r.unit_exp = @intFromEnum(unit);
        // §17.3: "the default ... is the smallest time precision argument of
        // all the `timescale compiler directives in the source description".
        // One module here, so that is this one's precision.
        r.time_format.units = @intFromEnum(precision);
    }
    // Variables, then array elements, then nets — one slot space, so one
    // `store` publishes all three and wakes the same event waiters.
    var values: std.ArrayList(Int.Literal) = .empty;
    for (m.vars) |v| {
        if (v.ty != .integer or v.init != .none or v.storage == .time) return r.fail(v.main_tok, "only uninitialized scalar/packed reg and integer declarations are implemented", .{});
        // ponytail: one unpacked dimension. §3.9 admits any number; the second
        // one needs a row-major address fold this has no consumer for yet.
        if (v.dims.len > 1) return r.fail(v.main_tok, "only one unpacked array dimension is implemented", .{});
        const width: u32 = if (v.packed_range) |range| try r.declaredWidth(range, v.main_tok) else if (v.storage == .reg) 1 else 32;
        const base: u32 = @intCast(values.items.len);
        try r.bind(v.name, base, v.main_tok);
        var count: u32 = 1;
        if (v.dims.len == 1) {
            const lo = try r.declaredBound(v.dims[0].lsb, v.main_tok);
            const hi = try r.declaredBound(v.dims[0].msb, v.main_tok);
            const low = @min(lo, hi);
            const high = @max(lo, hi);
            if (high - low >= std.math.maxInt(u32)) return r.fail(v.main_tok, "unpacked array size is outside the supported u32 range", .{});
            count = @intCast(high - low + 1);
            try r.arrays.put(arena, base, .{ .count = count, .low = low, .high = high });
        }
        if (count > std.math.maxInt(u32) - values.items.len) return r.fail(v.main_tok, "too many digital storage slots", .{});
        for (0..count) |_| try values.append(arena, try filled(arena, width, if (v.storage == .reg) v.is_signed else true, .x));
    }
    r.net_base = @intCast(values.items.len);
    if (m.nets.len > std.math.maxInt(u32) - values.items.len) return r.fail(m.main_tok, "too many digital storage slots", .{});
    r.nets = try arena.alloc(Net, m.nets.len);
    for (m.nets, 0..) |n, i| {
        if (n.discipline != .none or n.is_ground or n.init != .none)
            return r.fail(n.main_tok, "disciplined, ground and wreal-initialized nets are not implemented by digital execution", .{});
        const width = if (n.range) |range| try r.declaredWidth(range, n.main_tok) else 1;
        const at: u32 = @intCast(values.items.len);
        try r.bind(n.name, at, n.main_tok);
        // §3.7: a net with no driver is Z, not X — except where the net type
        // itself supplies a value. That is the whole net/variable difference.
        try values.append(arena, try filled(arena, width, false, undriven(n.kind)));
        r.nets[i] = .{ .kind = n.kind, .slot = at, .resolved = try filled(arena, width, false, .z) };
    }
    r.values = values.items;
    r.types = try arena.alloc(Type, file.exprs.nodes.len);
    @memset(r.types, .{ .width = 0, .signed = false });
    // §6.1 one continuous assignment is one driver of one net; §7.9 resolution
    // needs them grouped, because every update reads all of a net's drivers.
    //
    // They compile FIRST so that no driver's pc can also be a process's
    // resumption point: a `wait_event` resumes at its own pc plus one, and
    // every instruction from here on belongs to a process.
    if (m.assigns.len > std.math.maxInt(u32)) return r.fail(m.main_tok, "too many continuous assignments", .{});
    r.drivers = try arena.alloc(Driver, m.assigns.len);
    const grouped = try arena.alloc(std.ArrayList(u32), m.nets.len);
    @memset(grouped, .empty);
    for (m.assigns, 0..) |a, i| {
        const target = try r.scalarSlot(a.target);
        if (target < r.net_base) return r.fail(a.main_tok, "a continuous assignment can only drive a net", .{});
        try r.checkExpr(a.value);
        var watched: std.ArrayList(u32) = .empty;
        try r.sensitivity(a.value, &watched);
        r.drivers[i] = .{
            .net = target - r.net_base,
            .value = a.value,
            .sensitivity = watched.items,
            .current = try filled(arena, r.values[target].width, false, .z),
        };
        try grouped[target - r.net_base].append(arena, @intCast(i));
        try r.enqueue(.{ .run_process = try r.append(.{ .continuous = @intCast(i) }) }, null, false);
    }
    for (r.nets, grouped, m.nets) |*n, g, decl| {
        // §7.9 `uwire` is the UNRESOLVED net type: a second driver is not a
        // resolution question there, it is an error.
        if (n.kind == .uwire and g.items.len > 1) return r.fail(decl.main_tok, "a uwire net accepts a single driver", .{});
        n.drivers = g.items;
    }
    for (m.discrete) |process| {
        const start: u32 = @intCast(r.code.items.len);
        try r.compileStmt(process.body, 0);
        _ = try r.append(if (process.is_always)
            .{ .restart = .{ .target = start, .tok = process.main_tok } }
        else
            .stop);
        try r.enqueue(.{ .run_process = start }, null, false);
    }
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    while (r.scheduler.next()) |event| {
        _ = scratch.reset(.retain_capacity);
        switch (r.pending.items[event.payload]) {
            .run_process => |start| try r.execute(&scratch, start),
            .write => |w| try r.store(w.target, w.value.planes),
            .strobe => |s| try r.display(s.args, scratch.allocator(), s.show),
            .monitor_tick => {
                r.monitor_pending = false;
                try r.monitorPrint(scratch.allocator(), false);
            },
        }
    }
}

fn expectRun(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    run(arena.allocator(), source, .{}, &bag, &output.writer) catch |e| {
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        std.debug.print("{s}", .{messages.written()});
        return e;
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

test "source processes suspend at zero delay and NBA captures RHS in lexical order" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module example;
        \\reg [3:0] a, b;
        \\initial begin
        \\  $display("initial %b",a);
        \\  a = 4'b0001;
        \\  b <= a;
        \\  b <= 4'b0011;
        \\  a = 4'b0010;
        \\  #0 $display("inactive %b %b",a,b);
        \\  #1 $display("after %b %b",a,b);
        \\  $finish(0);
        \\end
        \\initial begin #0 $display("peer %b",a); end
        \\endmodule
    , "initial xxxx\ninactive 0010 xxxx\npeer 0010\nafter 0010 0011\n");
}

test "digital assignment context extends before operations and preserves X Z" {
    try expectRun(
        \\module example;
        \\reg [7:0] a;
        \\integer i;
        \\initial begin
        \\  a = ~4'b0000; $display("wide %b",a);
        \\  a = 4'sb1000; $display("signed %b",a);
        \\  a = 4'b1000; $display("unsigned %b",a);
        \\  a = 4'b10xz; $display("logic %b",a);
        \\  i = 32'shffffffff; $display("integer %b",i);
        \\end
        \\endmodule
    , "wide 11111111\nsigned 11111000\nunsigned 00001000\nlogic 000010xz\ninteger 11111111111111111111111111111111\n");
}

test "an always process resumes on each posedge of a clock it does not drive" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(posedge clk) begin n = n + 1; $display("tick %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "tick 0001\ntick 0010\ntick 0011\n");
}

test "a negedge term ignores the opposite transition" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg clk;
        \\reg [3:0] n;
        \\initial begin clk = 0; n = 0; end
        \\always #5 clk = ~clk;
        \\always @(negedge clk) begin n = n + 1; $display("fall %b", n); end
        \\initial #28 $finish(0);
        \\endmodule
    , "fall 0001\nfall 0010\n");
}

test "every term of one event expression retires when any of them fires" {
    // Both waiters belong to one process: a second resumption per change would
    // double every line below.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg b;
        \\reg [1:0] hits;
        \\initial begin a = 0; b = 0; hits = 0; end
        \\always @(a or b) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 1; #5 b = 1; #5 a = 0; #5 $finish(0); end
        \\endmodule
    , "hit 01\nhit 10\nhit 11\n");
}

test "a write that does not change the value resumes nothing" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(a) begin hits = hits + 1; $display("hit %b", hits); end
        \\initial begin #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "hit 01\n");
}

test "a nonblocking write resumes a waiting process from the NBA region" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\reg [1:0] hits;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge a) begin hits = hits + 1; $display("nba %b", hits); end
        \\initial begin #5 a <= 1; #5 $finish(0); end
        \\endmodule
    , "nba 01\n");
}

test "an undriven net reads Z where a variable reads X" {
    try expectRun(
        \\module example;
        \\reg [3:0] r;
        \\wire [3:0] w;
        \\wire s;
        \\initial $display("%b %b %b", r, w, s);
        \\endmodule
    , "xxxx zzzz z\n");
}

test "a continuous assignment drives its net and re-evaluates on every operand" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire [1:0] w;
        \\assign w = {a, a & b};
        \\initial begin
        \\  a = 0; b = 0;
        \\  #1 $display("00 %b", w);
        \\  a = 1;
        \\  #1 $display("10 %b", w);
        \\  b = 1;
        \\  #1 $display("11 %b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00 00\n10 10\n11 11\n");
}

test "a net resolution resumes event waiters through the same write path" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\wire w;
        \\reg [1:0] hits;
        \\assign w = a;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge w) begin hits = hits + 1; $display("net posedge %b", hits); end
        \\initial begin #5 a = 1; #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "net posedge 01\nnet posedge 10\n");
}

test "IEEE1364-2005 section 7.9 wired logic resolves all drivers of one net" {
    // Each net has the same two drivers; only the resolution function differs.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\wor wo;
        \\assign w = a, wa = a, wo = a;
        \\assign w = b, wa = b, wo = b;
        \\initial begin
        \\  a = 0; b = 0; #1 $display("0 0 %b %b %b", w, wa, wo);
        \\  a = 1;        #1 $display("1 0 %b %b %b", w, wa, wo);
        \\  b = 1;        #1 $display("1 1 %b %b %b", w, wa, wo);
        \\  a = 1'bz;     #1 $display("z 1 %b %b %b", w, wa, wo);
        \\  b = 1'bx;     #1 $display("z x %b %b %b", w, wa, wo);
        \\  b = 1'bz;     #1 $display("z z %b %b %b", w, wa, wo);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\0 0 0 0 0
        \\1 0 x 0 1
        \\1 1 1 1 1
        \\z 1 1 1 1
        \\z x x x x
        \\z z z z z
        \\
    );
}

test "the pull supply and capacitive net types supply what no driver did" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\tri0 t0;
        \\tri1 t1;
        \\supply0 s0;
        \\supply1 s1;
        \\trireg c;
        \\assign t0 = d, t1 = d, s0 = d, s1 = d, c = d;
        \\initial begin
        \\  $display("start %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 0;    #1 $display("zero  %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 1'bz; #1 $display("float %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\start x x 0 1 x
        \\zero  0 0 0 1 0
        \\float 0 1 0 1 0
        \\
    );
}

test "unpacked array elements are addressed, and an out-of-range index reads X" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [7:0] mem [5:2];
        \\integer i;
        \\initial begin
        \\  for (i = 2; i < 6; i = i + 1) mem[i] = i * 3;
        \\  mem[1] = 8'hff;
        \\  mem[4] <= 8'h0f;
        \\  $display("%b %b %b", mem[2], mem[5], mem[1]);
        \\  #1 $display("%b %b", mem[4], mem[1'bx]);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00000110 00001111 xxxxxxxx\n00001111 xxxxxxxx\n");
}

test "an array element operand wakes a continuous assignment" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [3:0] mem [0:1];
        \\integer i;
        \\wire [3:0] w;
        \\assign w = mem[i];
        \\initial begin
        \\  i = 0; mem[0] = 4'h1; mem[1] = 4'h2;
        \\  #1 $display("%b", w);
        \\  i = 1;
        \\  #1 $display("%b", w);
        \\  mem[1] = 4'h7;
        \\  #1 $display("%b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "0001\n0010\n0111\n");
}

fn expectRejected(source: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, run(arena.allocator(), source, .{}, &bag, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, messages.written(), message) != null);
}

test "unsupported source is rejected before any process side effect" {
    try expectRejected("module m; initial $display(\"before\"); initial forever ; endmodule", "error");
    try expectRejected("module m; tran(a,b); initial $display(\"before\"); endmodule", "switch primitives");
    try expectRejected("module m; initial $display(\"%b\",2147483648); endmodule", "unsized constants");
    try expectRejected("module m; initial $display(\"%b\",'hx); endmodule", "unsized four-state");
    try expectRejected("module m; reg c; always begin c = 1; end endmodule", "without suspending");
    try expectRejected("module m; reg c; initial @(c[0]) c = 1; endmodule", "event terms are implemented");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=(a+1)+$bogus(1); end endmodule", "expression form");
    try expectRejected("module m; reg [3:0] a; initial a[0]=1; endmodule", "whole-variable");
    try expectRejected("module m; initial $finish(2); endmodule", "only $finish");
    // The conversions that ARE implemented are §9.4.3 Table 9-22's; `%s` and
    // `%c` are not, and the refusal names the table rather than one letter.
    try expectRejected("module m; initial $display(\"%s\",1); endmodule", "Table 9-22");
    // §17.7: a real conversion needs a real, and `$realtime` is the only one.
    try expectRejected("`timescale 1ns/1ns\nmodule m; reg a; initial $display(\"%g\",a); endmodule", "only one implemented");
    try expectRejected("module m; reg a; initial a=1; integer a; endmodule", "duplicate digital");
}

test "the net and array declaration boundaries are explicit" {
    // §6.1/§6.2.2: neither form of assignment accepts the other's target.
    try expectRejected("module m; wire w; initial w = 1; endmodule", "no procedural assignment to a net");
    try expectRejected("module m; reg r; initial $display(\"before\"); assign r = 1; endmodule", "can only drive a net");
    try expectRejected("module m; wire w; reg a; assign w[0] = a; endmodule", "whole-variable");
    // §7.9 uwire resolves nothing, so a second driver is an error.
    try expectRejected("module m; uwire u; reg a,b; assign u = a; assign u = b; endmodule", "uwire net accepts a single driver");
    // §3.9 an array has no value of its own, and a select is not an element.
    try expectRejected("module m; reg [3:0] mem [0:3]; initial $display(\"%b\",mem); endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] mem [0:1]; reg a; initial @(mem) a = 1; endmodule", "requires an element index");
    try expectRejected("module m; reg [3:0] a; initial $display(\"%b\",a[0]); endmodule", "bit and part selects");
    try expectRejected("module m; reg [3:0] mem [0:1][0:1]; initial $display(\"x\"); endmodule", "one unpacked array dimension");
    try expectRejected("module m; reg [3:0] mem [0:1]; initial mem[65'h1] = 0; endmodule", "indices wider than 64 bits");
    // §3.6 a disciplined net belongs to the analog solver, not to this executor.
    try expectRejected("module m; electrical e; initial $display(\"x\"); endmodule", "disciplined, ground");
    try expectRejected("module m; wire [p:0] w; initial $display(\"x\"); endmodule", "bounds must be literal integers");
}

test "timescale provenance rejects absent malformed or later directives" {
    try expectRejected("module m; initial #1 ; endmodule", "explicit valid timescale");
    // All three are refused by the preprocessor now (E0142), so what the digital
    // executor sees is a failed preprocess and the message names the directive
    // rather than the consumer that could not use it.
    try expectRejected("`timescale 2ns/1ps\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ns/1ps junk\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ps/1ns\nmodule m; initial #1 ; endmodule", "coarser than the time unit");
    try expectRejected("`timescale 1ns/1ps\nmodule m; initial #1 ; endmodule\n`timescale 1ms/1us\n", "after module start");
    try expectRejected("`timescale 1ns/1ps\n`resetall\nmodule m; initial #1 ; endmodule", "resetall");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
    // §17.7: a clock query has no unit to report in without a timescale.
    try expectRejected("module m; initial $display(\"%0d\", $time); endmodule", "explicit valid timescale");
}

test "§9.7.1 a real delay rounds to the precision instead of truncating to the unit" {
    // `#0.5` under 10ns/100ps is 50 precision units — half a time unit, not
    // zero. A runner that truncated would print `0 0`, and one that ignored
    // the fraction would print `0 0` too; only rounding gives 1.
    try expectRun(
        \\`timescale 10ns/100ps
        \\module m; initial begin #0.5 $display("%0d %g", $time, $realtime); end endmodule
        \\
    , "1 0.5\n");
}

test "§9.4.3 the radix conversions size themselves from the operand" {
    // IEEE 1364-2005 §17.1.1.3: a radix field is the operand's declared width
    // in that radix, and the default decimal field holds the largest value the
    // operand can take — 255 for `reg [7:0]`, so three columns of leading
    // SPACE and not zero. `%0d` is the escape from it.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'd7;
        \\  $display("[%d][%0d][%h][%o][%b]", v, v, v, v, v);
        \\end endmodule
        \\
    , "[  7][7][07][007][00000111]\n");
    // §17.1.1.4: a group that is ENTIRELY unknown prints lowercase, a group
    // that is partly unknown prints uppercase. The `X` is the whole signal
    // that known bits were discarded.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'b1010_xxxx; $display("[%b][%h][%o]", v, v, v);
        \\  v = 8'bzzzz_0011; $display("[%h][%o]", v, v);
        \\end endmodule
        \\
    , "[1010xxxx][ax][2Xx]\n[z3][zZ3]\n");
    // §9.4.1: a null argument is one space, $write has no newline, and an
    // argument with no format specification takes the TASK's default radix.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'hA5;
        \\  $write("w"); $displayh(v); $display("[", , "]"); $display("bare=", v);
        \\end endmodule
        \\
    , "wa5\n[ ]\nbare=165\n");
}

test "unknown delay is zero and finish discards pending later processes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\initial begin
        \\  a = 0; a <= 1;
        \\  #(1'bx) $display("unknown-delay %b",a);
        \\  #1 $display("later %b",a);
        \\  $finish(0);
        \\end
        \\initial begin #2 $display("not run"); end
        \\endmodule
    , "unknown-delay 0\nlater 1\n");
}

test "display retains escaped NUL bytes and unsized integer width" {
    try expectRun("module m; initial $display(\"A\\000B %b\",1); endmodule", "A\x00B 00000000000000000000000000000001\n");
    try expectRun("module m; initial $display(\"%b\",65'd1); endmodule", "00000000000000000000000000000000000000000000000000000000000000001\n");
}

test "finish verbosity reports exact local precision ticks and mapped source" {
    const source = "`timescale 1ns/1ps\nmodule m; initial #1 $finish; endmodule";
    const offset = std.mem.indexOf(u8, source, "$finish").?;
    var expected: [128]u8 = undefined;
    try expectRun(source, try std.fmt.bufPrint(&expected, "$finish at tick 1000, <digital> byte {d}\n", .{offset}));
}

test "nested unsupported forms fail preflight even in unselected conditional arms" {
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b1 ? 1'b0 : $bogus(1); end endmodule", "expression form");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b0 && $bogus(1); end endmodule", "expression form");
}

test "deep left-associated source expression fails before output" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("module m; reg a; initial begin $display(\"before\"); a=0");
    for (0..256) |_| try source.writer.writeAll("+0");
    try source.writer.writeAll("; end endmodule");
    try expectRejected(source.written(), "deeper than 256 AST levels");
}

test "nested expressions preserve NBA snapshot and evaluate delay at suspension" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a,b;
        \\integer n;
        \\initial begin
        \\  a=4'h3; n=0;
        \\  b <= (a+4'h1)*4'h2;
        \\  a=4'hf;
        \\  #(n+1) $display("nested-nba %b",b);
        \\  $finish(0);
        \\end
        \\endmodule
    , "nested-nba 1000\n");
}

test "control flow validates unselected bodies and every case label" {
    try expectRejected("module m; initial begin $display(\"before\"); if(0) $bogustask(\"BAD\"); end endmodule", "system task");
    try expectRejected("module m; initial begin $display(\"before\"); case(1) 1:; $bogus(2):; endcase end endmodule", "expression form");
    try expectRejected("module m; initial begin $display(\"before\"); while(0) @(a); end endmodule", "undeclared digital variable");
    try expectRejected("module m; initial case(1) default:; default:; endcase endmodule", "multiple default");
    try expectRejected("module m; initial case(1) endcase endmodule", "at least one item");
    try expectRejected("module m; initial repeat(65'd1); endmodule", "wider than 64");
    try expectRejected("module m; initial repeat(-1); endmodule", "negative repeat counts");
}

test "repeat accepts all 64 count bits and finish stops without an iteration clamp" {
    try expectRun("module m; initial repeat(64'hffffffffffffffff) begin $display(\"first\"); $finish(0); end endmodule", "first\n");
    try expectRun("module m; integer i; initial begin i=0; while(i<70001) i=i+1; $display(\"%b\",i); end endmodule", "00000000000000010001000101110001\n");
}

test "statement depth is explicit and diagnosed before execution" {
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("module m; initial $display(\"before\"); initial ");
    for (0..256) |_| try source.writer.writeAll("if(1) ");
    try source.writer.writeAll("; endmodule");
    try expectRejected(source.written(), "statements deeper than 256");
}

test "concatenation validates zero replication structure and constant counts" {
    try expectRejected("module m; initial $display(\"%b\",{0{1'b1}}); endmodule", "immediately enclosing concatenation");
    try expectRejected("module m; initial $display(\"%b\",{{{0{1'b1}}},1'b1}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{{0{$bogus(1)}},1'b1}); endmodule", "expression form");
    try expectRejected("module m; integer n; initial begin $display(\"before\"); $display(\"%b\",{n{1'b1}}); end endmodule", "constant expression");
    try expectRejected("module m; initial $display(\"%b\",{-1{1'b1}}); endmodule", "cannot be negative");
    try expectRejected("module m; initial $display(\"%b\",{1'bx{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{1'bz{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{65'h10000000000000000{1'b1}}); endmodule", "count exceeds");
    try expectRejected("module m; initial $display(\"%b\",{32'h80000000{2'b1}}); endmodule", "width exceeds");
}

test "concat unsized boundary and cast arity are explicit" {
    try expectRejected("module m; initial $display(\"%b\",{1'b1,3}); endmodule", "unsized constant numbers");
    try expectRejected("module m; initial $display(\"%b\",{1+2,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",{8'd1+1,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",$signed()); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$unsigned(1,2)); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$signed(1.0)); endmodule", "expression form");
}

fn testConcatRunAllocation(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try run(arena.allocator(), "module m; reg [7:0] a; initial begin a={{0{$signed(65'bz)}},{(1+1){4'b10xz}}}; $display(\"%b\",a); end endmodule", .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings("10xz10xz\n", output.written());
}

test "source concat allocation failures clean up preflight and execution arenas" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatRunAllocation, .{});
}
