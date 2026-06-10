//! MIR, the SSA IR lowering writes and every later stage reads: §4.2
//! operators, §4.3 math, §5.8/§5.9 control flow as blocks, phis and calls.
//! Instructions, values and blocks are SoA columns addressed by typed
//! `enum(u32)` handles; tables grow by append, so equal input gives equal
//! indices. A Value index renumbers when the source changes, so it must never
//! reach an emitted name or a content hash (naming.zig canonicalizes).

const std = @import("std");
const Ast = @import("frontend").Ast;
const assert = std.debug.assert;
/// The per-opcode fact table (class, type, domain, …).
pub const opcode = @import("opcode.zig");
/// What a `call` calls, and the per-callee fact table.
pub const callee = @import("callee.zig");
/// What a `call` calls (`callee.Callee`).
pub const Callee = callee.Callee;

const Mir = @This();

/// Handle to an instruction row; `.none` ends a block's `next` chain.
pub const Inst = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle to an SSA value. Indices below `first_dynamic` are shared constants
/// with no `defs` row.
pub const Value = enum(u32) {
    // Reserved sentinels 0..9 (common constants); dynamic values from 10+.
    undef = 0,
    f_zero,
    f_one,
    f_neg_one,
    f_two,
    f_ten,
    f_inf,
    zero,
    one,
    neg_one,
    _,

    /// First dynamic Value index. Values below this are the sentinels above and
    /// have no row in the `defs` side table.
    pub const first_dynamic: u32 = 10;
};
/// Handle to a basic block; block 0 is the entry.
pub const Block = enum(u32) { entry = 0, _ };
/// Interned string handle (call names, §4.4 access names, ch9 arguments). The
/// AST's type, but it indexes this Mir's `strings` table, not the AST's.
/// `.none` is the absent sentinel.
pub const StrId = Ast.StrId;

/// Opcode set: §4.2 arithmetic, relational, logical, bitwise and shift
/// operators, §4.3 math, casts. Every opcode has a row of facts in
/// `opcode.zig`. Naming: a leading `f` is the real-valued form, a leading `i` the
/// integer form. Math functions (§4.3) are always real-valued and carry the
/// bare LRM name.
pub const Opcode = enum(u8) {
    // --- arithmetic §4.2.4 (+ unary §4.2.3, modulus §4.2.4) ---
    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fneg,
    iadd,
    isub,
    imul,
    idiv,
    imod,
    ineg,
    // --- relational §4.2.5 / equality §4.2.7 (yield integer 0/1) ---
    flt,
    fgt,
    fle,
    fge,
    feq,
    fne,
    ilt,
    igt,
    ile,
    ige,
    ieq,
    ine,
    // --- logical §4.2.8 (integer 0/1 result) ---
    logand,
    logor,
    lognot,
    // --- bitwise §4.2.9 (integer only; reduction §4.2.10 is digital-only) ---
    bitand,
    bitor,
    bitxor,
    bitxnor,
    bitnot,
    // --- shifts §4.2.11 (logical << >> only; <<< >>> are illegal in analog) ---
    shl,
    shr,
    // --- standard math, LRM Table 4-14 §4.3.1 ---
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log10,
    pow,
    hypot,
    floor,
    ceil,
    fabs,
    fmin,
    fmax, // real forms
    iabs,
    imin,
    imax, // integer forms (§4.3.1: int operands ⇒ int result)
    /// §4.2.1.3 `**` over two integers: integer, not §4.3.1's real `pow`.
    /// IEEE 1364-2005 §5.1.5 Table 5-6 at §3.2's 32-bit width; `Lower.ipow32`
    /// is the definition.
    ipow,
    // --- trigonometric + hyperbolic, LRM Table 4-15 §4.3.2 ---
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    // --- casts §4.2.1.1 (real→integer, rounds) / §4.2.1.2 (integer→real) ---
    fi_cast,
    if_cast,
    /// Optimization fence (engine-internal): stops codegen from folding or
    /// reassociating across it. Unary, value-preserving.
    opt_barrier,
    /// Derivative stop (no LRM basis; VerA's `vera_nodiff` attribute, §2.9):
    /// the operand's value with every derivative lane zero. So its `deps` is
    /// empty although the value still varies with x (`Analysis.xDep`).
    dstop,
    /// Committed-value latch (engine-internal): reads the Instance field
    /// `pb__<k>`, the operand's value at the last accepted solve; gradient
    /// zero. Serves §5.6.1.2 path-integrated reactive terms `A*ddt(B)`:
    /// q = path_acc + A·(B - path_prev(B)), so the charge increment is A·ΔB
    /// (the capacitance form) and dA reaches the Jacobian only times ΔB,
    /// which is 0 at every committed point (AC sees exactly A·∂B/∂x).
    path_prev,
    /// Committed accumulator latch: reads `pq__<k>`, the sum of the operand's
    /// values over all accepted solves; gradient zero. Carries the charge base
    /// Σ A·ΔB for `path_prev`. The base is fixed across one Newton attempt, so
    /// the reactive residual is one smooth function per attempt and its AD
    /// Jacobian is exact.
    path_acc,
    // --- value-form conditional §4.2.12 (`?:` that needs no CFG split) ---
    select,
    // --- §3.2.2 memory-backed arrays (`Lowered.mem_arrays`) ---
    /// A fresh version of array `a` (an index into `Lowered.mem_arrays`, not a
    /// Value): every element zero, or for a §5.10 held array the values the
    /// last accepted evaluation left in its `Instance` field.
    anew,
    /// Element `b` of array version `a`; real / integer by the array's type.
    /// `b` is the flat element index, and any index outside `0..len` reads
    /// the element type's zero (§3.2.2 names no element there; lowering's
    /// `runtimeArrayIndex` encodes an invalid subscript as -1).
    fload,
    iload,
    /// Array version `a` with element `b` set to `c`: a new version. An index
    /// outside `0..len` writes nothing. Every version of one array shares one
    /// storage, so a version is dead once a store has been made from it; no
    /// pass may make one live again (if-conversion keeps any arm that stores).
    store,
    // --- control §5.8/§5.9 ---
    phi,
    branch,
    jump,
    call,
};

/// Operand shape of an opcode; selects the `InstData` variant.
pub const OpClass = enum(u8) { unary, binary, ternary, phi, branch, jump, call, anew, load, store };

/// Operand shape of an opcode. Drives `instData` decoding.
pub fn opClass(op: Opcode) OpClass {
    return opcode.get(op).class;
}

/// Returns whether `op` yields a §3.2 integer rather than a real.
/// Relational, equality and logical operators yield integer 0/1 (§4.2.5, §4.2.8).
pub fn opIsInteger(op: Opcode) bool {
    return opcode.get(op).int;
}

/// One instruction row. Fixed width; operands are Value/Block/StrId handles
/// packed into a/b/c; `result` is the produced Value; `next` links within a block.
///
/// Operand encoding per class (see `instData` for the decoded view):
///   unary   a = operand
///   binary  a = lhs, b = rhs
///   ternary a = cond, b = then value, c = else value        (§4.2.12)
///   phi     b = extra start, c = pair count (2 u32 per pair: block, value)
///   branch  a = cond, b = then Block, c = else Block        (§5.8)
///   jump    a = target Block                                (§5.9)
///   call    a = Callee, b = extra start (the raw name's StrId, then the
///           args), c = arg count
///   anew    a = array id (`Lowered.mem_arrays` index)                (§3.2.2)
///   load    a = array version, b = flat index
///   store   a = array version, b = flat index, c = value
pub const InstRow = struct {
    op: Opcode,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    result: Value = .undef,
    next: Inst = .none,
    /// The block whose `next` chain links this row. Never set by a caller:
    /// `addInst` stamps it and every relink restamps it.
    block: Block = .entry,
    /// Index of the token this instruction came from, for diagnostics, or
    /// `no_tok`. Never set by a caller: `addInst` stamps it from `cur_tok`.
    /// A cold column; `instData` does not read it.
    tok: u32 = no_tok,
};

/// "This instruction has no AST origin", such as a constant the SSA builder
/// materialised. Not 0, because token 0 is the first real token of the file.
pub const no_tok: u32 = std.math.maxInt(u32);

/// First and last instruction of a block's `next` chain; `.none` when empty.
pub const BlockRow = struct { first: Inst = .none, last: Inst = .none };

/// How a Value came to be.
pub const DefKind = enum(u8) {
    undef,
    float_const, // §4.2 constant expression, real
    int_const, // §4.2 constant expression, integer
    str_const, // §2.7 string literal (ch9 format args, §4.4 names)
    param_ref, // §3.4 parameter: index into Lowered.params
    block_param, // §4.4 probe: index into the unknown vector (Lowered.nodes)
    inst_result, // result of an instruction
};

/// Decoded definition of a Value (see `valueDef`). Built on read, never stored.
pub const Def = union(DefKind) {
    undef,
    float_const: f64,
    int_const: i64,
    str_const: []const u8,
    param_ref: u32,
    block_param: u32,
    inst_result: Inst,
};

/// SoA row of the value-definition side table. `payload` is kind-dependent:
/// float bits / int bits / StrId / param index / unknown index / Inst.
pub const ValueRow = struct { kind: DefKind, payload: u64 };

/// Decoded instruction view. Built on demand; never stored (see InstRow).
pub const InstData = union(OpClass) {
    unary: struct { op: Opcode, operand: Value },
    binary: struct { op: Opcode, lhs: Value, rhs: Value },
    ternary: struct { cond: Value, then_val: Value, else_val: Value },
    phi: struct { start: u32, count: u32 },
    branch: struct { cond: Value, then_block: Block, else_block: Block },
    jump: struct { target: Block },
    /// `name` is the spelling the call was emitted with: `@tagName(callee)`,
    /// except for `.systf`, whose name only this carries.
    call: struct { callee: Callee, name: []const u8, args: []const Value },
    anew: struct { array: u32 },
    load: struct { op: Opcode, arr: Value, index: Value },
    store: struct { arr: Value, index: Value, value: Value },
};

/// One phi operand: the value flowing in from predecessor `block`.
pub const PhiPair = struct { block: Block, value: Value };

/// The lowered module's name.
name: []const u8 = "",
/// IEEE 1364 §19.1 (via §10.1): the module was declared inside a
/// `` `celldefine ``/`` `endcelldefine `` pair. A tag only; nothing branches on
/// it. It carries the fact past the preprocessor for tools that ask. For any
/// other module, ask `Preprocessor.CellRegion.inForce`.
is_cell: bool = false,
/// Provenance cursor: the builder sets it to the token of the AST node being
/// lowered, and `addInst` stamps it onto every row. A cursor rather than an
/// `emit` parameter because lowering emits from hundreds of sites but visits
/// AST nodes from a handful.
cur_tok: u32 = no_tok,
/// Instruction rows, indexed by `Inst`.
insts: std.MultiArrayList(InstRow) = .empty,
/// Block rows, indexed by `Block`.
blocks: std.MultiArrayList(BlockRow) = .empty,
/// Definition of every dynamic Value; index = @intFromEnum(v) - first_dynamic.
defs: std.MultiArrayList(ValueRow) = .empty,
/// Shared variable-length payload pool (call args, phi operands).
extra: std.ArrayList(u32) = .empty,
/// String table (the AST's interner type). Slices are not copied: they must
/// outlive the Mir.
strings: Ast.StringInterner = .empty,
/// Constant dedup, keyed by exact bits so -0.0 / 0.0 stay distinct and NaN
/// payloads survive. Lookup only: iteration order is not deterministic.
fconst_map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
/// Integer constant dedup. Lookup only.
iconst_map: std.AutoHashMapUnmanaged(i64, Value) = .empty,
/// Trivial-phi aliases (ssa.zig `tryRemoveTrivialPhi`). Union-find parent array
/// parallel to `defs` (index = value - first_dynamic); an entry equal to its own
/// Value means "no alias". Only collapsed phis point elsewhere, so codegen never
/// emits a decl for them.
alias: std.ArrayList(Value) = .empty,

/// Frees every table. Keeps `name`, which the Mir does not own.
pub fn deinit(self: *Mir, gpa: std.mem.Allocator) void {
    self.insts.deinit(gpa);
    self.blocks.deinit(gpa);
    self.defs.deinit(gpa);
    self.extra.deinit(gpa);
    self.strings.deinit(gpa);
    self.fconst_map.deinit(gpa);
    self.iconst_map.deinit(gpa);
    self.alias.deinit(gpa);
    self.* = .{ .name = self.name };
}

// ---------------------------------------------------------------- values ----

/// Registers a new dynamic Value. Prefer the typed helpers below.
fn addValue(self: *Mir, gpa: std.mem.Allocator, kind: DefKind, payload: u64) !Value {
    const i = self.defs.len + Value.first_dynamic;
    assert(i < std.math.maxInt(u32));
    const v: Value = @enumFromInt(@as(u32, @intCast(i)));
    try self.defs.append(gpa, .{ .kind = kind, .payload = payload });
    try self.alias.append(gpa, v); // self-parent = no alias
    return v;
}

/// Returns the §4.2 real constant `x`, deduped. Common literals map onto the sentinels so
/// two spellings of `1.0` are the same Value in every compilation.
pub fn addFloatConst(self: *Mir, gpa: std.mem.Allocator, x: f64) !Value {
    const bits: u64 = @bitCast(x);
    switch (bits) {
        @as(u64, @bitCast(@as(f64, 0.0))) => return .f_zero,
        @as(u64, @bitCast(@as(f64, 1.0))) => return .f_one,
        @as(u64, @bitCast(@as(f64, -1.0))) => return .f_neg_one,
        @as(u64, @bitCast(@as(f64, 2.0))) => return .f_two,
        @as(u64, @bitCast(@as(f64, 10.0))) => return .f_ten,
        @as(u64, @bitCast(std.math.inf(f64))) => return .f_inf,
        else => {},
    }
    const gop = try self.fconst_map.getOrPut(gpa, bits);
    if (!gop.found_existing) gop.value_ptr.* = try self.addValue(gpa, .float_const, bits);
    return gop.value_ptr.*;
}

/// Returns the §4.2 integer constant `x`, deduped; 0, 1 and -1 are sentinels.
pub fn addIntConst(self: *Mir, gpa: std.mem.Allocator, x: i64) !Value {
    switch (x) {
        0 => return .zero,
        1 => return .one,
        -1 => return .neg_one,
        else => {},
    }
    const gop = try self.iconst_map.getOrPut(gpa, x);
    if (!gop.found_existing)
        gop.value_ptr.* = try self.addValue(gpa, .int_const, @bitCast(x));
    return gop.value_ptr.*;
}

/// Returns a §2.7 string literal Value. `bytes` must outlive the Mir. The string itself is deduped by the interner; the
/// Value wrapper is not (a handful per module, and identical strings are
/// behaviorally interchangeable).
pub fn addStrConst(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !Value {
    const s = try self.internString(gpa, bytes);
    return self.addValue(gpa, .str_const, @intFromEnum(s));
}

/// Returns a §3.4 parameter reference. `param` indexes `Lowered.params`.
pub fn addParamRef(self: *Mir, gpa: std.mem.Allocator, param: u32) !Value {
    return self.addValue(gpa, .param_ref, param);
}

/// Returns a §4.4 signal-access probe. `unknown` indexes the solver unknown vector
/// (Lowered.nodes → the generated `U` enum, i.e. codegen's `x[unknown]`).
/// V(a,b) lowers to fsub of two probes; a branch-current unknown gets its own
/// `nodes` row.
pub fn addBlockParam(self: *Mir, gpa: std.mem.Allocator, unknown: u32) !Value {
    return self.addValue(gpa, .block_param, unknown);
}

/// Interns a name into this Mir's table. `bytes` is borrowed and must outlive
/// the Mir. Idempotent, so the same callee name is one
/// StrId no matter how many call sites use it.
pub fn internString(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !StrId {
    return self.strings.intern(gpa, bytes);
}

/// Returns the decoded definition of `value`. A `.str_const` slice borrows
/// the string table.
pub fn valueDef(self: *const Mir, value: Value) Def {
    switch (value) {
        .undef => return .undef,
        .f_zero => return .{ .float_const = 0.0 },
        .f_one => return .{ .float_const = 1.0 },
        .f_neg_one => return .{ .float_const = -1.0 },
        .f_two => return .{ .float_const = 2.0 },
        .f_ten => return .{ .float_const = 10.0 },
        .f_inf => return .{ .float_const = std.math.inf(f64) },
        .zero => return .{ .int_const = 0 },
        .one => return .{ .int_const = 1 },
        .neg_one => return .{ .int_const = -1 },
        _ => {},
    }
    const row = self.defs.get(@intFromEnum(value) - Value.first_dynamic);
    return switch (row.kind) {
        .undef => .undef,
        .float_const => .{ .float_const = @bitCast(row.payload) },
        .int_const => .{ .int_const = @bitCast(row.payload) },
        .str_const => .{ .str_const = self.strings.get(@enumFromInt(@as(u32, @truncate(row.payload)))) },
        .param_ref => .{ .param_ref = @truncate(row.payload) },
        .block_param => .{ .block_param = @truncate(row.payload) },
        .inst_result => .{ .inst_result = @enumFromInt(@as(u32, @truncate(row.payload))) },
    };
}

/// Returns the kind of `value`, read from the `kind` column without decoding
/// the payload.
pub fn valueKind(self: *const Mir, value: Value) DefKind {
    return switch (value) {
        .undef => .undef,
        .f_zero, .f_one, .f_neg_one, .f_two, .f_ten, .f_inf => .float_const,
        .zero, .one, .neg_one => .int_const,
        _ => self.defs.items(.kind)[@intFromEnum(value) - Value.first_dynamic],
    };
}

// --------------------------------------------------------------- aliases ----

/// Records `from` ≡ `to` (ssa.zig trivial-phi removal); overwrites.
/// `from` must be a dynamic Value (a phi result); `to` may be a sentinel.
/// Asserts that `from != to`.
pub fn setAlias(self: *Mir, from: Value, to: Value) void {
    assert(from != to); // a self-alias would make resolveAlias non-terminating
    assert(@intFromEnum(from) >= Value.first_dynamic);
    self.alias.items[@intFromEnum(from) - Value.first_dynamic] = to;
}

/// Returns whether `value` was collapsed onto another (codegen skips its decl).
pub fn hasAlias(self: *const Mir, value: Value) bool {
    const i = @intFromEnum(value);
    if (i < Value.first_dynamic) return false;
    return self.alias.items[i - Value.first_dynamic] != value;
}

/// Returns the Value `value` aliases to at the end of its chain. Union-find
/// with path compression: amortized near O(1).
/// Takes `*const` but writes `alias` (compression), so it is not safe to call
/// concurrently on one Mir. Asserts the chain has no cycle.
pub fn resolveAlias(self: *const Mir, value: Value) Value {
    const fd = Value.first_dynamic;
    if (@intFromEnum(value) < fd) return value;
    const parent = self.alias.items;

    var root = value;
    var hops: usize = 0;
    while (@intFromEnum(root) >= fd) {
        const next = parent[@intFromEnum(root) - fd];
        if (next == root) break;
        root = next;
        hops += 1;
        assert(hops <= parent.len); // cycle ⇒ SSA bug
    }

    var v = value;
    while (v != root) {
        const next = parent[@intFromEnum(v) - fd];
        parent[@intFromEnum(v) - fd] = root;
        v = next;
    }
    return root;
}

// ---------------------------------------------------------------- blocks ----

/// Appends an empty block.
pub fn addBlock(self: *Mir, gpa: std.mem.Allocator) !Block {
    const i = self.blocks.len;
    assert(i < std.math.maxInt(u32));
    try self.blocks.append(gpa, .{});
    return @enumFromInt(@as(u32, @intCast(i)));
}

/// Returns the number of blocks.
pub fn blockCount(self: *const Mir) u32 {
    return @intCast(self.blocks.len);
}

/// Iterator over one block's instruction chain.
pub const InstIterator = struct {
    /// Borrowed `next` column. Adding instructions invalidates it: iterate only
    /// after the block is built (codegen/proof are read-only passes).
    next_col: []const Inst,
    cur: Inst,

    /// Returns the next instruction, or null at the end of the chain.
    pub fn next(it: *InstIterator) ?Inst {
        if (it.cur == .none) return null;
        const out = it.cur;
        it.cur = it.next_col[@intFromEnum(out)];
        return out;
    }
};

/// Instructions of `block`, in emission order (intrusive `next` chain).
pub fn blockInsts(self: *const Mir, block: Block) InstIterator {
    return .{
        .next_col = self.insts.items(.next),
        .cur = self.blocks.items(.first)[@intFromEnum(block)],
    };
}

/// The last instruction linked into `block`, or `.none` when it is empty.
pub fn blockLast(self: *const Mir, block: Block) Inst {
    return self.blocks.items(.last)[@intFromEnum(block)];
}

/// Unlinks every instruction of `from` after `after` (all of them when `after`
/// is `.none`) and relink them, in order, in front of `to`'s terminator. For a
/// value computed after a join that one incoming edge has to carry: the
/// operands must already be available at the end of `to`. True when there is
/// nothing to move; moves nothing and returns false when `to` has no
/// terminator yet or is `from`.
pub fn moveTailBefore(self: *Mir, from: Block, after: Inst, to: Block) bool {
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const head = if (after == .none) first[@intFromEnum(from)] else next[@intFromEnum(after)];
    if (head == .none) return true;
    if (from == to) return false;
    var prev: Inst = .none;
    var term = first[@intFromEnum(to)];
    while (term != .none) : (term = next[@intFromEnum(term)]) {
        switch (opClass(self.instOp(term))) {
            .branch, .jump => break,
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => prev = term,
        }
    } else return false;
    const tail = last[@intFromEnum(from)];
    var moved = head;
    while (moved != .none) : (moved = next[@intFromEnum(moved)]) self.insts.items(.block)[@intFromEnum(moved)] = to;
    if (after == .none) first[@intFromEnum(from)] = .none else next[@intFromEnum(after)] = .none;
    last[@intFromEnum(from)] = after;
    next[@intFromEnum(tail)] = term;
    if (prev == .none) first[@intFromEnum(to)] = head else next[@intFromEnum(prev)] = head;
    return true;
}

/// Removes `inst` from `block`'s chain; the rows after it stay linked. The row
/// is orphaned, not reused.
pub fn unlink(self: *Mir, block: Block, inst: Inst) void {
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const b = @intFromEnum(block);
    var prev: Inst = .none;
    var cur = first[b];
    while (cur != inst) : (cur = next[@intFromEnum(cur)]) prev = cur;
    const after = next[@intFromEnum(inst)];
    if (prev == .none) first[b] = after else next[@intFromEnum(prev)] = after;
    if (last[b] == inst) last[b] = prev;
    next[@intFromEnum(inst)] = .none;
}

/// Relinks every row of `from`, in order, at the end of `to`; `from` is left
/// empty.
pub fn splice(self: *Mir, to: Block, from: Block) void {
    assert(to != from);
    const next = self.insts.items(.next);
    const first = self.blocks.items(.first);
    const last = self.blocks.items(.last);
    const head = first[@intFromEnum(from)];
    if (head == .none) return;
    var moved = head;
    while (moved != .none) : (moved = next[@intFromEnum(moved)]) self.insts.items(.block)[@intFromEnum(moved)] = to;
    const tail = last[@intFromEnum(to)];
    if (tail == .none) first[@intFromEnum(to)] = head else next[@intFromEnum(tail)] = head;
    last[@intFromEnum(to)] = last[@intFromEnum(from)];
    first[@intFromEnum(from)] = .none;
    last[@intFromEnum(from)] = .none;
}

// ---------------------------------------------------------- instructions ----

/// Appends `row` to the end of `block` and links it in. Caller sets row.result
/// (use `emit` to get a fresh result Value automatically).
fn addInst(self: *Mir, gpa: std.mem.Allocator, block: Block, row: InstRow) !Inst {
    const i = self.insts.len;
    assert(i < std.math.maxInt(u32) - 1); // maxInt is Inst.none
    var stamped = row;
    stamped.tok = self.cur_tok; // provenance: see InstRow.tok and cur_tok
    stamped.block = block;
    try self.insts.append(gpa, stamped);
    const inst: Inst = @enumFromInt(@as(u32, @intCast(i)));

    const b = @intFromEnum(block);
    const last = self.blocks.items(.last)[b];
    if (last == .none) {
        self.blocks.items(.first)[b] = inst;
    } else {
        self.insts.items(.next)[@intFromEnum(last)] = inst;
    }
    self.blocks.items(.last)[b] = inst;
    return inst;
}

/// Appends a value-producing instruction to `block` and returns its result.
/// Asserts that `ops` matches `op`'s class (see `InstRow`'s encoding table);
/// phi, branch, jump, call and anew have their own builders.
pub fn emit(self: *Mir, gpa: std.mem.Allocator, block: Block, op: Opcode, ops: []const Value) !Value {
    assert(ops.len >= 1 and ops.len <= 3);
    assert(switch (opClass(op)) {
        .unary => ops.len == 1,
        .binary => ops.len == 2,
        .ternary, .store => ops.len == 3,
        .load => ops.len == 2,
        .phi, .branch, .jump, .call, .anew => false, // dedicated builders
    });
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = op,
        .a = @intFromEnum(ops[0]),
        .b = if (ops.len > 1) @intFromEnum(ops[1]) else 0,
        .c = if (ops.len > 2) @intFromEnum(ops[2]) else 0,
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// Returns a fresh version of §3.2.2 memory-backed array `array` (see `Opcode.anew`).
pub fn emitAnew(self: *Mir, gpa: std.mem.Allocator, block: Block, array: u32) !Value {
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{ .op = .anew, .a = array, .result = result });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// Appends a §5.8 two-way branch, the block's terminator.
pub fn emitBranch(self: *Mir, gpa: std.mem.Allocator, block: Block, cond: Value, then_block: Block, else_block: Block) !Inst {
    return self.addInst(gpa, block, .{
        .op = .branch,
        .a = @intFromEnum(cond),
        .b = @intFromEnum(then_block),
        .c = @intFromEnum(else_block),
    });
}

/// Appends a §5.9 unconditional jump, the block's terminator.
pub fn emitJump(self: *Mir, gpa: std.mem.Allocator, block: Block, target: Block) !Inst {
    return self.addInst(gpa, block, .{ .op = .jump, .a = @intFromEnum(target) });
}

/// Appends a call by name (§4.3 math, §4.5 analog operator, §4.7 function,
/// ch9 system function) and returns its result. The one place a name becomes
/// a `Callee`; the raw name is kept for `.systf`.
pub fn emitCall(self: *Mir, gpa: std.mem.Allocator, block: Block, name: StrId, args: []const Value) !Value {
    const start = try self.addExtra(gpa, &.{@intFromEnum(name)});
    _ = try self.addExtra(gpa, @ptrCast(args));
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = .call,
        .a = @intFromEnum(Callee.fromName(self.strings.get(name))),
        .b = start,
        .c = @intCast(args.len),
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// Appends a phi and returns its result. `pairs` may be empty for an
/// incomplete phi (Braun et al.); fill it later with `setPhiPairs`.
pub fn emitPhi(self: *Mir, gpa: std.mem.Allocator, block: Block, pairs: []const PhiPair) !Value {
    const start = try self.addExtraPairs(gpa, pairs);
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = .phi,
        .b = start,
        .c = @intCast(pairs.len),
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// Replaces a phi's operand list (`sealBlock` fills incomplete phis).
/// Asserts that `inst` is a phi. Invalidates slices previously returned by
/// `instData`.
pub fn setPhiPairs(self: *Mir, gpa: std.mem.Allocator, inst: Inst, pairs: []const PhiPair) !void {
    // ponytail: appends a fresh region and abandons the old one, a few dead
    // u32s per filled phi. Compact the pool only if `extra` shows in a profile.
    assert(self.insts.items(.op)[@intFromEnum(inst)] == .phi);
    const start = try self.addExtraPairs(gpa, pairs);
    self.insts.items(.b)[@intFromEnum(inst)] = start;
    self.insts.items(.c)[@intFromEnum(inst)] = @intCast(pairs.len);
}

/// Returns every column of `inst`, the cold `tok` and `next` included; a hot
/// walk decodes through `instData` instead.
pub fn instRow(self: *const Mir, inst: Inst) InstRow {
    return self.insts.get(@intFromEnum(inst));
}

/// Returns the token `inst` was lowered from (the finiteness diagnostics'
/// location), or `no_tok` when it has no AST origin.
pub fn instTok(self: *const Mir, inst: Inst) u32 {
    return self.insts.items(.tok)[@intFromEnum(inst)];
}

/// Returns the opcode of `inst`.
pub fn instOp(self: *const Mir, inst: Inst) Opcode {
    return self.insts.items(.op)[@intFromEnum(inst)];
}

/// Returns the block `inst` is linked into.
pub fn instBlock(self: *const Mir, inst: Inst) Block {
    return self.insts.items(.block)[@intFromEnum(inst)];
}

/// Returns the Value `inst` defines, or `.undef` for a terminator.
pub fn instResult(self: *const Mir, inst: Inst) Value {
    return self.insts.items(.result)[@intFromEnum(inst)];
}

/// Returns the decoded view of `inst`. A call's `args` borrows `extra` and is
/// invalidated by any later append to the pool. Reads only the `op`/`a`/`b`/`c`
/// columns.
pub fn instData(self: *const Mir, inst: Inst) InstData {
    const i = @intFromEnum(inst);
    const row: struct { op: Opcode, a: u32, b: u32, c: u32 } = .{
        .op = self.insts.items(.op)[i],
        .a = self.insts.items(.a)[i],
        .b = self.insts.items(.b)[i],
        .c = self.insts.items(.c)[i],
    };
    return switch (opClass(row.op)) {
        .unary => .{ .unary = .{ .op = row.op, .operand = @enumFromInt(row.a) } },
        .binary => .{ .binary = .{
            .op = row.op,
            .lhs = @enumFromInt(row.a),
            .rhs = @enumFromInt(row.b),
        } },
        .ternary => .{ .ternary = .{
            .cond = @enumFromInt(row.a),
            .then_val = @enumFromInt(row.b),
            .else_val = @enumFromInt(row.c),
        } },
        .phi => .{ .phi = .{ .start = row.b, .count = row.c } },
        .branch => .{ .branch = .{
            .cond = @enumFromInt(row.a),
            .then_block = @enumFromInt(row.b),
            .else_block = @enumFromInt(row.c),
        } },
        .jump => .{ .jump = .{ .target = @enumFromInt(row.a) } },
        .call => .{
            .call = .{
                .callee = @enumFromInt(row.a),
                .name = self.strings.get(@enumFromInt(self.extra.items[row.b])),
                // Borrowed slice into the payload pool; invalidated by further appends.
                .args = @ptrCast(self.extra.items[row.b + 1 ..][0..row.c]),
            },
        },
        .anew => .{ .anew = .{ .array = row.a } },
        .load => .{ .load = .{ .op = row.op, .arr = @enumFromInt(row.a), .index = @enumFromInt(row.b) } },
        .store => .{ .store = .{
            .arr = @enumFromInt(row.a),
            .index = @enumFromInt(row.b),
            .value = @enumFromInt(row.c),
        } },
    };
}

/// Returns operand `i` of a phi (0..count-1 from `instData(...).phi`).
pub fn phiPair(self: *const Mir, inst: Inst, i: u32) PhiPair {
    const n = @intFromEnum(inst);
    assert(self.insts.items(.op)[n] == .phi and i < self.insts.items(.c)[n]);
    const at = self.insts.items(.b)[n] + i * 2;
    return .{
        .block = @enumFromInt(self.extra.items[at]),
        .value = @enumFromInt(self.extra.items[at + 1]),
    };
}

// ----------------------------------------------------------- extra pool ----

/// Appends raw u32s and returns the start index. Prefer the typed wrappers.
/// Invalidates slices previously returned by `instData`.
pub fn addExtra(self: *Mir, gpa: std.mem.Allocator, words: []const u32) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.appendSlice(gpa, words);
    return @intCast(start);
}

fn addExtraPairs(self: *Mir, gpa: std.mem.Allocator, pairs: []const PhiPair) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.ensureUnusedCapacity(gpa, pairs.len * 2);
    for (pairs) |p| {
        self.extra.appendAssumeCapacity(@intFromEnum(p.block));
        self.extra.appendAssumeCapacity(@intFromEnum(p.value));
    }
    return @intCast(start);
}

// -------------------------------------------------------------------------

test "mir: const dedup, block chain, phi pairs, alias" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "diode" };
    defer mir.deinit(gpa);

    // sentinels + dedup (§4.2 constant expressions)
    try std.testing.expectEqual(Value.f_one, try mir.addFloatConst(gpa, 1.0));
    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    const k = try mir.addFloatConst(gpa, 1.5);
    try std.testing.expectEqual(k, try mir.addFloatConst(gpa, 1.5));
    try std.testing.expectEqual(@as(f64, 1.5), mir.valueDef(k).float_const);
    // 0.0 and -0.0 are distinct bit patterns and must not collapse
    try std.testing.expect(try mir.addFloatConst(gpa, -0.0) != Value.f_zero);

    const entry = try mir.addBlock(gpa);
    const vd = try mir.addBlockParam(gpa, 0);
    const vs = try mir.addBlockParam(gpa, 1);
    const dv = try mir.emit(gpa, entry, .fsub, &.{ vd, vs });
    const id = try mir.emit(gpa, entry, .fmul, &.{ dv, k });
    try std.testing.expectEqual(@as(u32, 0), mir.valueDef(vd).block_param);

    // instruction chain + decoded view
    var it = mir.blockInsts(entry);
    const in0 = it.next().?;
    const in1 = it.next().?;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(dv, mir.instResult(in0));
    try std.testing.expectEqual(id, mir.instResult(in1));
    try std.testing.expectEqual(vs, mir.instData(in0).binary.rhs);
    try std.testing.expectEqual(in1, mir.valueDef(id).inst_result);

    // call (§4.3): name + args round-trip through the extra pool
    const nm = try mir.internString(gpa, "exp");
    try std.testing.expectEqual(nm, try mir.internString(gpa, "exp")); // deduped
    const e = try mir.emitCall(gpa, entry, nm, &.{id});
    const cd = mir.instData(mir.valueDef(e).inst_result).call;
    try std.testing.expectEqualStrings("exp", cd.name);
    try std.testing.expectEqual(Callee.systf, cd.callee); // bare `exp` is an opcode, not a callee
    try std.testing.expectEqualSlices(Value, &.{id}, cd.args);

    // phi (§5.8): empty then filled, and trivial-phi aliasing
    const join = try mir.addBlock(gpa);
    const p = try mir.emitPhi(gpa, join, &.{});
    const pi = mir.valueDef(p).inst_result;
    try std.testing.expectEqual(@as(u32, 0), mir.instData(pi).phi.count);
    try std.testing.expectEqual(join, mir.instBlock(pi));
    try std.testing.expectEqual(entry, mir.instBlock(in1));
    try mir.setPhiPairs(gpa, pi, &.{ .{ .block = entry, .value = id }, .{ .block = join, .value = e } });
    try std.testing.expectEqual(@as(u32, 2), mir.instData(pi).phi.count);
    try std.testing.expectEqual(e, mir.phiPair(pi, 1).value);

    mir.setAlias(p, e);
    try std.testing.expectEqual(e, mir.resolveAlias(p));
    try std.testing.expectEqual(id, mir.resolveAlias(id));

    var bi = mir.blockIter();
    try std.testing.expectEqual(Block.entry, bi.next().?);
    try std.testing.expectEqual(join, bi.next().?);
    try std.testing.expect(bi.next() == null);
}
