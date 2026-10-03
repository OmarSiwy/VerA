//! The expression table of the AST (LRM §4.2-§4.6, §5.10's event
//! expressions; annex A.8): one SoA row per expression, addressed by `ExprId`,
//! with literal values and variable-arity operand lists in side tables. The
//! parser appends rows; every later stage reads them through `ExprStore`.

const std = @import("std");
const Integer = @import("integer.zig");
const IntLiteral = @import("lexer.zig").IntLiteral;
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StrId = ast.StrId;
const SourceFile = ast.SourceFile;

/// A.8.6 unary_operator. Stored in the `extra` column of a `.unary` node.
pub const UnaryOp = enum(u8) {
    plus, // +      §4.2.1
    minus, // -      §4.2.1
    logical_not, // !      §4.2.7
    bit_not, // ~      §4.2.8
    reduce_and, // &      §4.2.9
    reduce_nand, // ~&     §4.2.9
    reduce_or, // |      §4.2.9
    reduce_nor, // ~|     §4.2.9
    reduce_xor, // ^      §4.2.9
    reduce_xnor, // ~^ ^~  §4.2.9
};

/// A.8.6 binary_operator. Stored in the `extra` column of a `.binary` node.
pub const BinaryOp = enum(u8) {
    add, // +    §4.2.1
    sub, // -    §4.2.1
    mul, // *    §4.2.1
    div, // /    §4.2.1
    mod, // %    §4.2.1
    pow, // **   §4.2.1
    eq, // ==   §4.2.5
    neq, // !=   §4.2.5
    case_eq, // ===  §4.2.5 (digital; rejected in the analog subset, annex C)
    case_neq, // !==  §4.2.5
    lt, // <    §4.2.4
    le, // <=   §4.2.4
    gt, // >    §4.2.4
    ge, // >=   §4.2.4
    logical_and, // &&   §4.2.7
    logical_or, // ||   §4.2.7
    bit_and, // &    §4.2.8
    bit_or, // |    §4.2.8
    bit_xor, // ^    §4.2.8
    bit_xnor, // ~^ ^~ §4.2.8
    shl, // <<   §4.2.10
    shr, // >>   §4.2.10
    ashl, // <<<  §4.2.10
    ashr, // >>>  §4.2.10
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// `.branch_access` `extra` value for A.8.9's hierarchical_unnamed_branch_reference
/// (`V(drv.branch(x, y))`): the child's existing unnamed branch (§5.6.8.2), as
/// against `V(drv.x, drv.y)`, which creates a new one in the writer (§5.6.8.1).
/// The parser rewrites both to the same terminal pair, so this is the only
/// record of which one was written.
pub const branch_ref_hier_unnamed: u32 = 1;

/// Expression node tag: LRM §4.2 (operators), §4.3/§4.5/§4.6 (calls), §4.4
/// (access functions), §5.10 (A.6.5 event expressions).
/// Each arm documents its column usage; `main_tok` is always the token the
/// node is reported at.
pub const ExprTag = enum(u8) {
    // ---- literals and names: §2.6, §2.7, §2.8, A.8.7 ----
    /// `extra` = index into `ExprStore.ints`. LRM §2.6.1.
    int_literal,
    /// Exact four-state or wide constant; rejected by the analog integer boundary.
    logic_literal,
    /// `extra` = index into `ExprStore.reals`. LRM §2.6.2 (incl. SI suffixes).
    real_literal,
    /// `str` = interned, escape-processed contents. LRM §2.7.
    str_literal,
    /// A.2.5 `value_range_expression ::= ... | inf | -inf`. Only legal inside a
    /// `ValueRange`; the finiteness proof reads these directly.
    pos_inf,
    neg_inf,
    /// `str` = name. LRM §2.8 (variables, nets, params, genvars, named events).
    ident,
    /// Dotted name: `extra` = StrId list offset (2+ parts). Covers
    /// hierarchical_identifier (§6.8) and nature_attribute_reference
    /// (§3.6.1.3, e.g. `electrical.potential.abstol`); lowering tells them
    /// apart by resolving the first part.
    hier_ident,

    // ---- operators: §4.2 ----
    /// `lhs` = operand, `extra` = @intFromEnum(UnaryOp).
    unary,
    /// `lhs`, `rhs` operands, `extra` = @intFromEnum(BinaryOp).
    binary,
    /// §4.2.12 `?:`: `lhs` = cond, `rhs` = then, `extra` = @intFromEnum(else).
    /// Read the third operand with `ExprStore.ternaryElse`.
    ternary,

    // ---- calls (all: `str` = callee name, `extra` = ExprId list offset) ----
    /// §4.7 user-defined analog function call (A.8.2 analog_function_call).
    call,
    /// §4.3 math built-in (A.8.2 analog_built_in_function_name). Lowering maps
    /// the name to a MIR op and to the LRM §4.3 domain table.
    builtin_call,
    /// ch9 system function / task-as-expression, and §9.x `analysis("...")`
    /// (A.8.2 analog_system_function_call, analysis_function_call). `$name`
    /// without parens is this tag with an empty arg list.
    sys_call,
    /// §4.5 analog operator / filter: ddt, ddx, idt, idtmod, absdelay,
    /// transition, slew, last_crossing, limexp, laplace_*, zi_* (A.8.2
    /// analog_filter_function_call). Each occurrence owns runtime state, so it
    /// must stay a distinct tag from `builtin_call`.
    filter_call,
    /// §4.6 small-signal / noise: ac_stim, white_noise, flicker_noise,
    /// noise_table, noise_table_log (A.8.2 analog_small_signal_function_call).
    noise_call,

    // ---- access functions: §4.4 ----
    /// §4.4.1 branch probe: `V(a)`, `V(a,b)`, `I(br)`. `str` = access
    /// identifier (`V`/`I`/nature access name, §3.6.1.4), `lhs` = first
    /// net-or-branch reference, `rhs` = second net reference or `.none`.
    /// `extra` = `branch_ref_hier_unnamed` for §5.6.8.2's
    /// `inst.branch(x, y)` spelling, 0 otherwise.
    branch_access,
    /// §4.4.2 / §5.4.3 port branch probe `I(<p>)` (A.8.2
    /// port_probe_function_call). `str` = access identifier, `lhs` = port ref.
    port_access,

    // ---- aggregates: §4.2.13, §3.4.4, A.8.1 ----
    /// `{a, b, ...}`: `extra` = ExprId list offset.
    concat,
    /// `{n{...}}`: `lhs` = repeat count, `rhs` = the inner `.concat`.
    multi_concat,
    /// `'{a, b, ...}` assignment pattern (array param defaults §3.4.4, filter
    /// coefficient args §4.5.4): `extra` = ExprId list offset.
    assign_pattern,
    /// A.8.1's `'{ constant_expression { ... } }` whose count is not a literal
    /// (`'{N{0.5}}`): the parser cannot unroll it before parameters have
    /// values, so the pattern's only element is this node: `lhs` = count,
    /// `rhs` = an `.assign_pattern` holding the group. `Lower.patternElems`
    /// unrolls it with the constant folder.
    pattern_repl,
    /// §3.4.4 array / bit select `base[i]`: `lhs` = base, `rhs` = index.
    index,
    /// `msb:lsb` part select and `analog_range_expression` (A.8.3):
    /// `lhs` = msb, `rhs` = lsb.
    range,
    /// IEEE 1364-2005 §5.2.1 indexed part-select, A.8.3 `base +: width` or
    /// `base -: width`: `lhs` = base, `rhs` = width, `extra` = 0 for `+:` and
    /// 1 for `-:`.
    indexed_range,

    // ---- event expressions: §5.10, A.6.5 ----
    /// `e1 or e2` / `e1, e2`: `lhs`, `rhs`.
    event_or,
    /// `posedge e` / `negedge e`: `lhs` (digital edges, §5.10.1).
    event_posedge,
    event_negedge,
    /// §5.10.2 `initial_step` / `final_step`: `extra` = StrId list offset of
    /// the analysis-name arguments (empty list = no argument list).
    event_initial_step,
    event_final_step,
    /// §5.10.3 monitored event function: cross, above, timer, absdelta (A.6.5
    /// analog_event_functions). `str` = name, `extra` = ExprId list offset
    /// (a `.none` element is an omitted `analog_expression_or_null` argument).
    event_function,
    /// A.6.5 `driver_update expression`: `lhs` is the signal (§9.22.4). A digital
    /// event that §9.22 confines to a connect module, so it belongs under a
    /// `connectmodule`'s `DiscreteBlock`; analog lowering refuses it (E0701).
    event_driver_update,
};

/// One expression row. `ExprStore` keeps these as MultiArrayList columns, so
/// this struct is a row view, never an allocated node.
pub const Node = struct {
    tag: ExprTag,
    /// Token index this node is reported at.
    main_tok: u32 = 0,
    lhs: ExprId = .none,
    rhs: ExprId = .none,
    /// Opcode, literal payload or list offset; see `ExprTag`'s arms.
    extra: u32 = 0,
    /// Interned name, `.none` when the tag carries no name.
    str: StrId = .none,
};

// Budget: 21 bytes a row across the SoA columns (50,875 rows on psp103).
comptime {
    var bytes: usize = 0;
    for (@typeInfo(Node).@"struct".field_types) |T| bytes += @sizeOf(T);
    std.debug.assert(bytes == 21);
}

/// SoA expression store, one row per expression (LRM annex A). `ExprId`
/// indexes every column.
pub const ExprStore = struct {
    /// Columns: `.tag`, `.main_tok`, `.lhs`, `.rhs`, `.extra`, `.str`.
    nodes: std.MultiArrayList(Node) = .empty,
    /// Shared variable-arity payload pool. Each list is stored as
    /// `[len, e0, e1, ...]`; a row's `extra` is the offset of the `len` word.
    pool: std.ArrayList(u32) = .empty,
    /// Side table for `.real_literal` values (`extra` indexes it). Kept out of
    /// the row so the common integer/ident rows stay narrow.
    reals: std.ArrayList(f64) = .empty,
    /// `.int_literal` values that fit i64, with their source width and sign for
    /// expression sizing.
    ints: std.ArrayList(IntLiteral) = .empty,
    /// `.logic_literal` values: wider or four-state constants. Owns each `planes`.
    logic: std.ArrayList(Integer.Literal) = .empty,

    pub const empty: ExprStore = .{};

    /// Frees every column and each `logic` literal's `planes`; `gpa` must be
    /// the allocator the store was built with.
    pub fn deinit(self: *ExprStore, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.pool.deinit(gpa);
        self.reals.deinit(gpa);
        self.ints.deinit(gpa);
        for (self.logic.items) |literal| gpa.free(literal.planes);
        self.logic.deinit(gpa);
        self.* = .empty;
    }

    /// Appends one row (all columns in lockstep) and returns its handle.
    pub fn add(self: *ExprStore, gpa: std.mem.Allocator, node: Node) !ExprId {
        const id: u32 = @intCast(self.nodes.len);
        std.debug.assert(id != @backingInt(ExprId.none));
        try self.nodes.append(gpa, node);
        return @fromBackingInt(@intCast(id));
    }

    /// Appends a `.real_literal` row whose value lives in `reals`.
    pub fn addReal(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: f64) !ExprId {
        const idx: u32 = @intCast(self.reals.items.len);
        try self.reals.append(gpa, value);
        return self.add(gpa, .{ .tag = .real_literal, .main_tok = main_tok, .extra = idx });
    }

    /// Appends a synthetic unsized, signed `.int_literal` (the implementation
    /// integer width).
    pub fn addInt(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, value: i64) !ExprId {
        return self.addIntLiteral(gpa, main_tok, .{ .value = value, .width = 0, .signed = true });
    }

    /// Appends an `.int_literal` row whose value lives in `ints`.
    pub fn addIntLiteral(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, literal: IntLiteral) !ExprId {
        const idx: u32 = @intCast(self.ints.items.len);
        try self.ints.append(gpa, literal);
        return self.add(gpa, .{ .tag = .int_literal, .main_tok = main_tok, .extra = idx });
    }

    /// Appends a `.logic_literal` row. Takes ownership of `literal.planes`,
    /// which must be allocated with `gpa`; `deinit` frees it.
    pub fn addLogic(self: *ExprStore, gpa: std.mem.Allocator, main_tok: u32, literal: Integer.Literal) !ExprId {
        const idx: u32 = @intCast(self.logic.items.len);
        try self.logic.append(gpa, literal);
        return self.add(gpa, .{ .tag = .logic_literal, .main_tok = main_tok, .extra = idx });
    }

    /// Returns a `.logic_literal`'s value; asserts the tag. `planes` stays owned
    /// by the store.
    pub fn logicValue(self: *const ExprStore, id: ExprId) Integer.Literal {
        std.debug.assert(self.tag(id) == .logic_literal);
        return self.logic.items[self.extraOf(id)];
    }

    /// Returns every column of row `id`. A walk that needs one field reads
    /// that column instead (`tag`, `lhs`, ...). `id` must not be `.none`;
    /// the column accessors below share that precondition.
    pub fn get(self: *const ExprStore, id: ExprId) Node {
        return self.nodes.get(@backingInt(id));
    }

    pub fn tag(self: *const ExprStore, id: ExprId) ExprTag {
        return self.nodes.items(.tag)[@backingInt(id)];
    }
    pub fn mainTok(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.main_tok)[@backingInt(id)];
    }
    pub fn lhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.lhs)[@backingInt(id)];
    }
    pub fn rhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.rhs)[@backingInt(id)];
    }
    pub fn extraOf(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.extra)[@backingInt(id)];
    }
    pub fn strOf(self: *const ExprStore, id: ExprId) StrId {
        return self.nodes.items(.str)[@backingInt(id)];
    }

    /// Returns a `.unary` node's operator; asserts the tag.
    pub fn unOp(self: *const ExprStore, id: ExprId) UnaryOp {
        std.debug.assert(self.tag(id) == .unary);
        return @fromBackingInt(@intCast(@as(u8, @intCast(self.extraOf(id)))));
    }
    /// Returns a `.binary` node's operator; asserts the tag.
    pub fn binOp(self: *const ExprStore, id: ExprId) BinaryOp {
        std.debug.assert(self.tag(id) == .binary);
        return @fromBackingInt(@intCast(@as(u8, @intCast(self.extraOf(id)))));
    }
    /// Returns the third operand of a §4.2.12 `?:`; asserts the tag.
    pub fn ternaryElse(self: *const ExprStore, id: ExprId) ExprId {
        std.debug.assert(self.tag(id) == .ternary);
        return @fromBackingInt(@intCast(self.extraOf(id)));
    }
    /// Returns a §2.6.1 `.int_literal`'s value; asserts the tag.
    pub fn intValue(self: *const ExprStore, id: ExprId) i64 {
        std.debug.assert(self.tag(id) == .int_literal);
        return self.intLiteral(id).value;
    }
    /// Returns a `.int_literal` with its width and sign; asserts the tag.
    pub fn intLiteral(self: *const ExprStore, id: ExprId) IntLiteral {
        std.debug.assert(self.tag(id) == .int_literal);
        return self.ints.items[self.extraOf(id)];
    }
    /// Returns a §2.6.2 `.real_literal`'s value; asserts the tag.
    pub fn realValue(self: *const ExprStore, id: ExprId) f64 {
        std.debug.assert(self.tag(id) == .real_literal);
        return self.reals.items[self.extraOf(id)];
    }

    /// Stores a variable-arity list; returns the offset to put in a row's `extra`.
    fn addList(self: *ExprStore, gpa: std.mem.Allocator, items: []const u32) !u32 {
        const off: u32 = @intCast(self.pool.items.len);
        try self.pool.ensureUnusedCapacity(gpa, items.len + 1);
        self.pool.appendAssumeCapacity(@intCast(items.len));
        self.pool.appendSliceAssumeCapacity(items);
        return off;
    }
    /// Stores an ExprId list; returns its pool offset.
    pub fn addExprList(self: *ExprStore, gpa: std.mem.Allocator, items: []const ExprId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }
    /// Stores a StrId list; returns its pool offset.
    pub fn addStrList(self: *ExprStore, gpa: std.mem.Allocator, items: []const StrId) !u32 {
        return self.addList(gpa, @ptrCast(items));
    }

    /// Returns the list stored at pool offset `off`. The slice is invalidated
    /// by the next list append.
    pub fn list(self: *const ExprStore, off: u32) []const u32 {
        const n = self.pool.items[off];
        return self.pool.items[off + 1 ..][0..n];
    }

    /// Arguments of any call-shaped tag (`call`, `builtin_call`, `sys_call`,
    /// `filter_call`, `noise_call`, `event_function`) and the elements of
    /// `concat` / `assign_pattern`.
    pub fn args(self: *const ExprStore, id: ExprId) []const ExprId {
        return @ptrCast(self.list(self.extraOf(id)));
    }
    /// Parts of a `.hier_ident`, and the analysis names of
    /// `.event_initial_step` / `.event_final_step`.
    pub fn nameParts(self: *const ExprStore, id: ExprId) []const StrId {
        return @ptrCast(self.list(self.extraOf(id)));
    }

    /// Returns every child expression of `id`, in source order. This is the one
    /// exhaustive statement of `ExprTag`'s column usage, so a new tag is a
    /// compile error here. Elements may be `.none` (an omitted argument, a
    /// one-terminal probe). A list tag returns its pool slice; otherwise the
    /// result points into `buf`.
    pub fn children(self: *const ExprStore, id: ExprId, buf: *[3]ExprId) []const ExprId {
        switch (self.tag(id)) {
            .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident => return &.{},
            // StrId lists, not expressions.
            .hier_ident, .event_initial_step, .event_final_step => return &.{},
            .unary, .event_posedge, .event_negedge, .event_driver_update, .port_access => {
                buf[0] = self.lhs(id);
                return buf[0..1];
            },
            .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl, .event_or, .branch_access => {
                buf[0..2].* = .{ self.lhs(id), self.rhs(id) };
                return buf[0..2];
            },
            .ternary => {
                buf.* = .{ self.lhs(id), self.rhs(id), self.ternaryElse(id) };
                return buf;
            },
            .call, .builtin_call, .sys_call, .filter_call, .noise_call, .event_function, .concat, .assign_pattern => return self.args(id),
        }
    }
};

// ponytail: not modelled, because nothing would produce or consume the tag:
//   · `min:typ:max` (A.8.3 mintypmax_expression); the parser keeps the typ
//     value. Add a `.mintypmax` tag if a fixture needs the triple.

test "ExprStore round-trips rows, lists and literals" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const v = try f.intern(gpa, "V");
    const a = try f.intern(gpa, "a");
    try std.testing.expectEqual(v, try f.intern(gpa, "V")); // idempotent
    try std.testing.expectEqualStrings("a", f.str(a));

    const one = try f.exprs.addInt(gpa, 0, 1);
    const two_pt_5 = try f.exprs.addReal(gpa, 1, 2.5);
    try std.testing.expectEqual(@as(i32, 1), f.exprs.intValue(one));
    try std.testing.expectEqual(@as(f64, 2.5), f.exprs.realValue(two_pt_5));

    const sum = try f.exprs.add(gpa, .{
        .tag = .binary,
        .main_tok = 2,
        .lhs = one,
        .rhs = two_pt_5,
        .extra = @backingInt(BinaryOp.add),
    });
    try std.testing.expectEqual(BinaryOp.add, f.exprs.binOp(sum));
    try std.testing.expectEqual(one, f.exprs.lhs(sum));

    // `V(a)`: §4.4.1 branch access.
    const node_a = try f.exprs.add(gpa, .{ .tag = .ident, .main_tok = 3, .str = a });
    const probe = try f.exprs.add(gpa, .{ .tag = .branch_access, .main_tok = 4, .lhs = node_a, .str = v });
    try std.testing.expectEqual(ExprId.none, f.exprs.rhs(probe));

    // §4.3 call with an argument list in the shared pool.
    const off = try f.exprs.addExprList(gpa, &.{ sum, probe });
    const call = try f.exprs.add(gpa, .{ .tag = .builtin_call, .main_tok = 5, .extra = off, .str = try f.intern(gpa, "pow") });
    try std.testing.expectEqualSlices(ExprId, &.{ sum, probe }, f.exprs.args(call));

    // §4.2.12 ternary keeps its third operand in `extra`.
    const t = try f.exprs.add(gpa, .{ .tag = .ternary, .lhs = probe, .rhs = one, .extra = @backingInt(two_pt_5) });
    try std.testing.expectEqual(two_pt_5, f.exprs.ternaryElse(t));
}
