//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §5.5.1 Table 5-22, §5.1.14, A.6.5, §9.7.1, §9.7.5,
//! §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §17.7; VAMS §9.14 Table 9-11 `$clog2`.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const SpecExpr = @import("root.zig").SpecExpr;
const expectRun = @import("root.zig").expectRun;
const expectRejected = @import("root.zig").expectRejected;
const filled = @import("net.zig").filled;
const tasks = display.tasks;

// ---- the bytecode and its tables (A.6.5, §9.14 Table 9-11, §17.7) -----------

/// An expression's type (§5.5.1): a width and a signedness, or IEEE 1364-2005
/// §4.8's `real`, a double held in a slot as its 64 bits.
pub const Type = struct { width: u32, signed: bool, real: bool = false };
pub const real_type: Type = .{ .width = 64, .signed = true, .real = true };

/// One bytecode row, consumed whole by one dispatch; expressions stay in the
/// AST. Each statement kind is decided here, so `exec.execute` is one switch
/// and never goes back to the statement.
pub const Instruction = union(enum(u5)) {
    /// A.6.2 a blocking or nonblocking assignment with no intra-assignment
    /// timing control (those are `sample`/`deposit`).
    assign: struct { target: Ast.ExprId, value: Ast.ExprId, nonblocking: bool },
    /// §9.7.1 `#d stmt`: suspend for the delay, resume at the next pc.
    delay: struct { amount: Ast.ExprId, tok: u32 },
    /// One §17 system task, resolved against `display.tasks` at compile time.
    task: struct { task: display.Task, args: []const Ast.ExprId, tok: u32 },
    /// §6.1 continuous assignment `n`: evaluate, drive, resolve, then suspend
    /// on its own operands, resuming at its own pc.
    continuous: u32,
    branch: struct { condition: Ast.ExprId, otherwise: u32 },
    jump: u32,
    case_select: struct { statement: Ast.StmtId, targets: u32, fallback: u32, ty: Type },
    /// `clamp`: §9.7.7's repeat event control, where a count <= 0 is no
    /// occurrence; the §9.6 statement refuses a negative one.
    repeat_start: struct { count: Ast.ExprId, counter: u32, end: u32, clamp: bool = false },
    repeat_next: struct { counter: u32, body: u32 },
    /// §5.10.1 suspend until one watched variable takes a matching edge.
    wait_event: Ast.ExprId,
    /// A.6.5 `@*`: §9.7.5's implicit list, resolved to slots at compile time.
    /// A resumption is the same `.any` waiter `@(a or b)` installs.
    wait_slots: []const u32,
    /// A.6.5 `wait_statement`, level sensitive: `cond` is tested on arrival
    /// and on every resumption, and only a true reading falls through.
    /// `slots` (its operands) says when to re-test.
    wait_level: struct { cond: Ast.ExprId, slots: []const u32 },
    /// §8.5.3.3 the first half of an intra-assignment timing control: the
    /// right-hand side, evaluated when the statement is reached, is parked in
    /// `cell`, then the timing applies. A nonblocking one schedules its write
    /// here, does not suspend, and has no `deposit`.
    sample: struct { statement: Ast.StmtId, cell: u32 },
    /// The second half: on resumption the target is resolved ("the values at
    /// the time the process resumes are used to determine the target(s)") and
    /// the parked value written.
    deposit: struct { statement: Ast.StmtId, cell: u32 },
    /// A.6.5 `-> named_event`. §5.10 events "do not hold any data", so this
    /// stores nothing: it resumes whoever waits on the slot now, and a
    /// trigger nobody waits for is gone.
    trigger: u32,
    /// §9.9.2 an `always` body returning to its own start.
    restart: struct { target: u32, tok: u32 },
    /// A.6.5 `disable` of a named block, whose activity is its pc range
    /// [start, end): terminating it drops every resumption into that range.
    /// Patched in after every process is compiled, since a `disable` may
    /// name a block written later.
    disable_block: struct { start: u32, end: u32 },
    /// §6.2.1 a variable declaration assignment: one blocking write of a
    /// whole declared variable, which has a slot and no expression naming it.
    init_var: struct { slot: u32, value: Ast.ExprId },
    /// §10.2.2 a task enable or function call run to completion in place:
    /// copy in, the body at `Sub.entry`, copy out.
    call: struct { sub: u32, args: []const Ast.ExprId, tok: u32 },
    /// §10.2.2 an inlined enable's copy-out: formal `slot` is assigned to
    /// the caller's lvalue `target`, resolved in the caller's scope.
    copy_out: struct { target: Ast.ExprId, slot: u32 },
    /// §10.3 `disable` naming a task: every activation of it ends.
    disable_task: u32,
    /// §10.2.3 enable of a task that suspends and reaches itself: a new
    /// activation of its out-of-line body (`Sub.body`).
    call_timed: struct { sub: u32, args: []const Ast.ExprId },
    /// The end of a `call_timed` activation of task `n`.
    task_return: u32,
    /// Start a process of its own at this pc: §17.5 an asynchronous PLA's,
    /// or §9.7.7 the wait of a nonblocking assignment's event control.
    pla_start: u32,
    /// §9.8.2 `fork`: start every arm as a process of its own; join cell
    /// `join` counts them back, and the parent resumes at `end`.
    fork: struct { arms: []const u32, join: u32, end: u32 },
    /// One `fork` arm finished; the last one resumes the parent at `end`.
    join_arm: struct { join: u32, end: u32 },
    /// §9.3 install a procedural continuous assignment on `slot`: its
    /// out-of-line process [start, end) keeps the slot equal to its expression.
    /// `bits`: §9.3.2's constant select of a vector net, which the override
    /// holds alone (`override_eval` and `override_off` alike).
    override_on: struct { slot: u32, force: bool, start: u32, end: u32, bits: ?Bits = null },
    /// That process's one step: write `value` into `slot` past the guard.
    /// An operand of a §9.3 concatenation target takes bits [lo, lo + its
    /// width) of the value evaluated `of` bits wide.
    override_eval: struct { slot: u32, value: Ast.ExprId, force: bool, slice: ?Slice = null, bits: ?Bits = null },
    /// §9.3 `deassign` / `release`.
    override_off: struct { slot: u32, force: bool, bits: ?Bits = null },
    /// §7.6 a controlled pass switch: read the control, re-resolve both
    /// sides, and wait on the control's operands.
    switch_ctrl: struct { tran: u32, slots: []const u32 },
    stop,
};

/// §9.14 Table 9-11's integral system functions, the two of IEEE 1364 §17.7
/// that read the clock, and §4.2.1.4's `$signed`/`$unsigned` casts: every
/// system function an integral expression may call. `infer` resolves each
/// call once into `Run.sys_calls`; separate from `tasks` because these are
/// expressions.
pub const SysFn = enum {
    /// §17.7.1, 64 bits: "the time unit of the module that invoked it".
    time,
    /// §17.7.1's 32-bit half, "the low order 32 bits of the current
    /// simulation time".
    stime,
    /// §9.14 Table 9-11 / IEEE 1364 §17.11: ceiling of log base 2.
    clog2,
    make_signed,
    make_unsigned,
    /// IEEE 1364-2005 §17.10.1/§17.10.2, the plusarg queries. `vera --run`
    /// takes no plusargs, so every query is §17.10's "no match": an integer
    /// zero, and `$value$plusargs` leaves its variable alone.
    test_plusargs,
    value_plusargs,
    /// §17.6.5 `$q_full(q_id, status)`, which also writes its status.
    q_full,
    /// VAMS §9.22/§9.23 connect-module driver access (`driver.zig`).
    driver_count,
    receiver_count,
    driver_state,
    driver_strength,
    driver_delay,
    driver_next_state,
    driver_next_strength,
    driver_type,
    /// §17.2 the file functions: open, the character, line, formatted and
    /// binary reads, positioning, end-of-file, errors, and §17.2.4.3's
    /// `$sscanf`.
    fopen,
    fgetc,
    ungetc,
    fgets,
    fscanf,
    fread,
    ftell,
    fseek,
    rewind,
    feof,
    ferror,
    sscanf,
    /// §17.7.3, the clock as a real in the module's unit.
    realtime,
    /// §17.8's conversions: `$rtoi` truncates, `$itor` converts, and
    /// `$realtobits`/`$bitstoreal` move the 64 IEEE-754 bits unchanged.
    rtoi,
    itor,
    realtobits,
    bitstoreal,
    /// §17.11.2 Table 17-17's real math functions.
    ln,
    log10,
    exp,
    sqrt,
    floor,
    ceil,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    pow,
    atan2,
    hypot,
    /// §17.9 `$random` and the `$dist_*` functions (`system.dist`).
    random,
    dist_uniform,
    dist_normal,
    dist_exponential,
    dist_poisson,
    dist_chi_square,
    dist_t,
    dist_erlang,

    /// Is a call a constant expression when its arguments are? A replication
    /// count and a case label depend on this. A clock query, a file or queue
    /// operation, a draw from a distribution and a driver query never are.
    fn constant(self: SysFn) bool {
        return switch (self) {
            .time, .stime, .realtime, .test_plusargs, .value_plusargs, .q_full, .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf => false,
            .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => false,
            .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_delay, .driver_next_state, .driver_next_strength, .driver_type => false,
            else => true, // else: a pure function of its arguments
        };
    }

    /// How many real arguments a Table 17-17 function takes, or null for a
    /// function that is not one of them.
    pub fn mathArity(self: SysFn) ?u32 {
        return switch (self) {
            .pow, .atan2, .hypot => 2,
            .ln, .log10, .exp, .sqrt, .floor, .ceil, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => 1,
            else => null, // else: not a math function
        };
    }

    /// Does a call change state besides giving its value: an argument it
    /// writes back, `$random`'s seed, a file's position or table?
    pub fn effects(self: SysFn) bool {
        return switch (self) {
            .q_full, .sscanf, .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ferror, .fseek, .rewind => true,
            .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => true,
            else => false, // else: a function of its arguments, the clock or the design alone
        };
    }

    /// The §17.9 distribution a call draws from, or null for any other.
    pub fn dist(self: SysFn) ?system.Dist {
        return switch (self) {
            .random => .random,
            .dist_uniform => .uniform,
            .dist_normal => .normal,
            .dist_exponential => .exponential,
            .dist_poisson => .poisson,
            .dist_chi_square => .chi_square,
            .dist_t => .t,
            .dist_erlang => .erlang,
            else => null, // else: not a §17.9 function
        };
    }
};

const sys_fns = std.StaticStringMap(SysFn).initComptime(.{
    .{ "$time", .time },
    .{ "$stime", .stime },
    .{ "$clog2", .clog2 },
    .{ "$signed", .make_signed },
    .{ "$unsigned", .make_unsigned },
    .{ "$test$plusargs", .test_plusargs },
    .{ "$value$plusargs", .value_plusargs },
    .{ "$q_full", .q_full },
    .{ "$driver_count", .driver_count },
    .{ "$receiver_count", .receiver_count },
    .{ "$driver_state", .driver_state },
    .{ "$driver_strength", .driver_strength },
    .{ "$driver_delay", .driver_delay },
    .{ "$driver_next_state", .driver_next_state },
    .{ "$driver_next_strength", .driver_next_strength },
    .{ "$driver_type", .driver_type },
    .{ "$fopen", .fopen },
    .{ "$fgetc", .fgetc },
    .{ "$ungetc", .ungetc },
    .{ "$fgets", .fgets },
    .{ "$fscanf", .fscanf },
    .{ "$fread", .fread },
    .{ "$ferror", .ferror },
    .{ "$ftell", .ftell },
    .{ "$fseek", .fseek },
    .{ "$rewind", .rewind },
    .{ "$feof", .feof },
    .{ "$sscanf", .sscanf },
    .{ "$realtime", .realtime },
    .{ "$rtoi", .rtoi },
    .{ "$itor", .itor },
    .{ "$realtobits", .realtobits },
    .{ "$bitstoreal", .bitstoreal },
    .{ "$ln", .ln },
    .{ "$log10", .log10 },
    .{ "$exp", .exp },
    .{ "$sqrt", .sqrt },
    .{ "$floor", .floor },
    .{ "$ceil", .ceil },
    .{ "$sin", .sin },
    .{ "$cos", .cos },
    .{ "$tan", .tan },
    .{ "$asin", .asin },
    .{ "$acos", .acos },
    .{ "$atan", .atan },
    .{ "$sinh", .sinh },
    .{ "$cosh", .cosh },
    .{ "$tanh", .tanh },
    .{ "$asinh", .asinh },
    .{ "$acosh", .acosh },
    .{ "$atanh", .atanh },
    .{ "$pow", .pow },
    .{ "$atan2", .atan2 },
    .{ "$hypot", .hypot },
    .{ "$random", .random },
    .{ "$dist_uniform", .dist_uniform },
    .{ "$dist_normal", .dist_normal },
    .{ "$dist_exponential", .dist_exponential },
    .{ "$dist_poisson", .dist_poisson },
    .{ "$dist_chi_square", .dist_chi_square },
    .{ "$dist_t", .dist_t },
    .{ "$dist_erlang", .dist_erlang },
});

// ---- expression typing (§5.5.1 Table 5-22, §5.1.14) -------------------------

fn leafType(self: *Run, e: Ast.ExprId) Error!Type {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident, .hier_ident => blk: {
            const at = try self.scalarSlot(e);
            // §5.10: events "do not hold any data", so a named event has no
            // value an expression could read.
            if (self.events.contains(at)) return self.exprFail(e, "§5.10: a named event holds no data; it can only be triggered and waited on");
            // IEEE 1364-2005 §4.10.3: "A specify parameter declared outside a
            // specify block shall be declared before it is referenced."
            if (self.specparams.get(at)) |decl| if (ex.tag(e) == .ident and ex.mainTok(e) < decl)
                return self.exprFail(e, "§4.10.3: a specify parameter is declared before it is referenced");
            if (self.reals.contains(at)) break :blk real_type;
            const v = self.values[at];
            const own = if (ex.tag(e) == .ident) self.port_signed.get(.{ .scope = self.scope, .str = ex.strOf(e) }) else null;
            break :blk .{ .width = v.width, .signed = own orelse v.signed };
        },
        .int_literal => blk: {
            const n = ex.intLiteral(e);
            if (n.width == 0 and (if (n.signed) n.value < std.math.minInt(i32) or n.value > std.math.maxInt(i32) else n.value < 0 or n.value > std.math.maxInt(u32)))
                return self.exprFail(e, "unsized constants outside the implemented 32-bit integer width are not supported; use an explicit size");
            break :blk .{ .width = if (n.width == 0) 32 else n.width, .signed = n.signed };
        },
        // An unsized based constant is an integer-sized operand (Table
        // 5-22) whose x/z fill is decided in context (`exec.unsizedFill`).
        .logic_literal => blk: {
            const n = ex.logicValue(e);
            break :blk .{ .width = if (n.sized) n.width else 32, .signed = n.signed };
        },
        // IEEE 1364-2005 §3.6: a string operand is an unsigned number of
        // eight bits per character, and §5.2.3.3's "" is one NUL byte.
        .str_literal => .{ .width = stringWidth(self.file.str(ex.strOf(e))), .signed = false },
        .real_literal => real_type,
        else => self.exprFail(e, "this expression requires digital context typing beyond the implemented leaf operands"), // else: infer calls this for the leaves above only
    };
}

pub fn stringWidth(text: []const u8) u32 {
    return @intCast(@max(1, text.len) * 8);
}

/// §5.5.1/§4.8.1: an operator with a real operand is real.
pub fn common(a: Type, b: Type) Type {
    if (a.real or b.real) return real_type;
    return .{ .width = @max(a.width, b.width), .signed = a.signed and b.signed };
}

pub fn typeOf(self: *Run, e: Ast.ExprId) Type {
    const i = @intFromEnum(e);
    return switch (self.ty_state[i]) {
        .one => self.types[i],
        .many => self.spec_types.get(.{ .spec = self.specOf(self.scope), .e = e }).?,
        .untyped => unreachable, // infer runs before any evaluation
    };
}

pub fn checkExpr(self: *Run, e: Ast.ExprId) Error!void {
    _ = try inferValue(self, e, 0);
}

fn inferValue(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
    const ty = try infer(self, e, depth);
    if (ty.width == 0) return self.exprFail(e, "zero replication requires an immediately enclosing concatenation with a positive-width operand");
    return ty;
}

pub fn constantExpression(self: *Run, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal => return true,
        // §12.2: a parameter is a constant; every other name is not.
        .ident => {
            const at = self.lookup(self.scope, ex.strOf(e)) orelse return false;
            return self.params.contains(at);
        },
        // §5: "constant bit-selects and part-selects of parameters" are
        // constant; the base is a name, which the arm above judges.
        .unary, .binary, .multi_concat, .ternary, .concat, .index, .range, .indexed_range => {},
        // §10.4.5: "A constant function call shall be a function invocation
        // of a constant function local to the calling module where the
        // arguments to the function are constant expressions", "evaluated at
        // elaboration time", so only while elaboration folds.
        .call => {
            if (self.growing == null) return false;
            const idx = self.sub_by_name.get(.{ .scope = self.instanceOf(self.scope), .str = ex.strOf(e) }) orelse return false;
            if (!self.subs.items[idx].framed or !(constantFunction(self, idx) catch false)) return false;
        },
        // §17.7: a call that reads the clock is never constant, however
        // constant its (absent) arguments are. Without this `$time`
        // would be accepted as a replication count.
        .sys_call => if (sys_fns.get(self.file.str(ex.strOf(e)))) |f| {
            if (!f.constant()) return false;
        },
        else => return false, // else: not a form this executor folds
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (!constantExpression(self, c)) return false;
    return true;
}

/// IEEE 1364-2005 §10.4.5: is function `idx` a constant function?
pub fn constantFunction(self: *Run, idx: u32) Error!bool {
    return try notConstant(self, idx) == null;
}

/// Why function `idx` is no §10.4.5 constant function, or null when it is
/// one: every name its body uses is its own (a formal, a local, its result)
/// or a parameter, it holds no hierarchical reference, every function it
/// calls is a constant function of the same module, and every system function
/// it calls may be in a constant expression. Asked of a framed function; one
/// it calls is framed early (`earlyFrame`) if need be. A recursive call is
/// taken as constant while it is being asked about.
/// ponytail: a system task is refused, not ignored as §10.4.5 says, and a
/// named block's own locals are not the function's.
pub fn notConstant(self: *Run, idx: u32) Error!?[]const u8 {
    const sub = &self.subs.items[idx];
    if (sub.constant) |c| return if (c) null else "it is not a constant function";
    if (!sub.decl.is_function) return "it is a task";
    sub.constant = true;
    const V = struct {
        r: *Run,
        sub: *const @import("root.zig").Sub,
        why: ?[]const u8 = null,
        pub fn expr(v: *@This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
            if (x == .none or v.why != null) return;
            const ex = &v.r.file.exprs;
            const f = v.sub.frame;
            v.why = switch (ex.tag(x)) {
                .ident => if (v.r.lookup(f.scope, ex.strOf(x))) |at|
                    if ((at >= f.first and at < f.first + f.count) or v.r.params.contains(at)) null else "it reads a name that is neither its own nor a parameter"
                else
                    "it reads a name that is neither its own nor a parameter",
                .hier_ident => "it contains a hierarchical reference",
                .call => if (v.r.sub_by_name.get(.{ .scope = v.sub.inst, .str = ex.strOf(x) })) |callee| blk: {
                    if (!v.r.subs.items[callee].framed) try @import("root.zig").earlyFrame(v.r, callee, ex.mainTok(x));
                    break :blk if (try notConstant(v.r, callee) == null) null else "it calls a function that is not a constant function";
                } else "it calls a function that is not a constant function",
                .sys_call => if (sys_fns.get(v.r.file.str(ex.strOf(x)))) |sf| if (sf.constant()) null else "it calls a system function no constant expression may" else "it calls a system function no constant expression may",
                else => null, // else: every other form is constant when its operands are
            };
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(x, &buf)) |c| try v.expr(c, .read);
        }
        pub fn stmt(v: *@This(), st: Ast.StmtId) Error!void {
            if (st == .none or v.why != null) return;
            if (v.r.file.stmt(st) == .sys_task) {
                v.why = "it enables a system task";
                return;
            }
            try v.r.file.stmtEdges(st, v);
        }
    };
    var v: V = .{ .r = self, .sub = sub };
    try v.stmt(sub.decl.body);
    sub.constant = v.why == null;
    return v.why;
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
            .plus, .minus, .bit_not => unsizedConcatOperand(self, ex.lhs(e)),
            // One-bit results, sized whatever their operand.
            .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => false,
        },
        .binary => switch (ex.binOp(e)) {
            .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => unsizedConcatOperand(self, ex.lhs(e)) or unsizedConcatOperand(self, ex.rhs(e)),
            .shl, .shr, .ashl, .ashr, .pow => unsizedConcatOperand(self, ex.lhs(e)),
            .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => false,
        },
        .ternary => unsizedConcatOperand(self, ex.rhs(e)) or unsizedConcatOperand(self, ex.ternaryElse(e)),
        else => false, // else: a name, a select, a call or a concatenation has its own size
    };
}

fn replicationCount(self: *Run, e: Ast.ExprId) Error!u32 {
    if (!constantExpression(self, e)) return self.exprFail(e, "integral replication requires a constant expression");
    var scratch = std.heap.ArenaAllocator.init(self.arena);
    defer scratch.deinit();
    const value = try exec.eval(self, scratch.allocator(), e, 0);
    if (value.hasUnknown()) return self.exprFail(e, "replication count cannot contain X or Z");
    if (value.signed and value.bit(value.width - 1) == .one) return self.exprFail(e, "replication count cannot be negative");
    for (value.values()[1..]) |word| if (word != 0) return self.exprFail(e, "replication count exceeds the supported u32 range");
    if (value.values()[0] > std.math.maxInt(u32)) return self.exprFail(e, "replication count exceeds the supported u32 range");
    return @intCast(value.values()[0]);
}

/// A part-select bound or an indexed part-select's width: §5.2.1's constant
/// integer expression, which §4.8.1 keeps a real out of.
fn partBound(self: *Run, e: Ast.ExprId) Error!i64 {
    const v = try self.constant(e, self.file.exprs.mainTok(e));
    if (typeOf(self, e).real) return self.exprFail(e, "§4.8.1: a real is not a part-select bound");
    return v.asInt() orelse self.exprFail(e, "a part-select bound cannot contain x or z");
}

// IEEE1364-2005 Table 5-22, §5.5.1: infer natural size/type bottom-up.
// ponytail: recursive evaluation is bounded to 256 AST levels; an explicit
// stack can remove this ceiling when deeper expressions are needed.
fn infer(self: *Run, e: Ast.ExprId, depth: u16) Error!Type {
    if (e == .none) return self.fail(0, "omitted expressions are not implemented", .{});
    if (depth == 256) return self.exprFail(e, "digital expressions deeper than 256 AST levels are not implemented");
    const key: SpecExpr = .{ .spec = self.specOf(self.scope), .e = e };
    if (self.spec_types.get(key)) |ty| return ty;
    const ex = &self.file.exprs;
    const ty: Type = switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => try leafType(self, e),
        // §3.9 an array element has the element's declared type; the index
        // is self-determined and never widens the result.
        .index => blk: {
            if (try self.indexedArray(e) == null) {
                // IEEE 1364-2005 §5.2.1 a bit- or part-select of a vector, or
                // §5.2.2 of an array element: unsigned, as wide as it
                // selects; the index is self-determined, a part-select's
                // bounds and an indexed one's width constant.
                const lhs = ex.lhs(e);
                if (ex.tag(lhs) != .ident and ex.tag(lhs) != .hier_ident and try self.indexedArray(lhs) == null)
                    return self.exprFail(e, "a select is of a whole vector or an unpacked array element");
                if (ex.tag(lhs) == .index) _ = try inferValue(self, lhs, depth + 1);
                const at = try self.baseSlot(lhs);
                if (self.reals.contains(at)) return self.exprFail(e, "§4.8: a real has no bits to select");
                if (self.isScalar(at)) return self.exprFail(e, "§5.2.1: a scalar has no bits to select");
                const rg = ex.rhs(e);
                switch (ex.tag(rg)) {
                    .range => {
                        const msb = try partBound(self, ex.lhs(rg));
                        const lsb = try partBound(self, ex.rhs(rg));
                        if (@abs(msb - lsb) >= std.math.maxInt(u32)) return self.exprFail(rg, "part-select width is outside the supported u32 range");
                        // "The first expression has to address a more
                        // significant bit than the second expression."
                        const range = self.vecRange(at);
                        if (msb != lsb and (msb > lsb) != (range.msb >= range.lsb))
                            return self.exprFail(rg, "§5.2.1: a part-select names its more significant bit first");
                        try self.part_selects.put(self.arena, key, .{ .msb = msb, .lsb = lsb });
                        break :blk .{ .width = @intCast(@abs(msb - lsb) + 1), .signed = false };
                    },
                    .indexed_range => {
                        const base = try inferValue(self, ex.lhs(rg), depth + 1);
                        if (base.real) return self.exprFail(ex.lhs(rg), "§4.8.1: a real is not a part-select index");
                        if (base.width > 64) return self.exprFail(ex.lhs(rg), "bit indices wider than 64 bits are not implemented");
                        // "the width_expr shall be a positive constant
                        // integer expression". Kept as the part-select
                        // `[width-1:0]`, which only its width is read from.
                        const width = try partBound(self, ex.rhs(rg));
                        if (width < 1 or width >= std.math.maxInt(u32)) return self.exprFail(ex.rhs(rg), "§5.2.1: an indexed part-select's width is a positive constant");
                        try self.part_selects.put(self.arena, key, .{ .msb = width - 1, .lsb = 0 });
                        break :blk .{ .width = @intCast(width), .signed = false };
                    },
                    else => { // else: any other expression is a bit-select's index
                        const index = try inferValue(self, rg, depth + 1);
                        if (index.real) return self.exprFail(rg, "§4.8.1: a real is not a bit-select index");
                        if (index.width > 64) return self.exprFail(rg, "bit indices wider than 64 bits are not implemented");
                        break :blk .{ .width = 1, .signed = false };
                    },
                }
            }
            var x = e;
            while (ex.tag(x) == .index) : (x = ex.lhs(x)) {
                // §5.2.2: "the desired word shall first be selected by
                // supplying an address for each dimension".
                if (ex.tag(ex.rhs(x)) == .range or ex.tag(ex.rhs(x)) == .indexed_range)
                    return self.exprFail(ex.rhs(x), "§5.2.2: each array dimension takes an index, not a part-select");
                const index = try inferValue(self, ex.rhs(x), depth + 1);
                if (index.width > 64) return self.exprFail(ex.rhs(x), "array indices wider than 64 bits are not implemented");
            }
            const base = try self.slot(x);
            if (self.reals.contains(base)) break :blk real_type;
            const v = self.values[base];
            break :blk .{ .width = v.width, .signed = v.signed };
        },
        .unary => blk: {
            const operand = try inferValue(self, ex.lhs(e), depth + 1);
            const op = ex.unOp(e);
            // IEEE 1364-2005 §5.1.1 Table 5-2: a real takes the arithmetic,
            // relational and logical operators, and none of the bitwise ones.
            if (operand.real and op != .plus and op != .minus and op != .logical_not) return self.exprFail(e, "§5.1.1: this operator does not take a real operand");
            break :blk switch (op) {
                .plus, .minus, .bit_not => operand,
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .width = 1, .signed = false },
            };
        },
        .binary => blk: {
            const lhs = try inferValue(self, ex.lhs(e), depth + 1);
            const rhs = try inferValue(self, ex.rhs(e), depth + 1);
            const op = ex.binOp(e);
            if (lhs.real or rhs.real) switch (op) {
                .add, .sub, .mul, .div, .pow, .eq, .neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => {},
                .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr, .case_eq, .case_neq => return self.exprFail(e, "§5.1.1: this operator does not take a real operand"),
            };
            break :blk switch (op) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => common(lhs, rhs),
                .pow => if (rhs.real) real_type else lhs,
                .shl, .shr, .ashl, .ashr => lhs,
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .width = 1, .signed = false },
            };
        },
        .ternary => blk: {
            _ = try inferValue(self, ex.lhs(e), depth + 1);
            const yes = try inferValue(self, ex.rhs(e), depth + 1);
            const no = try inferValue(self, ex.ternaryElse(e), depth + 1);
            break :blk common(yes, no);
        },
        .sys_call => blk: {
            const f = sys_fns.get(self.file.str(ex.strOf(e))) orelse
                return self.exprFail(e, "this digital expression form is not implemented");
            self.sys_calls[@intFromEnum(e)] = f;
            const args = ex.args(e);
            switch (f) {
                // §17.7.1 gives `$time` the 64-bit `time` type and
                // `$stime` its low 32 bits. Both unsigned: simulation
                // time has no negative half.
                .time, .stime => {
                    if (args.len != 0) return self.exprFail(e, "$time and $stime take no arguments");
                    break :blk .{ .width = if (f == .time) 64 else 32, .signed = false };
                },
                // §17.11's result is an `integer`, which §3.2 makes 32-bit
                // signed: `$clog2(x) - 1` at x = 0 is -1, not 4294967295.
                .clog2 => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$clog2 takes exactly one argument");
                    // "The argument can be an integer or an arbitrary sized
                    // vector value" (§17.11.1).
                    if ((try inferValue(self, args[0], depth + 1)).real) return self.exprFail(args[0], "§17.11.1: $clog2 takes an integer or vector argument, not a real");
                    break :blk .{ .width = 32, .signed = true };
                },
                .make_signed, .make_unsigned => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                    const operand = try inferValue(self, args[0], depth + 1);
                    if (operand.real) return self.exprFail(e, "$signed/$unsigned require exactly one integral argument");
                    break :blk .{ .width = operand.width, .signed = f == .make_signed };
                },
                // §17.6.5 `(q_id, status)`, an integer; `status` is written.
                .q_full => {
                    if (args.len != 2 or args[0] == .none or args[1] == .none) return self.exprFail(e, "$q_full takes (q_id, status)");
                    _ = try inferValue(self, args[0], depth + 1);
                    try checkTarget(self, args[1]);
                    break :blk .{ .width = 32, .signed = true };
                },
                // §17.2: every file function returns an integer; the
                // descriptor of `$fopen` is 32 bits with the MSB set.
                .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf => {
                    const lo: usize, const hi: usize = switch (f) {
                        .fopen => .{ 1, 2 },
                        .ungetc, .fgets, .ferror => .{ 2, 2 },
                        .fseek => .{ 3, 3 },
                        .fread => .{ 2, 4 },
                        .sscanf, .fscanf => .{ 2, std.math.maxInt(usize) },
                        else => .{ 1, 1 },
                    };
                    if (args.len < lo or args.len > hi) return self.exprFail(e, "wrong number of arguments to a §17.2 file function");
                    for (args, 0..) |arg, i| {
                        // §17.2.4.4 `$fread(mem, fd, , count)` omits start.
                        if (arg == .none and f == .fread and i == 2) continue;
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.2 file function");
                        // §17.2.4.4 "the reg myreg or the memory mem".
                        if (f == .fread and i == 0 and ex.tag(arg) == .ident) if (self.arrays.get(try self.slot(arg))) |arr| {
                            if (arr.rest.len != 0) return self.exprFail(arg, "§17.2.4.4: $fread loads a one-dimensional memory");
                            continue;
                        };
                        const written = switch (f) {
                            .sscanf, .fscanf => i >= 2,
                            .fgets, .fread => i == 0,
                            .ferror => i == 1,
                            else => false, // else: every other file function only reads its arguments
                        };
                        if (written) try checkTarget(self, arg) else _ = try inferValue(self, arg, depth + 1);
                    }
                    // §17.2.1: "The type is a character string ... of one of
                    // the forms in Table 17-7".
                    if (f == .fopen and args.len == 2 and ex.tag(args[1]) == .str_literal and !system.fileType(self.file.str(ex.strOf(args[1]))))
                        return self.exprFail(args[1], "§17.2.1: an $fopen type is one of Table 17-7's r, w, a, r+, w+, a+ (with b)");
                    break :blk .{ .width = 32, .signed = f != .fopen };
                },
                .realtime => {
                    if (args.len != 0) return self.exprFail(e, "$realtime takes no arguments");
                    break :blk real_type;
                },
                .rtoi, .itor, .realtobits, .bitstoreal => {
                    if (args.len != 1 or args[0] == .none) return self.exprFail(e, "a §17.8 conversion takes exactly one argument");
                    const operand = try inferValue(self, args[0], depth + 1);
                    const wants_real = f == .rtoi or f == .realtobits;
                    if (operand.real != wants_real) return self.exprFail(e, "$rtoi and $realtobits convert a real; $itor and $bitstoreal an integral value");
                    break :blk switch (f) {
                        .rtoi => .{ .width = 32, .signed = true },
                        .realtobits => .{ .width = 64, .signed = false },
                        else => real_type,
                    };
                },
                // §17.10: `(string)` and `(format, variable)`, returning
                // an integer. The variable is written only on a match,
                // so it is checked as a target and never read.
                .test_plusargs, .value_plusargs => {
                    const want: usize = if (f == .test_plusargs) 1 else 2;
                    if (args.len != want or args[0] == .none) return self.exprFail(e, "$test$plusargs takes (string) and $value$plusargs (format, variable)");
                    // §17.10.1: "either a string or a nonreal variable".
                    if ((try inferValue(self, args[0], depth + 1)).real) return self.exprFail(args[0], "§17.10: the plusarg string is a string or a nonreal variable");
                    if (f == .value_plusargs and ex.tag(args[0]) == .str_literal) try plusargFormat(self, args[0]);
                    if (f == .value_plusargs) {
                        if (args[1] == .none) return self.exprFail(e, "$value$plusargs needs a variable to write");
                        try checkTarget(self, args[1]);
                    }
                    break :blk .{ .width = 32, .signed = true };
                },
                .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_delay, .driver_next_state, .driver_next_strength, .driver_type => break :blk try driver.infer(self, e, driver.of(f).?),
                // §17.9: `$random [ ( seed ) ]` and `$dist_*( seed, ... )`,
                // every argument an integer and the result a signed
                // 32-bit integer (§17.9.1).
                .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => {
                    const want: usize = switch (f) {
                        .random => @min(args.len, 1),
                        .dist_uniform, .dist_normal, .dist_erlang => 3,
                        else => 2, // else: the one-parameter distributions
                    };
                    if (args.len != want) return self.exprFail(e, "wrong number of arguments to a §17.9 distribution function");
                    for (args, 0..) |arg, i| {
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.9 distribution function");
                        const t = try inferValue(self, arg, depth + 1);
                        if (i == 0) {
                            // §17.9.1: "The seed argument shall be either a
                            // reg, an integer, or a time variable."
                            if (ex.tag(arg) != .ident or t.real) return self.exprFail(arg, "§17.9.1: the seed argument shall be a reg, integer or time variable");
                            try checkTarget(self, arg);
                        } else if (t.real) return self.exprFail(arg, "§17.9.2: the arguments of a $dist_ function are integer values");
                    }
                    break :blk .{ .width = 32, .signed = true };
                },
                // §17.11.2: every argument is read as a real and the
                // result is real.
                else => {
                    if (args.len != f.mathArity().?) return self.exprFail(e, "wrong number of arguments to a §17.11.2 math function");
                    for (args) |arg| {
                        if (arg == .none) return self.exprFail(e, "wrong number of arguments to a §17.11.2 math function");
                        _ = try inferValue(self, arg, depth + 1);
                    }
                    break :blk real_type;
                }, // else: Table 17-17's math functions, mathArity's rows
            }
        },
        // §10.4 a function call: the function's result variable is its type,
        // so the call site's context never reaches inside it.
        .call => blk: {
            const inst = self.instanceOf(self.scope);
            const idx = self.sub_by_name.get(.{ .scope = inst, .str = ex.strOf(e) }) orelse return self.exprFail(e, "undeclared function");
            if (!self.subs.items[idx].decl.is_function) return self.exprFail(e, "§10.2: a task is enabled as a statement, not called in an expression");
            if (!self.subs.items[idx].framed) try @import("root.zig").earlyFrame(self, idx, ex.mainTok(e));
            const sub = self.subs.items[idx];
            try checkArgs(self, sub.decl, ex.args(e), ex.mainTok(e));
            try self.call_subs.put(self.arena, e, idx - self.sub_base.get(inst).?);
            if (self.reals.contains(sub.frame.result)) break :blk real_type;
            const result = self.values[sub.frame.result];
            break :blk .{ .width = result.width, .signed = result.signed };
        },
        .concat => blk: {
            var width: u32 = 0;
            for (ex.args(e)) |arg| {
                const operand = try infer(self, arg, depth + 1);
                if (operand.real) return self.exprFail(arg, "§5.1.1: a real cannot be a concatenation operand");
                if (unsizedConcatOperand(self, arg)) {
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
            _ = try inferValue(self, ex.lhs(e), depth + 1);
            const operand = try inferValue(self, ex.rhs(e), depth + 1);
            const count = try replicationCount(self, ex.lhs(e));
            const width = std.math.mul(u32, count, operand.width) catch return self.exprFail(e, "replication width exceeds the supported u32 range");
            try self.replications.put(self.arena, key, count);
            break :blk .{ .width = width, .signed = false };
        },
        // VAMS §7.3.3 / §7.3.6.3 a potential probe of a continuous net, read
        // from the analog solution through the mixed-signal kernel's hook.
        .branch_access => blk: {
            if (!self.mixed or !std.mem.eql(u8, self.file.str(ex.strOf(e)), "V") or ex.tag(ex.lhs(e)) != .ident or
                (ex.rhs(e) != .none and ex.tag(ex.rhs(e)) != .ident))
                return self.exprFail(e, "only a V(net) or V(net, net) probe of the analog solution is implemented in a digital expression");
            self.has_probes = true;
            break :blk real_type;
        },
        else => return self.exprFail(e, "this digital expression form is not implemented"), // else: the analog-only forms (access functions, filters, patterns, events), refused out loud
    };
    try self.spec_types.put(self.arena, key, ty);
    const i = @intFromEnum(e);
    switch (self.ty_state[i]) {
        .untyped => {
            self.types[i] = ty;
            self.ty_state[i] = .one;
        },
        .one => if (!std.meta.eql(self.types[i], ty)) {
            self.ty_state[i] = .many;
        },
        .many => {},
    }
    return ty;
}

/// §17.10.2: a literal user_string's conversions are "the only valid ones",
/// `%d %o %h %b %e %f %g %s` in either case, with a leading 0 allowed.
fn plusargFormat(self: *Run, e: Ast.ExprId) Error!void {
    const text = self.file.str(self.file.exprs.strOf(e));
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '%')) |at| {
        i = at + 1;
        while (i < text.len and text[i] == '0') i += 1;
        if (i == text.len or std.mem.indexOfScalar(u8, "dohbefgsDOHBEFGS", text[i]) == null)
            return self.fail(self.file.exprs.mainTok(e), "§17.10.2: a $value$plusargs format is one of %d %o %h %b %e %f %g %s, not `%{s}`", .{text[@min(i, text.len)..@min(i + 1, text.len)]});
        i += 1;
    }
}

// ---- statements -> bytecode (A.6.5, §8.5.3.3, §9.7.5) -----------------------

fn position(self: *Run) u32 {
    return @intCast(self.code.items.len);
}

pub fn append(self: *Run, instruction: Instruction) Error!u32 {
    if (self.code.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital instructions", .{});
    const at = position(self);
    try self.code.append(self.arena, instruction);
    try self.code_scope.append(self.arena, self.scope);
    return at;
}

pub fn compileStmt(self: *Run, id: Ast.StmtId, depth: u16) Error!void {
    const tok = self.file.stmtTok(id);
    if (depth == 256) return self.fail(tok, "digital statements deeper than 256 AST levels are not implemented", .{});
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| {
            // IEEE 1364-2005 §12.7: a named block's declarations are a scope
            // of their own, searched before the one around it, so a local
            // shadows a module variable of the same name. The block's name
            // stays in the enclosing scope, where `disable` finds it.
            // Pass one made the scope (`root.blockScopes`), except in an
            // automatic activation's copy, which gets one here.
            // ponytail: `%m` inside such a block names the block but not the
            // named blocks around it.
            const outer = self.scope;
            defer self.scope = outer;
            if (self.block_scopes.get(.{ .scope = outer, .stmt = id })) |inner| {
                self.scope = inner;
            } else if (b.vars.len != 0 or b.params.len != 0 or b.events.len != 0) {
                self.scope = try @import("root.zig").blockScope(self, outer, id);
            }
            const start = position(self);
            if (b.parallel) try compileFork(self, b.body, depth) else for (b.body) |s| try compileStmt(self, s, depth + 1);
            self.scope = outer;
            if (b.name != .none) {
                const entry = try self.blocks.getOrPut(self.arena, .{ .scope = self.scope, .str = b.name });
                if (entry.found_existing) return self.fail(tok, "duplicate named block", .{});
                // `end` is one past the block, which is the statement
                // execution continues with once the block is terminated.
                entry.value_ptr.* = .{ .start = start, .end = position(self), .depth = depth };
            }
        },
        // A.6.5 `disable_statement`. The range is patched in once every
        // process exists (`Run.disables`).
        .disable => |s| {
            const at = try append(self, .{ .disable_block = .{ .start = 0, .end = 0 } });
            try self.disables.append(self.arena, .{ .at = at, .name = .{ .scope = self.scope, .str = s.name }, .tok = tok });
        },
        .if_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "conditional generate is not implemented", .{});
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.then_s, depth + 1);
            if (s.else_s == .none) {
                self.code.items[test_pc].branch.otherwise = position(self);
            } else {
                const end_pc = try append(self, .{ .jump = 0 });
                self.code.items[test_pc].branch.otherwise = position(self);
                try compileStmt(self, s.else_s, depth + 1);
                self.code.items[end_pc].jump = position(self);
            }
        },
        .while_stmt => |s| {
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.code.items[test_pc].branch.otherwise = position(self);
        },
        .for_stmt => |s| {
            try compileStmt(self, s.init, depth + 1);
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            try compileStmt(self, s.step, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.code.items[test_pc].branch.otherwise = position(self);
        },
        .repeat_stmt => |s| {
            try checkExpr(self, s.count);
            if (typeOf(self, s.count).width > 64) return self.exprFail(s.count, "repeat counts wider than 64 bits are not implemented");
            if (self.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
            const counter: u32 = @intCast(self.repeats.items.len);
            try self.repeats.append(self.arena, 0);
            const test_pc = try append(self, .{ .repeat_start = .{ .count = s.count, .counter = counter, .end = 0 } });
            const body_pc = position(self);
            try compileStmt(self, s.body, depth + 1);
            _ = try append(self, .{ .repeat_next = .{ .counter = counter, .body = body_pc } });
            self.code.items[test_pc].repeat_start.end = position(self);
        },
        .case_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "case generate is not implemented", .{});
            if (s.arms.len == 0) return self.fail(tok, "a case statement requires at least one item", .{});
            try checkExpr(self, s.scrutinee);
            var ty = typeOf(self, s.scrutinee);
            var have_default = false;
            for (s.arms) |arm| {
                if (arm.labels.len == 0) {
                    if (have_default) return self.fail(tok, "a case statement cannot have multiple default items", .{});
                    have_default = true;
                }
                for (arm.labels) |label| {
                    try checkExpr(self, label);
                    ty = common(ty, typeOf(self, label));
                }
            }
            if (s.arms.len > std.math.maxInt(u32) - self.case_targets.items.len) return self.fail(tok, "too many case targets", .{});
            const targets: u32 = @intCast(self.case_targets.items.len);
            try self.case_targets.appendNTimes(self.arena, 0, s.arms.len);
            const dispatch = try append(self, .{ .case_select = .{ .statement = id, .targets = targets, .fallback = 0, .ty = ty } });
            const exits = try self.arena.alloc(u32, s.arms.len);
            for (s.arms, 0..) |arm, i| {
                self.case_targets.items[targets + i] = position(self);
                if (arm.labels.len == 0) self.code.items[dispatch].case_select.fallback = position(self);
                try compileStmt(self, arm.body, depth + 1);
                exits[i] = try append(self, .{ .jump = 0 });
            }
            const end = position(self);
            if (!have_default) self.code.items[dispatch].case_select.fallback = end;
            for (exits) |at| self.code.items[at].jump = end;
        },
        .assign => |s| if (s.continuous != .none) try compileProcContinuous(self, s.target, s.value, s.continuous, tok) else {
            // §10.4.4: "Functions shall not contain any time-controlled
            // statements" and "shall not have any nonblocking assignments".
            if (self.in_function and s.nonblocking) return self.fail(tok, "§10.4.4: a function body cannot contain a nonblocking assignment", .{});
            if (self.in_function and s.timing != .none) return self.fail(tok, "§10.4.4: a function body cannot contain a time control", .{});
            try checkTarget(self, s.target);
            if (s.nonblocking) try notAutomatic(self, s.target, "a nonblocking assignment");
            try checkExpr(self, s.value);
            if (s.timing == .none) {
                _ = try append(self, .{ .assign = .{ .target = s.target, .value = s.value, .nonblocking = s.nonblocking } });
                return;
            }
            // A.6.2's intra-assignment `delay_or_event_control`, §8.5.3.3.
            if (s.timing_is_delay) try checkDelay(self, s.timing) else {
                try checkEvent(self, s.timing);
                if (s.timing_repeat != .none) {
                    try checkExpr(self, s.timing_repeat);
                    if (typeOf(self, s.timing_repeat).width > 64) return self.exprFail(s.timing_repeat, "repeat counts wider than 64 bits are not implemented");
                }
            }
            if (self.holds.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many intra-assignment timing controls", .{});
            const cell: u32 = @intCast(self.holds.items.len);
            try self.holds.append(self.arena, try filled(self.arena, 1, false, .x));
            _ = try append(self, .{ .sample = .{ .statement = id, .cell = cell } });
            // §8.5.3.4: a nonblocking one with a delay schedules the update
            // and falls through, so it has no resumption point and needs no
            // `deposit`.
            if (s.nonblocking and s.timing_is_delay) return;
            if (!parksOnly(s)) {
                _ = try append(self, .{ .deposit = .{ .statement = id, .cell = cell } });
                return;
            }
            // A nonblocking one with an event control falls through too: a
            // process of its own waits and then queues the update.
            // ponytail: the value is parked per site, so a second sample
            // before the first's event replaces it.
            var skip: ?u32 = null;
            if (s.nonblocking) {
                _ = try append(self, .{ .pla_start = position(self) + 2 });
                skip = try append(self, .{ .jump = 0 });
            }
            // §9.7.7 `repeat (n) @(e)`: n occurrences, none when n <= 0.
            if (s.timing_repeat != .none) {
                if (self.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
                const counter: u32 = @intCast(self.repeats.items.len);
                try self.repeats.append(self.arena, 0);
                const test_pc = try append(self, .{ .repeat_start = .{ .count = s.timing_repeat, .counter = counter, .end = 0, .clamp = true } });
                const body_pc = position(self);
                _ = try append(self, .{ .wait_event = s.timing });
                _ = try append(self, .{ .repeat_next = .{ .counter = counter, .body = body_pc } });
                self.code.items[test_pc].repeat_start.end = position(self);
            } else _ = try append(self, .{ .wait_event = s.timing });
            _ = try append(self, .{ .deposit = .{ .statement = id, .cell = cell } });
            if (skip) |at| {
                _ = try append(self, .stop);
                self.code.items[at].jump = position(self);
            }
        },
        // A.6.5 `event_trigger`. The slot is resolved here, not at run
        // time, so a trigger cannot fail in the middle of a dispatch.
        .event_trigger => |s| {
            if (self.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain an event trigger", .{});
            const at = self.lookup(self.scope, s.name) orelse
                return self.fail(tok, "undeclared named event", .{});
            const decl = self.events.get(at) orelse return self.fail(tok, "§5.10.4: `->` triggers a named event, not a variable or net", .{});
            if (tok < decl) return self.fail(tok, "§9.7.3: a named event is declared before it is used", .{});
            _ = try append(self, .{ .trigger = at });
        },
        .event_control => |s| {
            if (self.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain a time control", .{});
            // A.6.5 `@*`. The terms come from the body, so the body has to
            // be type-checked before they can be read off it: emit the wait
            // with an empty list, compile the body, then patch the list in.
            if (s.event == .none) {
                const at = try append(self, .{ .wait_slots = &.{} });
                try compileStmt(self, s.body, depth + 1);
                var watched: std.ArrayList(u32) = .empty;
                try readSlots(self, s.body, &watched, depth);
                // §9.7.5's list is what the statement reads; one that reads
                // nothing would suspend forever.
                if (watched.items.len == 0) return self.fail(tok, "§9.7.5: `@*` needs the statement to read at least one net or variable", .{});
                self.code.items[at].wait_slots = watched.items;
                return;
            }
            switch (s.kind) {
                .event => {
                    try checkEvent(self, s.event);
                    _ = try append(self, .{ .wait_event = s.event });
                },
                .delay => {
                    try checkDelay(self, s.event);
                    _ = try append(self, .{ .delay = .{ .amount = s.event, .tok = tok } });
                },
                // A.6.5 `wait_statement`: the condition's operands are the
                // wake-up list, but unlike `@` they only bring the process
                // back to the same pc to re-test the level.
                .level => {
                    try checkExpr(self, s.event);
                    var watched: std.ArrayList(u32) = .empty;
                    try sensitivity(self, s.event, &watched);
                    // IEEE 1364-2005 §9.7.6 tests the level first. An empty
                    // list is legal: true continues, false suspends forever.
                    _ = try append(self, .{ .wait_level = .{ .cond = s.event, .slots = watched.items } });
                },
            }
            try compileStmt(self, s.body, depth + 1);
        },
        .sys_task => |s| {
            const name = self.file.str(s.name);
            if (name[0] != '$') return compileEnable(self, s.name, s.args, tok, depth);
            if (std.mem.eql(u8, name, "$sdf_annotate")) return self.failWith(.E1102, tok, "", .{});
            // §17.4.2 Syntax 17-12 `$stop [ ( n ) ]`, refused by the runner
            // below either way.
            if (std.mem.eql(u8, name, "$stop") and s.args.len > 1) return self.fail(tok, "$stop accepts zero or one argument", .{});
            if (@import("evcd.zig").tasks.get(name)) |op| {
                try @import("evcd.zig").check(self, op, s.args, tok);
                _ = try append(self, .{ .task = .{ .task = .{ .ports = op }, .args = s.args, .tok = tok } });
                return;
            }
            const task = tasks.get(name) orelse return self.fail(tok, "digital system task `{s}` is not implemented", .{name});
            switch (task) {
                // All three format the same surface, so all three are
                // validated by the same dry run.
                .show, .strobe, .monitor => |sh| {
                    if (task == .monitor) for (s.args) |a| if (a != .none) try notAutomatic(self, a, "$monitor");
                    try display.display(self, s.args, null, sh);
                },
                .monitor_enable => if (s.args.len != 0)
                    return self.fail(tok, "$monitoron and $monitoroff take no arguments", .{}),
                .timeformat => {
                    // §17.3.2 Syntax 17-10: no arguments (Table 17-11's
                    // defaults), or all four. The three numbers are read once
                    // when the task runs, so an expression is legal and a
                    // later change to it is not tracked.
                    const ex = &self.file.exprs;
                    if (s.args.len != 0 and s.args.len != 4) return self.fail(tok, "$timeformat takes no arguments or exactly four", .{});
                    if (s.args.len == 4) {
                        for ([_]Ast.ExprId{ s.args[0], s.args[1], s.args[3] }) |a| {
                            if (a == .none) return self.fail(tok, "$timeformat's units, precision and minimum width are required", .{});
                            try checkExpr(self, a);
                        }
                        if (s.args[2] == .none or ex.tag(s.args[2]) != .str_literal)
                            return self.exprFail(s.args[2], "$timeformat's suffix must be a string literal");
                        // "The units number argument shall be an integer in
                        // the range from 0 to -15" (Table 17-10).
                        if (constantExpression(self, s.args[0])) if ((try self.constant(s.args[0], tok)).asInt()) |u|
                            if (u > 0 or u < -15) return self.exprFail(s.args[0], "§17.3.2: $timeformat's units number shall be in the range from 0 to -15");
                    }
                },
                .readmem => {
                    const ex = &self.file.exprs;
                    if (s.args.len < 2 or s.args.len > 4)
                        return self.fail(tok, "$readmemb/$readmemh take (file, memory [, start [, finish]])", .{});
                    if (s.args[0] == .none or ex.tag(s.args[0]) != .str_literal)
                        return self.exprFail(s.args[0], "the memory file name must be a string literal");
                    // ponytail: one dimension; §17.2.9's order over several
                    // is the row-major walk, when a source loads one.
                    const arr = if (s.args[1] == .none or ex.tag(s.args[1]) != .ident) null else self.arrays.get(try self.slot(s.args[1]));
                    if (arr == null or arr.?.rest.len != 0)
                        return self.exprFail(s.args[1], "$readmemb/$readmemh load a one-dimensional unpacked array");
                    for (s.args[2..]) |a| {
                        if (a == .none or !constantExpression(self, a))
                            return self.exprFail(a, "the $readmem address bounds must be constant");
                        try checkExpr(self, a);
                    }
                },
                // §17.6: four arguments, the last the status; which of the
                // others are written depends on the task.
                .queue => |op| {
                    if (s.args.len != 4) return self.fail(tok, "the §17.6 queue tasks take four arguments", .{});
                    for (s.args, 0..) |a, i| {
                        if (a == .none) return self.fail(tok, "the §17.6 queue tasks take four arguments", .{});
                        const written = i == 3 or (op == .remove and i != 0) or (op == .exam and i == 2);
                        if (written) try checkTarget(self, a) else try checkExpr(self, a);
                    }
                },
                // §17.5 `(memory, inputs, outputs)`. An asynchronous array is
                // its own process from here on: the loop is compiled out of
                // line, jumped over, and started by `.pla_start`.
                .pla => |p| {
                    if (s.args.len != 3 or s.args[0] == .none or s.args[1] == .none or s.args[2] == .none)
                        return self.fail(tok, "a §17.5 PLA task takes (memory, inputs, outputs)", .{});
                    const ex = &self.file.exprs;
                    const arr = if (ex.tag(s.args[0]) != .ident) null else self.arrays.get(try self.slot(s.args[0]));
                    if (arr == null or arr.?.rest.len != 0) return self.exprFail(s.args[0], "a §17.5 personality is a one-dimensional memory");
                    // §17.5.3: "PLA input terms, output terms, and memory
                    // shall be specified in ascending order".
                    // ponytail: the bit range only; `Array` keeps no word-range direction.
                    const rows = self.vecRange(try self.slot(s.args[0]));
                    if (rows.msb > rows.lsb) return self.exprFail(s.args[0], "§17.5.3: a PLA personality's bit range is ascending, as in reg [1:n]");
                    try checkExpr(self, s.args[1]);
                    try checkTarget(self, s.args[2]);
                    if (p.async_) {
                        var sync = p;
                        sync.async_ = false;
                        const skip = try append(self, .{ .jump = 0 });
                        const loop = position(self);
                        _ = try append(self, .{ .task = .{ .task = .{ .pla = sync }, .args = s.args, .tok = tok } });
                        var watched: std.ArrayList(u32) = .empty;
                        const base = try self.slot(s.args[0]);
                        for (0..arr.?.count) |i| try watch(self, base + @as(u32, @intCast(i)), &watched);
                        try sensitivity(self, s.args[1], &watched);
                        _ = try append(self, .{ .wait_slots = watched.items });
                        _ = try append(self, .{ .jump = loop });
                        self.code.items[skip].jump = position(self);
                        _ = try append(self, .{ .pla_start = loop });
                        return;
                    }
                },
                .dump => |op| try @import("vcd.zig").check(self, op, s.args, tok),
                .ports => unreachable, // `evcd.tasks` is looked up first
                // §17.2.2: the descriptor, then `$display`'s own arguments.
                .fshow => |sh| {
                    if (s.args.len == 0 or s.args[0] == .none) return self.fail(tok, "a §17.2.2 file output task's first argument is a descriptor", .{});
                    try checkExpr(self, s.args[0]);
                    try display.display(self, s.args[1..], null, sh);
                },
                // §17.2.3: the variable, then `$fwrite`'s own arguments; for
                // `$sformat` a format first ("always interprets its second
                // argument ... as a format string").
                .sshow, .sformat => {
                    if (s.args.len == 0 or s.args[0] == .none) return self.fail(tok, "a §17.2.3 string output task's first argument is a variable", .{});
                    try checkTarget(self, s.args[0]);
                    if (task == .sshow) try display.display(self, s.args[1..], null, task.sshow) else {
                        if (s.args.len < 2 or s.args[1] == .none) return self.fail(tok, "$sformat's second argument is its format", .{});
                        try display.sformat(self, s.args[1..], null);
                    }
                },
                // §17.3.1 Syntax 17-9.
                .printtimescale => {
                    if (s.args.len > 1) return self.fail(tok, "$printtimescale takes at most one module instance", .{});
                    if (s.args.len == 1) _ = try display.timescaleScope(self, s.args[0]);
                },
                .fclose => {
                    if (s.args.len != 1 or s.args[0] == .none) return self.fail(tok, "$fclose takes one descriptor", .{});
                    try checkExpr(self, s.args[0]);
                },
                // §17.2.6 `$fflush ( mcd )`, `( fd )` or `( )`.
                .fflush => {
                    if (s.args.len > 1) return self.fail(tok, "$fflush takes at most one descriptor", .{});
                    for (s.args) |a| if (a != .none) try checkExpr(self, a);
                },
                // §17.4.1: the argument is an expression selecting how much
                // is printed (0, 1 or 2), read when the task runs.
                .finish => {
                    if (s.args.len > 1) return self.fail(tok, "$finish accepts zero or one argument", .{});
                    if (s.args.len == 1) {
                        if (s.args[0] == .none) return self.fail(tok, "$finish's argument is an expression", .{});
                        try checkExpr(self, s.args[0]);
                    }
                },
            }
            _ = try append(self, .{ .task = .{ .task = task, .args = s.args, .tok = tok } });
        },
        else => return self.fail(tok, "this digital statement is not implemented", .{}), // else: the analog statements (contribution, indirect, jump), refused out loud
    }
}

/// IEEE 1364-2005 §9.3: `assign`/`force` compile an out-of-line process that
/// re-writes the target whenever the expression's operands change, and an
/// `.override_on` that starts it; `deassign`/`release` stop it. `assign`
/// takes a variable (§9.3.1); `force` a variable or a net (§9.3.2).
fn compileProcContinuous(self: *Run, target: Ast.ExprId, value: Ast.ExprId, kind: Ast.ProcContinuous, tok: u32) Error!void {
    if (self.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain a procedural continuous assignment", .{});
    const ex = &self.file.exprs;
    // §9.3 "a concatenation of variables" (and for `force`, of nets): one
    // override per operand, each keeping its own bits of the value.
    if (ex.tag(target) == .concat) {
        const ops = ex.args(target);
        var of: u32 = 0;
        for (ops) |x| of += overWidth(self, try overTarget(self, x));
        var lo = of;
        for (ops) |x| {
            lo -= overWidth(self, try overTarget(self, x));
            try override(self, x, value, kind, .{ .lo = lo, .of = of });
        }
        return;
    }
    return override(self, target, value, kind, null);
}

pub const Slice = struct { lo: u32, of: u32 };
pub const Bits = struct { lo: u32, width: u32 };
const OverTarget = struct { at: u32, bits: ?Bits };

fn overWidth(self: *Run, t: OverTarget) u32 {
    return if (t.bits) |b| b.width else self.values[t.at].width;
}

/// A §9.3 target's slot and, for §9.3.2's "constant bit-select of a vector
/// net, a part-select of a vector net", the bits it names.
fn overTarget(self: *Run, x: Ast.ExprId) Error!OverTarget {
    const ex = &self.file.exprs;
    const refused = "§9.3: a procedural continuous assignment names one whole variable or net, a constant bit-select or part-select of a vector net, or a concatenation of them";
    switch (ex.tag(x)) {
        .ident, .hier_ident => return .{ .at = try self.scalarSlot(x), .bits = null },
        .index => {
            const base = ex.lhs(x);
            if (ex.tag(base) != .ident and ex.tag(base) != .hier_ident or try self.indexedArray(x) != null) return self.exprFail(x, refused);
            const at = try self.scalarSlot(base);
            if (!self.net_of.contains(at)) return self.exprFail(x, refused);
            try checkExpr(self, x);
            const rg = ex.rhs(x);
            const index = switch (ex.tag(rg)) {
                .range => Ast.ExprId.none,
                .indexed_range => ex.lhs(rg),
                else => rg, // else: a bit-select's index
            };
            if (index != .none and !constantExpression(self, index)) return self.exprFail(x, refused);
            const sel = (try exec.selection(self, self.arena, x)) orelse return self.exprFail(x, "§9.3.2: the select's index is x or z");
            if (sel.first < 0 or sel.first + sel.count > self.values[at].width) return self.exprFail(x, "§9.3.2: the select is outside its net");
            return .{ .at = at, .bits = .{ .lo = @intCast(sel.first), .width = sel.count } };
        },
        else => return self.exprFail(x, refused), // else: no other expression names storage
    }
}

/// §9.3 one override of `target`: a whole variable or net, or bits of a net.
fn override(self: *Run, target: Ast.ExprId, value: Ast.ExprId, kind: Ast.ProcContinuous, slice: ?Slice) Error!void {
    const t = try overTarget(self, target);
    const at = t.at;
    try notAutomatic(self, target, "a procedural continuous assignment");
    const force = kind == .force or kind == .release;
    if (!force and self.net_of.contains(at)) return self.exprFail(target, "§9.3.1: assign/deassign take a variable; a net is forced");
    if (kind == .deassign or kind == .release) {
        _ = try append(self, .{ .override_off = .{ .slot = at, .force = force, .bits = t.bits } });
        return;
    }
    try checkExpr(self, value);
    var watched: std.ArrayList(u32) = .empty;
    try sensitivity(self, value, &watched);
    const skip = try append(self, .{ .jump = 0 });
    const start = position(self);
    _ = try append(self, .{ .override_eval = .{ .slot = at, .value = value, .force = force, .slice = slice, .bits = t.bits } });
    _ = try append(self, .{ .wait_slots = watched.items });
    _ = try append(self, .{ .jump = start });
    const end = position(self);
    self.code.items[skip].jump = end;
    _ = try append(self, .{ .override_on = .{ .slot = at, .force = force, .start = start, .end = end, .bits = t.bits } });
}

/// IEEE 1364-2005 §9.8.2 a parallel block: each statement is compiled as an
/// arm ending in `.join_arm`; `.fork` starts them all and suspends the parent
/// until the last one is back, which resumes it at the end of the block.
fn compileFork(self: *Run, body: []const Ast.StmtId, depth: u16) Error!void {
    const join: u32 = @intCast(self.joins.items.len);
    try self.joins.append(self.arena, 0);
    const arms = try self.arena.alloc(u32, body.len);
    const at = try append(self, .{ .fork = .{ .arms = arms, .join = join, .end = 0 } });
    const ends = try self.arena.alloc(u32, body.len);
    for (body, arms, ends) |s, *arm, *end| {
        arm.* = position(self);
        try compileStmt(self, s, depth + 1);
        end.* = try append(self, .{ .join_arm = .{ .join = join, .end = 0 } });
    }
    self.code.items[at].fork.end = position(self);
    for (ends) |e| self.code.items[e].join_arm.end = position(self);
}

// ---- tasks and functions (IEEE 1364-2005 §10) --------------------------------

/// Compiles every subroutine that runs synchronously into a body of its own,
/// entered by `.call`: every function, and every task with no timing control
/// (§10.2.1 allows one in a task; §10.4.4 forbids it in a function).
pub fn compileSubs(self: *Run) Error!void {
    for (0..self.subs.items.len) |i| try compileSub(self, @intCast(i));
}

/// Subroutine `idx`'s body at a pc range of its own, unless it is a timed
/// task, which is inlined where it is enabled.
pub fn compileSub(self: *Run, idx: u32) Error!void {
    if (try timed(self, idx)) return;
    const sub = &self.subs.items[idx];
    self.scope = sub.frame.scope;
    self.in_function = sub.decl.is_function;
    defer self.in_function = false;
    sub.entry = position(self);
    try compileStmt(self, sub.decl.body, 0);
    _ = try append(self, .stop);
}

/// Task `idx`'s body compiled once, jumped over where it is emitted, for
/// `.call_timed`. An automatic task gets a frame of its own, which each
/// activation fills in turn; a static one shares its one frame (§10.2.3).
/// ponytail: `disable` of the task stops its inlined copies, not these
/// activations; and `repeat` counters and intra-assignment cells are per
/// site, so a body that suspends inside one of them across its own
/// recursion shares it.
fn outOfLine(self: *Run, idx: u32, depth: u16) Error!void {
    if (self.subs.items[idx].body != null) return;
    const decl = self.subs.items[idx].decl;
    const f = if (decl.automatic) try @import("root.zig").frame(self, decl, self.subs.items[idx].inst) else self.subs.items[idx].frame;
    const skip = try append(self, .{ .jump = 0 });
    self.subs.items[idx].body = .{ .entry = position(self), .frame = f };
    const caller = self.scope;
    self.scope = f.scope;
    try compileStmt(self, decl.body, depth + 1);
    _ = try append(self, .{ .task_return = idx });
    self.scope = caller;
    self.code.items[skip].jump = position(self);
}

/// Does task `idx` contain a timing control, directly or through a task it
/// enables? Such a task can suspend, so it is inlined where it is enabled.
/// A recursive enable is taken as untimed while it is being asked about.
fn timed(self: *Run, idx: u32) Error!bool {
    const sub = &self.subs.items[idx];
    if (sub.timed) |t| return t;
    sub.timed = false;
    const t = !sub.decl.is_function and try stmtTimed(self, sub.inst, sub.decl.body);
    self.subs.items[idx].timed = t;
    return t;
}

fn stmtTimed(self: *Run, inst: u32, id: Ast.StmtId) Error!bool {
    if (id == .none) return false;
    return switch (self.file.stmt(id)) {
        .event_control => true,
        .assign => |s| s.timing != .none,
        .block => |b| for (b.body) |s| {
            if (try stmtTimed(self, inst, s)) break true;
        } else false,
        .if_stmt => |s| try stmtTimed(self, inst, s.then_s) or try stmtTimed(self, inst, s.else_s),
        .while_stmt => |s| try stmtTimed(self, inst, s.body),
        .repeat_stmt => |s| try stmtTimed(self, inst, s.body),
        .for_stmt => |s| try stmtTimed(self, inst, s.body),
        .case_stmt => |s| for (s.arms) |arm| {
            if (try stmtTimed(self, inst, arm.body)) break true;
        } else false,
        .sys_task => |s| blk: {
            if (self.file.str(s.name)[0] == '$') break :blk false;
            const callee = self.sub_by_name.get(.{ .scope = inst, .str = s.name }) orelse break :blk false;
            break :blk try timed(self, callee);
        },
        else => false, // else: no other statement suspends or nests one
    };
}

/// §10.2.2's argument rules, for an enable and for a call: one argument per
/// formal and none of them null, and an output or inout argument an lvalue
/// the value can be copied back into.
fn checkArgs(self: *Run, decl: *const Ast.Subroutine, args: []const Ast.ExprId, tok: u32) Error!void {
    if (args.len != decl.ports.len) return self.fail(tok, "`{s}` takes {d} arguments, not {d}", .{ self.file.str(decl.name), decl.ports.len, args.len });
    const ex = &self.file.exprs;
    for (decl.ports, args) |p, a| {
        if (a == .none) return self.fail(tok, "§10.2.2: null task arguments are not permitted", .{});
        if (p.direction != .input) {
            switch (ex.tag(a)) {
                .ident, .hier_ident, .index, .concat => {},
                else => return self.exprFail(a, "§10.2.2: a task output actual must be a procedural lvalue"), // else: every other form is an expression
            }
            try checkTarget(self, a);
        }
        if (p.direction != .output) try checkExpr(self, a);
    }
}

/// §10.2.2 a task enable. An untimed task is one `.call`; a timed one is
/// inlined here (copy in, the body in the task's frame, copy out), so its
/// suspensions are this process's own. A static task shares one frame
/// between every such copy (§10.2.3); an automatic one gets a frame per call
/// site, which is per activation because a site cannot be re-entered while
/// its process is suspended inside it.
fn compileEnable(self: *Run, name: Ast.StrId, args: []const Ast.ExprId, tok: u32, depth: u16) Error!void {
    if (self.in_function) return self.fail(tok, "§10.4.4: a function cannot enable a task", .{});
    var inst = self.instanceOf(self.scope);
    var leaf = name;
    // IEEE 1364-2005 A.6.9 `hierarchical_task_identifier`: the parts before
    // the last dot name instances as a §12.5 reference's do, and the task is
    // the last part, declared in the final one.
    const text = self.file.str(name);
    if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| {
        var parts = std.mem.splitScalar(u8, text[0..dot], '.');
        var k: usize = 0;
        while (parts.next()) |part| : (k += 1) {
            const str = self.file.strings.find(part) orelse return self.fail(tok, "undeclared instance `{s}` in a hierarchical task name", .{part});
            inst = (if (k == 0) self.upward(str) else self.instances.get(.{ .scope = inst, .str = str })) orelse
                return self.fail(tok, "undeclared instance `{s}` in a hierarchical task name", .{part});
        }
        leaf = self.file.strings.find(text[dot + 1 ..]) orelse return self.fail(tok, "undeclared task `{s}`", .{text});
    }
    const idx = self.sub_by_name.get(.{ .scope = inst, .str = leaf }) orelse return self.fail(tok, "undeclared task `{s}`", .{self.file.str(name)});
    const decl = self.subs.items[idx].decl;
    if (decl.is_function) return self.fail(tok, "§10.4: a function is called in an expression, not enabled", .{});
    try checkArgs(self, decl, args, tok);
    if (!try timed(self, idx)) {
        _ = try append(self, .{ .call = .{ .sub = idx, .args = args, .tok = tok } });
        return;
    }
    // A timed task reaching itself would inline forever: that enable, and
    // every later one inside the body, is an activation of one out-of-line
    // copy instead, with a frame per activation (§10.2.3).
    if (self.subs.items[idx].inlining) {
        try outOfLine(self, idx, depth);
        _ = try append(self, .{ .call_timed = .{ .sub = idx, .args = args } });
        return;
    }
    self.subs.items[idx].inlining = true;
    defer self.subs.items[idx].inlining = false;
    const f = if (decl.automatic) try @import("root.zig").frame(self, decl, inst) else self.subs.items[idx].frame;
    const start = position(self);
    for (decl.ports, args, f.ports) |p, a, slot| if (p.direction != .output) {
        _ = try append(self, .{ .init_var = .{ .slot = slot, .value = a } });
    };
    const caller = self.scope;
    self.scope = f.scope;
    try compileStmt(self, decl.body, depth + 1);
    self.scope = caller;
    for (decl.ports, args, f.ports) |p, a, slot| if (p.direction != .input) {
        _ = try append(self, .{ .copy_out = .{ .target = a, .slot = slot } });
    };
    try self.subs.items[idx].ranges.append(self.arena, .{ .start = start, .end = position(self) });
}

// ---- static sensitivity and target checks (§6.1, §9.7.5, §9.7.1) ------------

/// Appends to `out`, once each, the slots `e` reads: §6.1 "a continuous
/// assignment is evaluated whenever an operand changes". They resolve at
/// compile time, like an event term, so a resumption cannot fail mid-dispatch.
// ponytail: an array element operand watches every element of its array;
// a per-array wake list if a big memory ever feeds one.
pub fn sensitivity(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal => {},
        .ident, .hier_ident => try watch(self, try self.slot(e), out),
        .index => {
            // An array element watches every element, since the one an index
            // names is known only when it is read; a vector select its vector.
            if (try self.indexedArray(e)) |arr| {
                const base = try self.slot(self.chainBase(e).base);
                for (0..arr.count) |i| try watch(self, base + @as(u32, @intCast(i)), out);
                var x = e;
                while (ex.tag(x) == .index) : (x = ex.lhs(x)) try sensitivity(self, ex.rhs(x), out);
            } else {
                try sensitivity(self, ex.lhs(e), out);
                try sensitivity(self, ex.rhs(e), out);
            }
        },
        .unary, .binary, .multi_concat, .ternary, .sys_call, .concat, .range, .indexed_range, .call => {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none) try sensitivity(self, c, out);
        },
        else => unreachable, // else: checkExpr admitted only the forms above
    }
}

/// §9.7.5's implicit event expression: every net and variable the statement
/// reads. An assignment target is written, not read, but its subscripts are
/// read. Requires `compileStmt` to have accepted the statement, so every
/// expression in it is type-checked.
fn readSlots(self: *Run, id: Ast.StmtId, out: *std.ArrayList(u32), depth: u16) Error!void {
    if (id == .none) return;
    if (depth == 256) return self.fail(self.file.stmtTok(id), "digital statements deeper than 256 AST levels are not implemented", .{});
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try readSlots(self, s, out, depth + 1),
        .if_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.then_s, out, depth + 1);
            try readSlots(self, s.else_s, out, depth + 1);
        },
        .while_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.body, out, depth + 1);
        },
        .for_stmt => |s| {
            try sensitivity(self, s.cond, out);
            for ([_]Ast.StmtId{ s.init, s.body, s.step }) |part| try readSlots(self, part, out, depth + 1);
        },
        .repeat_stmt => |s| {
            try sensitivity(self, s.count, out);
            try readSlots(self, s.body, out, depth + 1);
        },
        .case_stmt => |s| {
            try sensitivity(self, s.scrutinee, out);
            for (s.arms) |arm| {
                for (arm.labels) |label| try sensitivity(self, label, out);
                try readSlots(self, arm.body, out, depth + 1);
            }
        },
        .assign => |s| {
            if (s.value != .none) try sensitivity(self, s.value, out); // `deassign`/`release` read nothing
            try targetReads(self, s.target, out);
        },
        .sys_task => |s| for (s.args) |a| {
            if (a != .none and ex.tag(a) != .str_literal) try sensitivity(self, a, out);
        },
        // These read nothing. A nested `@` or `#` inside `@*` suspends on
        // its own terms; §9.7.5 takes the list from the reads either way.
        .empty, .event_trigger, .disable => {},
        .event_control => |s| try readSlots(self, s.body, out, depth + 1),
        else => unreachable, // else: compileStmt admitted only the forms above
    }
}

/// An element lvalue reads its subscript; `sensitivity` on the whole
/// `.index` would also add the array's own elements.
fn targetReads(self: *Run, target: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
    const ex = &self.file.exprs;
    if (ex.tag(target) == .concat) {
        for (ex.args(target)) |arg| try targetReads(self, arg, out);
        return;
    }
    var x = target;
    while (ex.tag(x) == .index) : (x = ex.lhs(x)) try sensitivity(self, ex.rhs(x), out);
}

fn watch(self: *Run, at: u32, out: *std.ArrayList(u32)) Error!void {
    for (out.items) |seen| if (seen == at) return;
    try out.append(self.arena, at);
}

/// §6.2.2/§6.1: a net is driven by a continuous assignment and a variable by
/// a procedural one; neither accepts the other's form.
fn checkTarget(self: *Run, e: Ast.ExprId) Error!void {
    const ex = &self.file.exprs;
    // §9.2 "a concatenation or nested concatenation of any of the above".
    if (ex.tag(e) == .concat) {
        for (ex.args(e)) |x| {
            try checkTarget(self, x);
            if ((try exec.targetType(self, x)).real) return self.exprFail(x, "§4.8: a real cannot be a concatenation operand");
        }
        return;
    }
    if (try self.indexedArray(e) != null) {
        var x = e;
        while (ex.tag(x) == .index) : (x = ex.lhs(x)) {
            try checkExpr(self, ex.rhs(x));
            if (typeOf(self, ex.rhs(x)).width > 64) return self.exprFail(ex.rhs(x), "array indices wider than 64 bits are not implemented");
        }
        return;
    }
    // §5.2.1 a bit- or part-select of a variable writes those bits only;
    // typing it as a read folds its bounds and checks its index.
    if (ex.tag(e) == .index) try checkExpr(self, e);
    const at = try self.baseSlot(e);
    if (self.net_of.contains(at))
        return self.exprFail(e, "a net is driven by a continuous assignment; there is no procedural assignment to a net");
    if (self.params.contains(at)) return self.exprFail(e, "§12.2: a parameter is a constant; it cannot be assigned");
    if (self.events.contains(at)) return self.exprFail(e, "§9.7.3: a named event holds no data; it cannot be assigned");
}

/// Does intra-assignment control `s` leave its `.sample` only parking the
/// value, the wait compiled after it: a `repeat` count, or an event control
/// on a nonblocking assignment (§9.7.7)?
pub fn parksOnly(s: @FieldType(Ast.Stmt, "assign")) bool {
    return !s.timing_is_delay and (s.nonblocking or s.timing_repeat != .none);
}

/// §10.2.3: an automatic task's variables "shall not be assigned values
/// using nonblocking assignments or procedural continuous assignments" and
/// "shall not be traced with system tasks such as $monitor". `e` is the
/// target, or a traced argument.
fn notAutomatic(self: *Run, e: Ast.ExprId, comptime what: []const u8) Error!void {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .concat => for (ex.args(e)) |x| try notAutomatic(self, x, what),
        .ident, .hier_ident, .index => if (self.auto_slots.contains(try self.slot(self.chainBase(e).base)))
            return self.exprFail(e, "§10.2.3: " ++ what ++ " cannot name a variable of an automatic task or function"),
        else => {}, // else: an expression names no storage to outlive the activation, its operands are read now
    }
}

/// §9.7.1 a delay is a "delay_value", which A.8.3 makes
/// `unsigned_number | real_number | ...`, so `#0.5` is legal. A real delay
/// is rounded to the module's precision at run time (`Scale.realDelay`), not
/// truncated to its unit, so a sub-unit delay keeps its meaning.
fn checkDelay(self: *Run, e: Ast.ExprId) Error!void {
    try checkExpr(self, e);
    if (typeOf(self, e).width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
}

/// Event terms resolve to watched slots at compile time, so a resumption
/// never has to fail in the middle of a dispatch.
fn checkEvent(self: *Run, e: Ast.ExprId) Error!void {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .event_or => {
            try checkEvent(self, ex.lhs(e));
            try checkEvent(self, ex.rhs(e));
        },
        // §4.8.1: real variables are prohibited in "Edge descriptors
        // (posedge, negedge) applied to real variables".
        .event_posedge, .event_negedge => {
            const x = ex.lhs(e);
            if (ex.tag(x) != .ident and ex.tag(x) != .hier_ident) try exprTerm(self, x);
            if (self.reals.contains(try self.termSlot(x)))
                return self.exprFail(e, "§4.8.1: posedge and negedge do not apply to a real variable");
        },
        .hier_ident => _ = try self.scalarSlot(e),
        .ident => if (self.events.get(try self.scalarSlot(e))) |decl| if (ex.mainTok(e) < decl)
            return self.exprFail(e, "§9.7.3: a named event is declared before it is used"),
        // VAMS §7.3.5 an analog event in a discrete event control: the
        // mixed-signal kernel monitors it and delivers an A2D event.
        .event_function => try self.registerMonitor(e),
        // VAMS §9.22.5 `driver_update signal`.
        .event_driver_update => try driver.checkUpdate(self, e),
        else => try exprTerm(self, e), // else: every other term is an expression (A.6.5 `event_expression ::= expression`)
    }
}

/// IEEE 1364-2005 §9.7.2: "An implicit event shall be detected on any change
/// in the value of the expression", and not on an operand change that leaves
/// it alone. A hidden slot follows `e`, kept equal to it by an out-of-line
/// process of its own started at time 0, and the term watches that slot.
fn exprTerm(self: *Run, e: Ast.ExprId) Error!void {
    try checkExpr(self, e);
    const entry = try self.term_slots.getOrPut(self.arena, .{ .scope = self.scope, .e = e });
    if (entry.found_existing) return;
    const g = self.growing.?;
    const ty = typeOf(self, e);
    const at: u32 = @intCast(g.items.len);
    entry.value_ptr.* = at;
    try g.append(self.arena, try filled(self.arena, ty.width, ty.signed, if (ty.real) .zero else .x));
    if (ty.real) try self.reals.put(self.arena, at, {});
    self.values = g.items;
    var watched: std.ArrayList(u32) = .empty;
    try sensitivity(self, e, &watched);
    const skip = try append(self, .{ .jump = 0 });
    const start = position(self);
    _ = try append(self, .{ .init_var = .{ .slot = at, .value = e } });
    _ = try append(self, .{ .wait_slots = watched.items });
    _ = try append(self, .{ .jump = start });
    self.code.items[skip].jump = position(self);
    _ = try exec.enqueue(self, .{ .run_process = start }, null, false);
}

// ---- tests ------------------------------------------------------------------

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

test "§3.6 a string operand is packed ASCII, right-justified and truncated on the left" {
    try expectRun(
        \\module m;
        \\reg [31:0] w; reg [15:0] n; reg [7:0] e;
        \\initial begin
        \\  w = "AZ"; n = "ABC"; e = "";
        \\  $display("%h %h %h %b", w, n, e, "AB" == 16'h4142);
        \\end
        \\endmodule
    , "0000415a 4243 00 1\n");
}

test "§17.1.1.6 %m names the instance path and the named blocks around it" {
    try expectRun(
        \\module leaf; initial begin : outer begin : inner $display("%m %l %s%c", "", 8'h21); end end endmodule
        \\module m; leaf u(); initial $display("%M"); endmodule
    , "m\nm.u.outer.inner work.leaf !\n");
}

test "§12.7 a named block's local shadows the module's, and each instance has its own" {
    try expectRun(
        \\module c; integer v; initial begin v = 1; begin : b integer v; v = 5; v = v + 1; $display("%m %0d", v); end $display("%0d", v); end endmodule
        \\module m; c u(); c w(); endmodule
    , "m.u.b 6\n1\nm.w.b 6\n1\n");
}

test "§5.3 a min:typ:max expression reads its typical member everywhere" {
    try expectRun("module m; initial $display(\"%0d\", (1:2:3) * 10 + (3:2:1)); endmodule", "22\n");
}

test "unsupported source is rejected before any process side effect" {
    try expectRejected("module m; initial $display(\"before\"); initial forever ; endmodule", "error");
    try expectRejected("module m; wire [1:0] a, b; tran(a,b); initial $display(\"before\"); endmodule", "a scalar net or a bit-select of a vector net");
    try expectRejected("module m; initial $display(\"%b\",2147483648); endmodule", "unsized constants");
    try expectRejected("module m; reg c; always begin c = 1; end endmodule", "without suspending");
    try expectRejected("module m; reg c; initial @(c[0]) c = 1; endmodule", "no bits to select");
    // §5.10 "events do not hold any data", so neither direction of the
    // event/variable confusion compiles.
    try expectRejected("module m; event e; initial $display(\"%b\", e); endmodule", "holds no data");
    try expectRejected("module m; reg c; initial -> c; endmodule", "triggers a named event");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=(a+1)+$bogus(1); end endmodule", "expression form");
    try expectRejected("module m; wire [3:0] w; initial w[0]=1; endmodule", "no procedural assignment to a net");
    // Past Table 9-22 and §17.1.1's %c %s %m %l %t %v, a conversion such as
    // the unformatted `%u` is refused, and the refusal names the table.
    try expectRejected("module m; initial $display(\"%u\",1); endmodule", "Table 9-22");
    // §17.7: a real conversion needs a real, and `$realtime` is the only one.
    // IEEE 1364-2005 §5.1.1 Table 5-3: a real takes no bitwise, modulus or
    // case operator.
    try expectRejected("module m; real a; integer b; initial b = a % 2; endmodule", "does not take a real operand");
    try expectRejected("module m; real a; reg [3:0] b; initial b = a[1]; endmodule", "a real has no bits");
    try expectRejected("module m; reg a; initial a=1; integer a; endmodule", "duplicate digital");
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

test "control flow validates unselected bodies and every case label" {
    try expectRejected("module m; initial begin $display(\"before\"); if(0) $bogustask(\"BAD\"); end endmodule", "system task");
    try expectRejected("module m; initial begin $display(\"before\"); case(1) 1:; $bogus(2):; endcase end endmodule", "expression form");
    try expectRejected("module m; initial begin $display(\"before\"); while(0) @(a); end endmodule", "undeclared digital variable");
    try expectRejected("module m; initial case(1) default:; default:; endcase endmodule", "multiple default");
    try expectRejected("module m; initial case(1) endcase endmodule", "at least one item");
    try expectRejected("module m; initial repeat(65'd1); endmodule", "wider than 64");
    try expectRejected("module m; initial repeat(-1); endmodule", "negative repeat counts");
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
    try expectRejected("module m; initial $display(\"%b\",$signed(1.0)); endmodule", "exactly one integral argument");
}
