//! The AST the parser builds from the token stream (LRM annex A, ch3 declarations).
//! Expressions are SoA rows addressed by `ExprId`, statements a flat pool addressed
//! by `StmtId`, names interned as `StrId`; variable-arity payloads share one `u32`
//! pool. Every store is append-only, so the same tokens give the same ids. Lists are
//! unmanaged and meant for the compilation arena; `deinit` exists so tests can use a
//! gpa. Interned slices are borrowed and must outlive the `SourceFile`.

const Integer = @import("integer.zig");
const IntLiteral = @import("lexer.zig").IntLiteral;
const std = @import("std");

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

/// Handle into the expression columns (LRM annex A expression grammar).
pub const ExprId = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle into the statement pool. LRM §5 behavioral statements.
pub const StmtId = enum(u32) { none = std.math.maxInt(u32), _ };
/// Handle into the string intern table. LRM §2.8 identifiers, §2.7 strings.
pub const StrId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Scalar data types. LRM §3.1, §3.2, §3.3, §3.4.1.
/// `realtime` collapses to `.real` and `time` to `.integer` (A.2.1.1
/// parameter_type); the distinction is meaningless in the analog kernel.
/// `.unspecified` is `parameter p = <expr>;` with no type keyword: §3.4.1 derives
/// the type from the default expression, which only lowering can fold. Lowering
/// resolves it; codegen never sees it.
pub const Type = enum(u8) { real, integer, string, unspecified };

/// Port / function-argument direction. LRM §6.5.2.2 (ports), §4.7.2.3
/// (function output/inout args). `.unspecified` is a port named in
/// `list_of_ports` whose direction arrives later as a `port_declaration`
/// (A.1.3 / A.1.4).
pub const Direction = enum(u8) { unspecified, input, output, inout };

/// LRM §3.6.1 / A.1.7 `potential_or_flow`.
pub const PotentialOrFlow = enum(u8) { potential, flow };

// ---------------------------------------------------------------------------
// Operators: LRM §4.2, A.8.6
// ---------------------------------------------------------------------------

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
        std.debug.assert(id != @intFromEnum(ExprId.none));
        try self.nodes.append(gpa, node);
        return @enumFromInt(id);
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

    pub fn get(self: *const ExprStore, id: ExprId) Node {
        return self.nodes.get(@intFromEnum(id));
    }

    pub fn tag(self: *const ExprStore, id: ExprId) ExprTag {
        return self.nodes.items(.tag)[@intFromEnum(id)];
    }
    pub fn mainTok(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.main_tok)[@intFromEnum(id)];
    }
    pub fn lhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.lhs)[@intFromEnum(id)];
    }
    pub fn rhs(self: *const ExprStore, id: ExprId) ExprId {
        return self.nodes.items(.rhs)[@intFromEnum(id)];
    }
    pub fn extraOf(self: *const ExprStore, id: ExprId) u32 {
        return self.nodes.items(.extra)[@intFromEnum(id)];
    }
    pub fn strOf(self: *const ExprStore, id: ExprId) StrId {
        return self.nodes.items(.str)[@intFromEnum(id)];
    }

    /// Returns a `.unary` node's operator; asserts the tag.
    pub fn unOp(self: *const ExprStore, id: ExprId) UnaryOp {
        std.debug.assert(self.tag(id) == .unary);
        return @enumFromInt(@as(u8, @intCast(self.extraOf(id))));
    }
    /// Returns a `.binary` node's operator; asserts the tag.
    pub fn binOp(self: *const ExprStore, id: ExprId) BinaryOp {
        std.debug.assert(self.tag(id) == .binary);
        return @enumFromInt(@as(u8, @intCast(self.extraOf(id))));
    }
    /// Returns the third operand of a §4.2.12 `?:`; asserts the tag.
    pub fn ternaryElse(self: *const ExprStore, id: ExprId) ExprId {
        std.debug.assert(self.tag(id) == .ternary);
        return @enumFromInt(self.extraOf(id));
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

// ---------------------------------------------------------------------------
// String interning: LRM §2.7, §2.8
// ---------------------------------------------------------------------------

/// Identifier and string intern table. Ids are assigned in insertion order, so
/// they are deterministic for a given token stream.
///
/// The MIR embeds the same type (`Mir.strings`, `Mir.StrId`). A StrId is only
/// meaningful against the table it came from; lowering carries a name across
/// with `mir.internString(gpa, file.str(id))`.
///
/// Stored slices are borrowed (source substrings or parser arena copies) and
/// never freed here; they must outlive the table.
pub const StringInterner = struct {
    strings: std.ArrayList([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(StrId) = .empty,

    pub const empty: StringInterner = .{};

    pub fn deinit(self: *StringInterner, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.map.deinit(gpa);
        self.* = .empty;
    }

    /// Returns the id for `s`, adding it if new. `s` is borrowed and must
    /// outlive the table.
    pub fn intern(self: *StringInterner, gpa: std.mem.Allocator, s: []const u8) !StrId {
        const gop = try self.map.getOrPut(gpa, s);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: StrId = @enumFromInt(@as(u32, @intCast(self.strings.items.len)));
        // errdefer: on OOM below, drop the just-inserted key so the table never
        // maps a name to an id that has no string.
        errdefer _ = self.map.remove(s);
        try self.strings.append(gpa, s);
        gop.value_ptr.* = id;
        return id;
    }

    /// Returns the string for `id`; asserts `id != .none`.
    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        std.debug.assert(id != .none);
        return self.strings.items[@intFromEnum(id)];
    }

    /// Returns the id for `s` without inserting it.
    pub fn find(self: *const StringInterner, s: []const u8) ?StrId {
        return self.map.get(s);
    }

    /// Returns whether `id` names `s`; false for `.none`.
    pub fn eql(self: *const StringInterner, id: StrId, s: []const u8) bool {
        return id != .none and std.mem.eql(u8, self.get(id), s);
    }
};

// ---------------------------------------------------------------------------
// Declarations: LRM ch3, ch4 §4.7, ch6
// ---------------------------------------------------------------------------

/// A declared dimension / range: `[msb:lsb]` (A.2.5 `range`, `dimension`).
/// Used by array parameters (§3.4.4), array variables (§3.2.2) and vector
/// ports / nets (§6.5.2).
pub const Dim = struct {
    msb: ExprId,
    lsb: ExprId,
};

/// LRM §3.4.2 value_range: `from [lo:hi]` / `exclude (lo:hi)` / `exclude val`.
/// A.2.5 `value_range`. `lo`/`hi` may be `.pos_inf` / `.neg_inf` nodes.
///
/// These are the only bound evidence the finiteness proof has; they travel
/// ParamDecl → Lower.ParamInfo → proof.zig.
pub const ValueRange = struct {
    kind: Kind,
    lo: ExprId,
    /// `.none` for a single-value `exclude` and for the string-set form.
    hi: ExprId = .none,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
    /// A.2.5 `value_range_type '{ string {, string} }`: offset of a StrId list
    /// in `ExprStore.pool`, or `null` for the numeric forms. LRM §3.4.2 string
    /// parameter value ranges.
    strings: ?u32 = null,

    pub const Kind = enum(u8) { from, exclude };
};

/// Parameter declaration. LRM §3.4 (A.2.1.1 parameter_declaration /
/// local_parameter_declaration, A.2.4 param_assignment). One `ParamDecl` per
/// declared name: the parser expands `parameter real a = 1, b = 2;`.
pub const ParamDecl = struct {
    name: StrId,
    ty: Type, // §3.4.1 (`.unspecified` ⇒ infer from `default`)
    default: ExprId, // §3.4 default expression (constant_mintypmax_expression)
    is_local: bool = false, // §3.4.5 localparam
    /// A.2.1.1 `parameter signed`: IEEE 1364-2005 §12.2 converts an override
    /// to a signed value.
    is_signed: bool = false,
    /// IEEE 1364-2005 §4.10.3 a module-body `specparam`, kept as a
    /// `localparam` (`is_local`) that no module parameter may read.
    is_spec: bool = false,
    /// §3.4.4 array parameter dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// A.2.1.1's `[ range ]`, the first arm's width bracket (`parameter [3:0]
    /// nib = 4'h5;`). Not `dims`: A.2.5's `range` is a vector width and
    /// `dimension` is an array bound, and lowering scalarizes the latter.
    /// `null` when the declaration writes no bracket, which is every
    /// `parameter_type` form (the two A.2.1.1 arms are exclusive).
    packed_range: ?Dim = null,
    /// §6.3 this parameter's value came from an instance parameter value
    /// assignment (or a paramset), not from its own declaration. Set only by
    /// elaboration (`ir/elaborate/clone.zig`) when it turns a flattened child's
    /// parameter into a `localparam` carrying the override as its default.
    ///
    /// It separates the two halves of §3.4.2: a declared default is judged only
    /// for well-formed bounds (E0347), while "the parameter value shall be
    /// within the range" applies to a supplied value.
    is_override: bool = false,
    /// LRM §3.4.2 value ranges (from/exclude). The finiteness proof needs them,
    /// so lowering carries them into `Lower.ParamInfo`.
    ranges: []const ValueRange = &.{},
    main_tok: u32 = 0,
};

/// LRM §3.4.6 `aliasparam alias = target;` (A.2.1.1 aliasparam_declaration).
pub const AliasParam = struct {
    alias: StrId,
    target: StrId,
};

/// Local variable declaration: `real`/`integer`/`string` (+ `realtime`/`time`
/// folded into those). LRM §3.2, §3.3; A.2.8 analog_block_item_declaration.
/// One per declared name.
pub const VarDecl = struct {
    name: StrId,
    ty: Type,
    /// §3.2.2 array dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// A.2.2.1 `variable_identifier = constant_expression`; `.none` if absent.
    init: ExprId = .none,
    main_tok: u32 = 0,
    /// Digital declaration metadata retained for source execution. Analog lowering
    /// continues to use ty/dims; a packed reg range is not an unpacked array.
    storage: enum { variable, reg, time } = .variable,
    packed_range: ?Dim = null,
    is_signed: bool = true,
    /// §6.4.3 / §3.2.1 declared with a `(* desc = ... *)` attribute, which is
    /// what makes a variable an output variable. Recorded for paramset
    /// variables, where §6.4.3's hiding rule turns on it.
    desc: bool = false,
};

/// The wired-logic function a net's drivers resolve through (IEEE 1364-2005
/// §7.9, Verilog-AMS §3.7): A.2.2.1 `net_type` plus the two spellings A.2.1.3
/// gives arms of their own, `trireg` (§3.8 charge storage) and `wreal` (§3.7).
/// A declaration that names no net type (`electrical a;`) is `.wire`, the §7.9
/// default resolution.
pub const NetKind = enum(u8) {
    wire,
    tri,
    tri0,
    tri1,
    triand,
    trior,
    trireg,
    wand,
    wor,
    uwire,
    supply0,
    supply1,
    /// §3.7: "The wreal, or real net data type, represents a real-valued
    /// physical connection between structural entities." Not four-state
    /// ("wreal nets shall have an initial value of zero"), so an `else` arm of
    /// a four-state resolution is wrong for one. `Parser.parseWrealDecl`
    /// refuses it under `--run` for that reason.
    wreal,
};

/// A.2.2.2 `strength0`/`strength1`/`charge_strength` as one scale (IEEE 1364
/// clause 7): supply > strong > pull > large > weak > medium > small > highz.
/// The numeric values are that order, so `@intFromEnum` comparison is "stronger
/// than". The 0-side/1-side split belongs to the keyword, so the parser checks
/// it (rejecting `(strong0, pull0)`).
pub const Strength = enum(u8) { highz = 0, small = 1, medium = 2, weak = 3, large = 4, pull = 5, strong = 6, supply = 7 };

/// The three strength slots A.2.1.3 puts on one `net_declaration` (a
/// `charge_strength` on the `trireg` arms, a `drive_strength` pair on the
/// `list_of_net_decl_assignments` arms), carried together so the parser can
/// return whichever bracket the source wrote. Defaults: `medium` (IEEE
/// 1364-2005 §3.8) and `(strong1, strong0)` (§7.10).
pub const NetStrength = struct {
    charge: Strength = .medium,
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A `drive_strength` was written, which A.2.1.3 allows only before a
    /// `list_of_net_decl_assignments` (IEEE 1364-2005 §4.4).
    drive: bool = false,
};

/// A.2.2.3 `delay3 ::= # delay_value | # ( delay_value [ , delay_value [ , delay_value ] ] )`.
/// One value means all three; two mean rise and fall with the turn-off delay
/// taken as the minimum of them (IEEE 1364-2005 §7.14); three are given. On a
/// `trireg` the third value is not a turn-off delay at all but A.2.1.3's charge
/// decay time, which is why the third field is spelled for both readings.
/// `.none` throughout is "no delay".
pub const Delay3 = struct {
    rise: ExprId = .none,
    fall: ExprId = .none,
    /// Turn-off (to z) on a driver, charge decay on a `trireg`.
    off: ExprId = .none,

    /// Returns whether any delay was written. The two-value form leaves `off`
    /// `.none`: §7.14 derives it as the smaller of rise and fall. A `trireg`
    /// reads that `.none` as "no charge decay", so `trireg c;` holds forever.
    pub fn any(self: Delay3) bool {
        return self.rise != .none;
    }
};

/// Net declaration. LRM §3.6.3 (A.2.1.3 net_declaration). One per declared
/// name. In the Verilog-A subset (annex C) the only forms that matter are
/// `<discipline> a, b;` and `ground <discipline> g;`.
pub const NetDecl = struct {
    name: StrId,
    /// A.2.2.1 net type; `.wire` when the declaration names none.
    kind: NetKind = .wire,
    /// §3.6.2 discipline identifier; `.none` when the net is untyped (§3.9
    /// discipline resolution then assigns it).
    discipline: StrId = .none,
    /// §3.6.3 `ground` declaration: a global reference node.
    is_ground: bool = false,
    /// §6.5.2 vector net range; `null` for a scalar.
    range: ?Dim = null,
    /// A.2.3 `net_identifier { dimension }`: a net array (IEEE 1364-2005
    /// §4.9.1), one net per element. Only a digital parse keeps one.
    dims: []const Dim = &.{},
    /// A.2.1.3 `[ signed ]`. IEEE 1364-2005 §12.3.11: signedness belongs to the
    /// declaration, so each side of a port keeps its own.
    is_signed: bool = false,
    /// A.2.1.3 `charge_strength`, `trireg` only; `medium` is IEEE 1364-2005
    /// §3.8's default.
    charge: Strength = .medium,
    /// A.2.1.3 `[ drive_strength ]` on the `list_of_net_decl_assignments` arms.
    /// IEEE 1364-2005 §7.10's default is `(strong1, strong0)`.
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A.2.1.3 `[ delay3 ]`. On a `trireg` the third value is the charge decay
    /// time; on every other net type it is the turn-off delay of the net's own
    /// transition.
    delay: Delay3 = .{},
    /// A.2.4 net_decl_assignment; `.none` when the declaration has no `=`.
    /// §3.6.3.2 makes this a nodeset value for the net's potential: an initial
    /// guess for the solver, not an assignment or a clamp. Folded by
    /// `Lower.lowerModule`.
    init: ExprId = .none,
    main_tok: u32 = 0,
};

/// Branch declaration. LRM §3.12 (A.2.1.3 branch_declaration /
/// port_branch_declaration). One per declared branch name.
pub const BranchDecl = struct {
    name: StrId,
    /// First terminal: an `.ident` or `.index` expression (net or port ref).
    hi: ExprId,
    /// Second terminal; `.none` = implicit global ground (§3.12, §1.3.1.1).
    lo: ExprId = .none,
    /// §3.12 `branch (<p>)`: a port branch, not a node pair.
    is_port_branch: bool = false,
    /// A.2.3 `branch_identifier [ range ]`: array of branches; `null` = scalar.
    range: ?Dim = null,
    main_tok: u32 = 0,
};

/// Module port. LRM §6.5 (A.1.3 port / port_declaration).
pub const Port = struct {
    name: StrId,
    direction: Direction = .unspecified, // §6.5.2.2
    /// §6.5.2.1 discipline identifier; `.none` ⇒ resolved by §3.9.
    discipline: StrId = .none,
    /// §6.5.2 vector port range `[msb:lsb]` from the port direction
    /// declaration (`inout [0:3] p;`); `null` for a scalar port.
    range: ?Dim = null,
    /// §6.5.2.2 the range from the port type declaration (`electrical [0:3]
    /// p;`). Kept apart from `range` because §6.5.2.2 requires the two to
    /// "evaluate to the same value"; lowering folds and compares them (E0350).
    type_range: ?Dim = null,
    /// A.2.1.2 `net_type` from the port type declaration, `.wire` when none was
    /// written (A.2.1.3's default, and §3.5's for an undeclared port). A net
    /// declaration naming a header port is folded into the port
    /// (`parseNetNames`), and §7.9 resolution reads this type.
    kind: NetKind = .wire,
    /// A.1.3 `port ::= . port_identifier ( [ port_expression ] )`: the port's
    /// external name, the one an instantiation connects to; `.none` when the
    /// port is named by the net it carries. Several consecutive ports share one
    /// external name when the port expression is a concatenation (§6.5.1).
    external_name: StrId = .none,
    /// A.1.3 this port_reference continues the previous one's port_expression,
    /// a concatenation: `{c, d}` is two `Port`s, the second one `concat_rest`.
    concat_rest: bool = false,
    /// IEEE 1364-2005 A.1.3 `port_reference ::= port_identifier [ [
    /// constant_range_expression ] ]`: the bit-select (`msb == lsb`) or
    /// part-select of the net this reference names. A digital parse only.
    select: ?Dim = null,
    /// A.2.1.2 `[ signed ]` on the direction or the net declaration of this
    /// port. §12.3.3: "If either ... is declared as signed, then the other
    /// shall also be considered signed."
    is_signed: bool = false,
    main_tok: u32 = 0,
};

/// Analog function argument. LRM §4.7.2 (A.2.6 analog_function_item_declaration
/// → input/output/inout declaration). §4.7.2.3 makes `output`/`inout` args
/// write-back parameters.
pub const FuncArg = struct {
    name: StrId,
    ty: Type,
    direction: Direction, // §4.7.2.3; `.input` unless declared otherwise
    /// §4.7.2.3/§4.7.2.4 an array formal, `output [0:1] out;`. A.2.6 puts the
    /// range on the direction declaration and §4.7.1's Example 3 on the block
    /// item declaration (`real a[0:1];`); `parseFuncDecl` merges either.
    dims: []const Dim = &.{},
    /// The identifier token, so §4.7.1's "all formal arguments shall have an
    /// associated block item declaration" (E0225) can point at the formal that
    /// never got one, after the parser has moved on to `endfunction`.
    main_tok: u32 = 0,
};

/// IEEE 1364-2005 §10.2 task or §10.4 function (A.2.6 `function_declaration`,
/// A.2.7 `task_declaration`) as a digital parse records it: the 1364
/// spellings VAMS §4.7 admits beside the analog function: packed port ranges,
/// `reg`/`integer`/`time` formals, `automatic`, and tasks at all. An analog
/// parse records its tasks here too (the mixed-signal kernel runs them) and
/// no function: its bare `function` is a `FuncDecl`.
///
/// Every formal, local and the function result is a `VarDecl`, because that
/// is what §10.2.3/§10.4.1 make them: variables of the subroutine's scope.
pub const Subroutine = struct {
    name: StrId,
    is_function: bool,
    /// A.2.6/A.2.7 `automatic`: storage per activation (§10.2.3, §10.4.2).
    automatic: bool = false,
    /// §10.4.1 "a variable with the same name as the function"; its type is
    /// A.2.6's `function_range_or_type`. Unused for a task.
    result: VarDecl = .{ .name = .none, .ty = .integer },
    /// A.2.7 `tf_*_declaration`s in declaration order, which is call order.
    ports: []const TfPort = &.{},
    /// A.2.7 `block_item_declaration`s.
    vars: []const VarDecl = &.{},
    body: StmtId,
    main_tok: u32 = 0,
};

/// One A.2.7 task/function formal: a direction and the variable it declares.
pub const TfPort = struct { direction: Direction, v: VarDecl };

/// User-defined analog function. LRM §4.7.1 (A.2.6 analog_function_declaration).
/// The implicit return variable is the function's own name (§4.7.1).
pub const FuncDecl = struct {
    name: StrId,
    ret_ty: Type, // §4.7.1 analog_function_type (default `.real`)
    args: []const FuncArg, // §4.7.2, in declaration order (call order)
    /// §4.7.2 local declarations of the function body.
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    /// §4.7.1 the single `analog_function_statement` (usually a `.block`).
    body: StmtId,
    main_tok: u32 = 0,
    /// §4.7's opening paragraph: "Each function can be an analog user-defined
    /// function or a digital function (as defined in IEEE Std 1364 Verilog)."
    /// False for the bare `function` spelling. The declaration is legal either
    /// way; §7.3.7 forbids only the call across contexts.
    is_analog: bool = true,
};

/// One `analog` construct. LRM §5.2 (A.6.2 analog_construct).
pub const AnalogBlock = struct {
    /// §5.2.1 `analog initial`: evaluated once, at initialization only.
    is_initial: bool = false,
    body: StmtId,
    main_tok: u32 = 0,
    /// Which module instance wrote this block, after elaboration concatenated
    /// every instance's blocks into the top's. 0 is the top itself; each inlined
    /// instance gets its own.
    ///
    /// §5.4.1 gives branch identity per instance, which flattening loses: two
    /// instances across the same nets share one unnamed branch. Same-kind
    /// contributions still aggregate, but §5.6.1.3's flow-discards-potential rule
    /// is about one branch, so `Lower.discardOpposite` scopes it by this unit.
    unit: u32 = 0,
};

/// One `initial` or `always` construct (A.6.2 initial_construct /
/// always_construct), §7.2.2's discrete context.
/// The analog device pipeline accepts only constant initial assignments; the
/// digital executor runs the rest through its event scheduler.
pub const DiscreteBlock = struct {
    /// `always` rather than `initial`. §7.2.2 puts both in the same context, so
    /// the context checks read this only for diagnostic wording;
    /// `Lower.collectInitialState` collects from `initial` only.
    is_always: bool = false,
    /// Hoisted out of a generate block by an analog parse: it exists only as
    /// the scheme selects (§6.6), which the digital engine decides, so it runs
    /// there and has no constant reading.
    generated: bool = false,
    body: StmtId,
    main_tok: u32 = 0,
};

/// A.6.1 `net_assignment ::= net_lvalue = expression`: one driver of one net
/// (IEEE 1364-2005 §6.1). `assign a = b, c = d;` is two of these.
pub const ContAssign = struct {
    target: ExprId,
    value: ExprId,
    /// A.6.1 `[ drive_strength ]`; IEEE 1364-2005 §7.9's default is
    /// `(strong1, strong0)`.
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A.6.1 `[ delay3 ]`: the driver's own delay, §6.1.3 inertial.
    delay: Delay3 = .{},
    main_tok: u32 = 0,
};

/// A.3.4's gate types that compute a logic value. §7.8.5's tables define all
/// twelve; `n_input`, `n_output` and `enable` gates differ only in what their
/// terminal list means, which `GateInst` records in its shape.
pub const GateKind = enum { g_and, g_nand, g_or, g_nor, g_xor, g_xnor, g_buf, g_not, g_bufif0, g_bufif1, g_notif0, g_notif1 };

/// A.3.1 one `gate_instance`. `out` is the output terminal (§7.8.5.1's `out`;
/// a `buf`/`not` with several outputs becomes one `GateInst` per output, since
/// each is a separate driver). `ins` is the rest in source order: the inputs of
/// an n-input gate, `(data, enable)` for an enable gate, the single input of
/// `buf`/`not`. A gate drives `out` (§7.1), so it carries a `ContAssign`'s
/// strength and delay.
pub const GateInst = struct {
    kind: GateKind,
    out: ExprId,
    ins: []const ExprId,
    /// A.3.1 `name_of_gate_instance`, `.none` when not written.
    name: StrId = .none,
    /// IEEE 1364-2005 §7.1.5 an array of instances, `name [ range ]`: one
    /// gate per index, vector terminals split among them (§7.1.6).
    range: ?Dim = null,
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    delay: Delay3 = .{},
    main_tok: u32 = 0,
};

/// A.7.4 `edge_identifier` / A.7.5.3 `timing_check_event_control`.
pub const SpecEdge = enum(u8) { none, posedge, negedge, edge };
/// A.7.4 `polarity_operator`, absent when not written.
pub const SpecPolarity = enum(u8) { none, positive, negative };

/// A.7.2 one `path_declaration`: parallel (`=>`) or full (`*>`), simple or
/// edge-sensitive, optionally state-dependent.
pub const SpecPath = struct {
    full: bool,
    edge: SpecEdge = .none,
    /// The polarity before the arrow (a simple path's).
    polarity: SpecPolarity = .none,
    /// `if ( module_path_expression )`, or `.none`.
    cond: ExprId = .none,
    ifnone: bool = false,
    ins: []const ExprId,
    outs: []const ExprId,
    /// An edge-sensitive path's `data_source_expression` and the polarity
    /// written before its colon.
    data: ExprId = .none,
    data_polarity: SpecPolarity = .none,
    /// A.7.4 `list_of_path_delay_expressions`: 1, 2, 3, 6 or 12.
    delays: []const ExprId,
    main_tok: u32,
};

/// A.7.5.1 one `system_timing_check`: the command, and each argument slot in
/// order (`.none` for a slot A.7.5.1 lets be empty) with the event control
/// written on it.
pub const TimingCheck = struct {
    name: StrId,
    args: []const ExprId,
    edges: []const SpecEdge,
    main_tok: u32,
};

/// A.3.1 one `pull_gate_instance`, IEEE 1364-2005 §7.8's pullup/pulldown
/// source. It drives one constant, so it is not a `GateInst`: it has no
/// inputs and §7.8 gives it no delay. `strength` is the one side that counts
/// ("a strength0 specification on a pullup source ... shall be ignored").
pub const PullInst = struct {
    out: ExprId,
    /// `pullup` drives 1, `pulldown` drives 0.
    one: bool,
    strength: Strength = .pull,
    main_tok: u32 = 0,
};

/// A.3.4's switch types (IEEE 1364-2005 §7.6/§7.7): the MOS and CMOS switches
/// pass their input one way, the pass switches conduct both ways; an `r`
/// prefix is the resistive variant (§7.12's strength reduction).
pub const SwitchKind = enum(u8) { cmos, rcmos, nmos, pmos, rnmos, rpmos, tran, rtran, tranif0, tranif1, rtranif0, rtranif1 };

/// A.3.1 one switch instance: its terminals in source order (output, input,
/// control(s) for a MOS/CMOS switch; the two inout terminals, then the
/// enable, for a pass switch). Only a digital parse records one.
pub const SwitchInst = struct {
    kind: SwitchKind,
    terms: []const ExprId,
    delay: Delay3 = .{},
    main_tok: u32 = 0,
};

/// One port connection of a module instance. LRM §6.2.2 (A.4.1
/// ordered_port_connection / named_port_connection).
///
/// `name == .none` is the ordered form, where the row's position picks the
/// port; otherwise the `.p(expr)` form. `expr == .none` is §6.2.2's unconnected
/// port, from either a blank in an ordered list (`u(a, , b)`) or an empty
/// `.p()`; §9.19 `$port_connected` reads it.
pub const PortConn = struct {
    name: StrId = .none,
    expr: ExprId = .none,
    main_tok: u32 = 0,
};

/// One `#(...)` entry of a module instance. LRM §6.3 (A.4.1
/// list_of_parameter_assignments), both arms: `name == .none` is the ordered
/// form ("in the order of their declaration"), a name is `.p(expr)`.
pub const ParamOverride = struct {
    name: StrId = .none,
    value: ExprId = .none,
    main_tok: u32 = 0,
};

/// One `defparam` assignment. LRM §6.3.1 (A.1.4 parameter_override, A.2.4
/// defparam_assignment `hierarchical_parameter_identifier = constant_expression`).
///
/// `path` is the whole dotted left-hand side interned as one string, joined by
/// `Elaborate.sep` ('.'), so it equals the flat name elaboration gives the
/// target parameter. `value` is over parameters "declared in the same module as
/// the defparam statement" (§6.3.1), so it is cloned in the declaring module's
/// namespace.
pub const Defparam = struct {
    path: StrId,
    value: ExprId,
    /// IEEE 1364-2005 §12.2.1 a digital path's instance selects that do not
    /// fold at parse time (a genvar's, inside a loop generate block), in
    /// order: each is spelled `[]` in `path` and folded in the scope the
    /// defparam is elaborated in.
    indices: []const ExprId = &.{},
    main_tok: u32 = 0,
};

/// A module instance. LRM §6.2.2 (A.4.1 module_instantiation).
///
/// One `Instance` per `module_instance`, so `child #(2.0) a(x), b(y);` is two
/// rows sharing one `params` slice.
pub const Instance = struct {
    /// §6.2.2 module_or_paramset_identifier, resolved at elaboration because
    /// the definition may be declared after the use (A.1.2 puts no order on the
    /// descriptions of a source_text).
    module: StrId,
    name: StrId,
    /// §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`:
    /// an array of instances; `null` for a single one. Folded at elaboration.
    range: ?Dim = null,
    params: []const ParamOverride = &.{}, // §6.3
    ports: []const PortConn = &.{}, // §6.2.2
    /// A.5.4 `udp_instantiation ::= udp_identifier [ drive_strength ]
    /// [ delay2 ] udp_instance …`: a UDP instance's own brackets, which only
    /// a digital parse records (an analog one warns W0252 and keeps nothing).
    delay: Delay3 = .{},
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    main_tok: u32 = 0,
};

/// A module. LRM §6.2 (A.1.2 module_declaration). Declarations are kept in
/// typed, source-ordered slices rather than a mixed item list: lowering wants
/// them by kind, and a declaration is not a statement.
pub const ModuleDecl = struct {
    name: StrId,
    /// §6.5, in header order. This is the terminal order the host device ABI sees.
    ports: []const Port,
    /// §6.2.1 module_parameter_port_list `#(...)` followed by body parameter
    /// declarations, in source order (later defaults may reference earlier
    /// parameters, §3.4).
    params: []const ParamDecl = &.{},
    aliasparams: []const AliasParam = &.{}, // §3.4.6
    vars: []const VarDecl = &.{}, // §3.2/§3.3
    nets: []const NetDecl = &.{}, // §3.6.3
    branches: []const BranchDecl = &.{}, // §3.12
    /// §6.2.2 child instances, in source order. Elaboration flattens them away.
    instances: []const Instance = &.{},
    /// §6.3.1 `defparam`s written in this module, in source order. Elaboration
    /// applies them to the flattened parameters.
    defparams: []const Defparam = &.{},
    genvars: []const StrId = &.{}, // §3.5 (unrolling evidence, §6.6.1)
    /// §5.10.4 named events (A.2.1.3 event_declaration). Names only: an event
    /// carries no value, only a per-timepoint triggered/not flag, which lowering
    /// materializes as an ordinary integer slot in the §2.8 declaration space.
    events: []const StrId = &.{},
    /// Each `events` entry's name token: IEEE 1364-2005 §9.7.3 "An event
    /// name shall be declared explicitly before it is used."
    event_toks: []const u32 = &.{},
    functions: []const FuncDecl = &.{}, // §4.7.1
    /// §5.2 analog blocks in source order.
    analog: []const AnalogBlock = &.{},
    /// A.6.2 `initial`/`always` constructs in source order, §7.2.2's discrete
    /// context.
    discrete: []const DiscreteBlock = &.{},
    /// A.6.1 continuous assignments in source order. One entry per
    /// net_assignment, because each is a separate driver of its net
    /// (IEEE 1364-2005 §6.1).
    assigns: []const ContAssign = &.{},
    /// A.3.1 gate instantiations in source order. Separate from `assigns`
    /// because §7.8.5's value tables are not the expression operators: a gate
    /// input is a logic value, so z on one reads as x.
    gates: []const GateInst = &.{},
    /// A.3.1 pullup/pulldown sources (§7.8), in source order.
    pulls: []const PullInst = &.{},
    /// IEEE 1364-2005 §10 tasks and digital functions (see `Subroutine`);
    /// an analog parse fills the tasks only.
    tasks: []const Subroutine = &.{},
    /// A.3.1 switch instances (§7.6), filled by a digital parse only.
    switches: []const SwitchInst = &.{},
    /// A.7.2 module paths and A.7.5 system timing checks of the module's
    /// `specify` blocks (IEEE 1364 Clause 14/15, inherited through §1.1).
    /// Recorded for §11.6.15's VPI objects; no simulation applies them
    /// (W0251).
    paths: []const SpecPath = &.{},
    timing_checks: []const TimingCheck = &.{},
    /// §2.9 every `attr_spec` in this module, flattened and not attached to
    /// the item it decorated: the §2.9 and §2.9.2 rules concern the attribute
    /// alone, and nothing downstream reads its value. A.9.1 `attr_spec` has the
    /// same (name, value, token) shape as a `NatureAttr`.
    attrs: []const NatureAttr = &.{},
    /// A.1.2 the `module_keyword` was `connectmodule` (§7.6). Unlike `module`
    /// and `macromodule`, which §6.2 makes interchangeable, it matters twice:
    /// §7.6 makes a connect module something insertion places on a mixed net,
    /// never a design root, so `elaborate.pickTop` skips it; and §7.2.2 allows
    /// the discrete context in its body, so `always` there is not E0205.
    is_connect: bool = false,
    main_tok: u32 = 0,
};

/// One `(* vera_lte [= constant_expression] *)`, or the same for
/// `vera_interp` or `vera_nodiff`; see `SourceFile.lte_attrs`.
/// Exactly one of `stmt`/`expr` is set. `value == .none` is §2.9's "If a value
/// is not specifically assigned to the attribute, then its value shall be 1".
pub const LteAttr = struct {
    /// The attribute's name, which is its tag.
    kind: enum { vera_lte, vera_interp, vera_nodiff } = .vera_lte,
    stmt: StmtId = .none,
    expr: ExprId = .none,
    value: ExprId,
    main_tok: u32,
};

/// Nature attribute: `name = expr;`. LRM §3.6.1 (A.1.6 nature_attribute).
/// The LRM-defined names are `abstol` (§3.6.1.2, required for a base nature),
/// `access` (§3.6.1.4), `units` (§3.6.1.3), `idt_nature` (§3.6.1.5) and
/// `ddt_nature` (§3.6.1.6), plus user attributes (`huge`, `blowup`, …).
/// `value` may be an `.ident` (A.8.3 nature_attribute_expression allows a
/// nature or access identifier, not just a constant).
pub const NatureAttr = struct {
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,
};

/// Nature declaration. LRM §3.6.1 (A.1.6 nature_declaration).
pub const NatureDecl = struct {
    name: StrId,
    /// §3.6.1.1 derived nature: `nature x : parent`. `.none` = base nature
    /// (which then must declare `abstol` and `access`, §3.6.1).
    parent: StrId = .none,
    /// A.1.6 `parent_nature ::= ... | discipline_identifier . potential_or_flow`
    /// Set when the parent was written as `electrical.potential`.
    parent_access: ?PotentialOrFlow = null,
    attrs: []const NatureAttr = &.{},
    main_tok: u32 = 0,
};

/// Discipline declaration. LRM §3.6.2 (A.1.7 discipline_declaration).
pub const DisciplineDecl = struct {
    name: StrId,
    /// §3.6.2.1 `potential <nature>;`; `.none` for a flow-only discipline.
    potential: StrId = .none,
    /// §3.6.2.1 `flow <nature>;`; `.none` for a signal-flow discipline.
    flow: StrId = .none,
    /// §3.6.2.2 `domain continuous|discrete`.
    domain: Domain = .unspecified,
    /// §3.6.2.3 `potential.abstol = 1e-6;` style overrides.
    overrides: []const Override = &.{},
    // ponytail: no read syntax reaches these. §5.5.3's `net.potential_or_flow.attr`
    // lands on the bound nature, and the LRM gives a discipline attribute no
    // access spelling; a host reading the AST is the only consumer.
    /// §3.6.2.7 "Like natures, a discipline can specify user-defined
    /// attributes." A.1.7's discipline_item grammar omits the production; the
    /// prose governs (see `Parser.parseDiscipline`).
    attrs: []const NatureAttr = &.{},
    main_tok: u32 = 0,

    pub const Domain = enum(u8) { unspecified, continuous, discrete };
    pub const Override = struct {
        which: PotentialOrFlow,
        attr: NatureAttr,
    };
};

/// Paramset. LRM §6.4 (A.1.9 paramset_declaration).
pub const ParamsetDecl = struct {
    name: StrId,
    /// The module (or paramset) this specializes.
    target: StrId,
    params: []const ParamDecl = &.{}, // §6.4 parameter/localparam decls
    aliasparams: []const AliasParam = &.{},
    vars: []const VarDecl = &.{},
    /// `.name = expr;` assignments (A.1.9 paramset_statement).
    overrides: []const ParamsetOverride = &.{},
    /// A.1.9 also allows `analog_function_statement`s in the body.
    body: []const StmtId = &.{},
    main_tok: u32 = 0,
};

/// One A.1.9 paramset_statement `.name = expr;`.
pub const ParamsetOverride = struct {
    /// Which flavour of `.identifier` was on the left (A.1.9).
    kind: Kind,
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,

    pub const Kind = enum(u8) { module_param, output_var, system_param };
};

/// Connect specification block. LRM §7.7 (A.1.8 connectrules_declaration),
/// an A.1.2 description, so it is a sibling of the module/discipline lists on
/// `SourceFile`, not of any module item. The two item forms share the
/// `connect` keyword and split on what follows the first identifier
/// (`Parser.parseConnectRules`).
pub const ConnectRulesDecl = struct {
    name: StrId,
    /// §7.7.1 connect module auto-insertion statements, in source order.
    insertions: []const ConnectInsertion = &.{},
    /// §7.7.2 discipline resolution statements, in source order; §7.7.2.1
    /// breaks a multi-match tie by taking "the first match".
    resolutions: []const ConnectResolution = &.{},
    main_tok: u32 = 0,
};

/// `connect connectmodule_identifier [connect_mode] [#(...)] [overrides] ;`
/// LRM §7.7.1 (A.1.8 connect_insertion): names the connect module the
/// auto-insertion phase (§7.8) would place on a mixed net of the bridged
/// discipline pair.
///
/// Consumed by `ir/elaborate/insert.zig` (§7.8 insertion, analog half):
/// `mode` picks merged vs split segments (§7.7.4), `params` is passed to the
/// inserted instance (§7.7.3), and `overrides` re-types a port's discipline
/// and direction before matching (§7.7.1).
pub const ConnectInsertion = struct {
    /// §7.7.1 connectmodule_identifier, resolved at elaboration like
    /// `Instance.module`, because A.1.2 puts no order on descriptions.
    module: StrId,
    /// §7.7.4 `merged` | `split`; `.unspecified` when the source wrote none
    /// (§7.8.3 makes `merged` the default, applied by the consumer, not here).
    mode: Mode = .unspecified,
    /// §7.7.3 `#(.tt(3.5n), ...)`: the same A.4.1 parameter_value_assignment
    /// an instance carries, parsed by the same code.
    params: []const ParamOverride = &.{},
    /// §7.7.1 discipline (and optionally direction) overrides, or null when
    /// the statement ends at the parameter list.
    overrides: ?PortOverrides = null,
    main_tok: u32 = 0,

    pub const Mode = enum(u8) { unspecified, merged, split };
    /// A.1.8 connect_port_overrides: two disciplines, each optionally
    /// directed. The grammar fixes the legal direction pairings
    /// (input/output, output/input, inout/inout, or neither); the parser
    /// enforces that, so a stored pair is always one of the four productions.
    pub const PortOverrides = struct {
        a_dir: Direction = .unspecified,
        a: StrId,
        b_dir: Direction = .unspecified,
        b: StrId,
    };
};

/// `connect d1 { , dN } resolveto discipline_or_exclude ;` LRM §7.7.2 (A.1.8
/// connect_resolution): when resolution (annex F.2 step 4.b, third bullet)
/// finds more than one candidate discipline for an undeclared net and the
/// candidate set matches `disciplines`, the net is of discipline `resolved`,
/// which "need not be one of the disciplines specified in the discipline
/// list" (§7.7.2.1). With `exclude` instead, the listed disciplines "are
/// deemed to be incompatible and an error is indicated if they are found on
/// the same net" (§7.7.2).
pub const ConnectResolution = struct {
    /// The discipline list before `resolveto`, in source order.
    disciplines: []const StrId,
    /// The discipline after `resolveto`; `.none` iff `exclude`.
    resolved: StrId = .none,
    /// A.1.8 discipline_identifier_or_exclude took the `exclude` arm.
    exclude: bool = false,
    main_tok: u32 = 0,
};

// ---------------------------------------------------------------------------
// Statements: LRM ch5, A.6
// ---------------------------------------------------------------------------

/// Which of A.6.5's three procedural timing controls a prefixed statement
/// carries. All three suspend the process and then run the same body, so they
/// share `Stmt.event_control`; only what they wait for differs.
pub const Timing = enum {
    /// `@(event)`: an edge, a named event, or `@*` (§5.10, §9.7.5).
    event,
    /// `#delay` (`delay_control`); the statement's `event` is the delay.
    delay,
    /// `wait (expression)`, level sensitive: if the expression is already true
    /// the body runs without suspending at all, and a resumption re-tests it
    /// instead of firing on whichever change woke the process.
    level,
};

/// Statement node (LRM §5), a tagged union in a flat pool. Statements are
/// walked once by lowering, so the union's width is not a cache concern.
pub const Stmt = union(enum) {
    /// A.6.4 `analog_statement_or_null ::= ... | ;`
    empty,
    /// §5.3.2 named block with local declarations (A.6.3 analog_seq_block).
    block: SeqBlock,
    /// §5.7 procedural assignment (A.6.2 analog_variable_assignment). `target`
    /// is an lvalue *expression* (`.ident` or `.index`) so array element
    /// assignment (§3.2.2) is representable.
    ///
    /// `timing` is A.6.2's optional `delay_or_event_control` between the `=`
    /// and the expression: the intra-assignment form, which §8.5.3.3 gives a
    /// different meaning from the statement prefix `#5 b = a;`: the right-hand
    /// side is sampled when the statement is reached and only the write waits.
    /// `timing_is_delay` picks `delay_control` over `event_control`, as
    /// `event_control.is_delay` does for the prefix form.
    assign: struct {
        target: ExprId,
        value: ExprId,
        nonblocking: bool = false,
        timing: ExprId = .none,
        timing_is_delay: bool = false,
        /// IEEE 1364-2005 §9.7.7 `repeat ( count ) @ ...`: the event control
        /// waits for `count` occurrences; `.none` without `repeat`.
        timing_repeat: ExprId = .none,
        /// IEEE 1364-2005 §9.3 procedural continuous assignments, which only
        /// a digital parse makes: `assign`/`force` (with a `value`) and
        /// `deassign`/`release` (whose `value` is `.none`).
        continuous: ProcContinuous = .none,
    },
    /// §5.6 contribution `V(a,b) <+ expr;`. `lhs` is a `.branch_access` or
    /// `.port_access` node (A.8.5 branch_lvalue).
    contribute: struct { lhs: ExprId, rhs: ExprId },
    /// §5.6.7 indirect contribution `V(x) : I(y) == expr;`
    /// (A.6.10 indirect_contribution_statement). Parsed even where lowering
    /// rejects it, so the error names the feature instead of the syntax.
    indirect: struct { lhs: ExprId, probe: ExprId, eqn: ExprId },
    /// §5.8 conditional. `else_s` is `.none` when absent; `else if` chains
    /// nest in `else_s`.
    if_stmt: struct {
        cond: ExprId,
        then_s: StmtId,
        else_s: StmtId,
        /// Syntax 6-8 `if_generate_construct` rather than A.6.6's
        /// `analog_conditional_statement`. One node, because lowering collapses
        /// a constant condition either way; only the generate form carries
        /// §6.6's constant-expression rule (E0428).
        is_generate: bool = false,
    },
    /// §5.8.3 case (A.6.7), and Syntax 6-8 `case_generate_construct` when
    /// `is_generate`. An arm with `labels.len == 0` is `default`.
    case_stmt: struct {
        kind: CaseKind = .normal,
        scrutinee: ExprId,
        arms: []const CaseArm,
        is_generate: bool = false,
    },
    /// §5.9.2 `for (init; cond; step) body`. Also carries the genvar
    /// loop-generate form (A.4.2); lowering decides whether to unroll by
    /// looking the loop variable up in `ModuleDecl.genvars` (§6.6.1).
    for_stmt: struct { init: StmtId, cond: ExprId, step: StmtId, body: StmtId },
    /// §5.9.1 `while (cond) body`.
    while_stmt: struct { cond: ExprId, body: StmtId },
    /// §5.9 `repeat (count) body`.
    repeat_stmt: struct { count: ExprId, body: StmtId },
    /// §5.10 `@(event) body` (A.6.5 analog_event_control_statement). `event` is
    /// one of the `event_*` expression tags, or an `.ident` naming an event.
    ///
    /// `.none` is A.6.5's `@*` / `@ (*)`: the implicit event expression, whose
    /// terms are every net and variable `body` reads. A.6.5 offers it to
    /// `event_control` only, so an analog block rejects it.
    event_control: struct { event: ExprId, body: StmtId, kind: Timing = .event },
    /// §5.10.4 `-> event;` (A.6.5 `event_trigger`). `name` is a
    /// `hierarchical_event_identifier`, so only its last (and, in a flat
    /// elaboration, only) component is kept.
    event_trigger: struct { name: StrId },
    /// §5.11 `disable <block>;` (A.6.5 disable_statement).
    disable: struct { name: StrId },
    /// §5.12 / ch9 analog system task: `$strobe`, `$finish`, `$error`,
    /// `$bound_step` (§9.17.1), `$discontinuity` (§9.17.2), `$limit`
    /// (§9.17.3), and so on. `args` may contain `.none` for an omitted argument
    /// (A.6.9 permits empty argument slots).
    sys_task: struct { name: StrId, args: []const ExprId },
    /// A.6.5 jump_statement: `return` (§4.7.1 analog functions), `break`,
    /// `continue`. `value` is `.none` except for `return expr`.
    jump: struct { kind: JumpKind, value: ExprId = .none },

    pub const JumpKind = enum(u8) { ret, brk, cont };
};

/// IEEE 1364-2005 §9.3 A.6.2 `procedural_continuous_assignments`.
pub const ProcContinuous = enum(u8) { none, assign, deassign, force, release };

/// §5.8.3 A.6.7 `case`, `casex`, `casez`. Only `.normal` is meaningful for
/// real-valued analog scrutinees; `casex`/`casez` are kept so the parser can
/// accept them and lowering can diagnose them precisely.
pub const CaseKind = enum(u8) { normal, casex, casez };

/// §5.8.3 one case arm. `labels.len == 0` ⇒ `default`.
pub const CaseArm = struct {
    labels: []const ExprId,
    body: StmtId,
};

/// §6.6 the items of a generate block that the scheme brings into existence
/// with it: its named events, processes and drivers, as `ModuleDecl` holds
/// a module's. The digital engine elaborates them in the block's scope.
pub const GenItems = struct {
    /// IEEE 1364-2005 §12.4 the block's net declarations, which are its own
    /// scope's: each iteration of a loop generate declares its own.
    nets: []const NetDecl = &.{},
    events: []const StrId = &.{},
    /// As `ModuleDecl.event_toks`.
    event_toks: []const u32 = &.{},
    discrete: []const DiscreteBlock = &.{},
    assigns: []const ContAssign = &.{},
    gates: []const GateInst = &.{},
    pulls: []const PullInst = &.{},
    switches: []const SwitchInst = &.{},
    /// IEEE 1364-2005 §12.2.1 defparams, relative to the block instance.
    defparams: []const Defparam = &.{},
};

/// §5.3.2 sequential block body plus its local declarations
/// (A.6.3 analog_seq_block, A.2.8 analog_block_item_declaration).
/// Local declarations are only legal on a named block (§5.3.2).
/// Not `Block`, which is the MIR's CFG basic block.
pub const SeqBlock = struct {
    name: StrId = .none,
    /// A.6.3 `par_block ::= fork … join` (IEEE 1364-2005 §9.8.2): every
    /// statement starts when the block does, and the block ends when the
    /// last one does. Only a digital parse makes one.
    parallel: bool = false,
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    /// IEEE 1364-2005 A.2.8 a named block's `event` declarations; only a
    /// digital parse keeps one.
    events: []const StrId = &.{},
    body: []const StmtId = &.{},
    /// A generate block's module instances (§6.6). The digital engine decides a
    /// digital parse's scheme; elaboration gates an analog if-generate's
    /// (`Flatten.genInstances`).
    instances: []const Instance = &.{},
    /// A digital parse's generate block's other items (§6.6). An analog parse
    /// hoists them to the module instead (`parseGenerateBlock`).
    gen: *const GenItems = &.{},
    /// §6.6.3 a generate block's name for external interfaces: its declared
    /// name, or `genblk<n>` for an unnamed one ("n" the number of its generate
    /// construct in the enclosing scope, zero-padded past any clash). `.none`
    /// for every block that is not a generate block, and for the block §6.6.2's
    /// direct nesting does not treat as a scope. Never a name that hierarchical
    /// references resolve through: "an unnamed generate block has no name that
    /// can be used in a hierarchical name".
    gen_name: StrId = .none,
};

// ---------------------------------------------------------------------------
// User-defined primitives: LRM §8.5.3, annex A.5
// ---------------------------------------------------------------------------

/// One A.5.3 `combinational_entry` or `sequential_entry`, as the characters of
/// its columns. A.5.3's alphabets are characters: an `edge_indicator ::= (
/// level_symbol level_symbol )` is one input field that lexes as three tokens,
/// so `parseUdpEntry` concatenates each column's token text.
pub const UdpRow = struct {
    /// `level_input_list` or `seq_input_list`, validated against A.5.3's
    /// alphabets, `( )` included so an edge entry keeps its grouping.
    inputs: []const u8,
    /// `current_state ::= level_symbol`; 0 for a combinational entry, which
    /// has no such column.
    state: u8 = 0,
    /// `output_symbol ::= 0 | 1 | x | X`, or `-` for a `next_state` that holds.
    output: u8,
};

// ponytail: `UdpRow.inputs` is not split into one field per input port; the
// evaluator is where that split has a consumer, and where the per-port field
// count can be checked with a diagnostic.
/// LRM §8.5.3 / A.5.1 `udp_declaration` as validated by `parseUdpDecl`.
/// Evaluating it belongs to whatever executes the discrete cycle.
pub const UdpDecl = struct {
    name: StrId,
    /// A.5.2 `udp_port_list ::= output_port_identifier , input_port_identifier
    /// { , input_port_identifier }`, so `ports[0]` is the output and
    /// `ports[1..]` are the inputs, in the order A.5.3's input list is written
    /// in. Both A.5.1 header arms produce the same order.
    ports: []const StrId = &.{},
    /// Which A.5.3 `udp_body` alternative the table is, taken from the table
    /// itself: a `sequential_entry` is the two-colon one, and `parseUdpTable`
    /// already requires every entry to agree.
    ///
    /// Not taken from the `reg` on the output declaration. A.5.2 admits one
    /// there and A.5.3 decides the body; a UDP that writes `reg` over a
    /// combinational table is malformed, and nothing checks that yet.
    is_sequential: bool = false,
    /// A.5.3 `udp_initial_statement ::= initial output_port_identifier =
    /// init_val ;`; `.none` when the declaration carries none.
    init: ExprId = .none,
    /// The identifier the initial statement assigns (§8.1.3: the output).
    init_target: StrId = .none,
    /// The ports declared `output`, the last one's name, and whether any
    /// `reg` is declared: IEEE 1364-2005 §8.1.1 wants exactly one output,
    /// first in the list; §8.1.2 a `reg` for a sequential UDP's output and
    /// none in a combinational one. The digital engine judges them.
    outputs: u8 = 0,
    output: StrId = .none,
    has_reg: bool = false,
    rows: []const UdpRow = &.{},
    main_tok: u32 = 0,
};

/// IEEE 1364-2005 Syntax 13-1 `[library_identifier.]cell_identifier[:config]`.
pub const LibCell = struct {
    /// `.none` when omitted; the clause using it says which library that is.
    lib: StrId = .none,
    cell: StrId,
    /// The `:config` suffix (§13.1.1), which only a use clause admits.
    config: bool = false,
};

/// IEEE 1364-2005 §13.3.1 one `config_rule_statement`.
pub const ConfigRule = struct {
    select: union(enum) {
        default,
        /// §13.3.1.3 `inst_name`, interned whole (`top.a1`).
        instance: StrId,
        cell: LibCell,
    },
    expand: union(enum) {
        liblist: []const StrId,
        use: LibCell,
    },
    main_tok: u32,
};

/// IEEE 1364-2005 §13.3.1 / A.1.5 `config_declaration`.
pub const ConfigDecl = struct {
    name: StrId,
    /// §13.3.1.1 the top-level cells, in the order the statement lists them.
    design: []const LibCell,
    rules: []const ConfigRule,
    main_tok: u32,
};

// ---------------------------------------------------------------------------
// Source file: LRM §1 source_text, A.1.2
// ---------------------------------------------------------------------------

/// Root of one parsed file (LRM §1 source_text, annex A). Arena-owned; the
/// decl slices are never freed by `deinit`.
pub const SourceFile = struct {
    /// §2.8 interned identifiers and §2.7 strings.
    strings: StringInterner = .empty,
    /// annex A expression grammar, SoA.
    exprs: ExprStore = .empty,
    /// §5 statement pool; a StmtId indexes it.
    stmts: std.ArrayList(Stmt) = .empty,
    /// Token index per statement, parallel to `stmts`, kept apart so `Stmt`
    /// stays a pure union.
    stmt_toks: std.ArrayList(u32) = .empty,

    // Top-level declarations, in source order (A.1.2 description).
    modules: []const ModuleDecl = &.{}, // §6.2
    disciplines: []const DisciplineDecl = &.{}, // §3.6.2
    natures: []const NatureDecl = &.{}, // §3.6.1
    paramsets: []const ParamsetDecl = &.{}, // §6.4
    connectrules: []const ConnectRulesDecl = &.{}, // §7.7
    udps: []const UdpDecl = &.{}, // §8.5.3 / A.5.1
    configs: []const ConfigDecl = &.{}, // IEEE 1364-2005 §13.3

    /// How many leading entries of `modules` are the annex E prelude (Table E.1
    /// SPICE primitives, prepended as source by `Preprocessor.spice_primitives`)
    /// rather than the user's declarations. E.3.3 prefers a user module of the
    /// same name, so lookups search `userModules()` first; and §6.2.2's top must
    /// be a module the user wrote. Zero with `--no-std-defs`; set by the caller,
    /// not the parser, because it is a property of the compilation.
    builtin_modules: u32 = 0,

    /// How many of the last `builtin_modules` entries were synthesized from
    /// SPICE `.MODEL`/`.SUBCKT` cards (`spice_cards.synthesize`) rather than
    /// transcribed from Table E.1. E.2.1's case-insensitive match applies only
    /// to netlist names, so `elaborate.findModule` must not reach Table E.1's
    /// rows; and E.3.2's access-function substitution is for "analog
    /// primitives", which a netlist wrapper is not.
    netlist_modules: u32 = 0,

    /// VerA's vendor attributes, `vera_lte`, `vera_interp` and `vera_nodiff`
    /// (§2.9 `attribute_instance`), where one decorates an analog statement
    /// (A.6.4) or suffixes an operator call's name (A.8.2 gives that slot only
    /// to `analog_function_call`; VerA extends it). Every other attribute goes
    /// to `ModuleDecl.attrs` and is read by nothing. `vera_lte` decides which
    /// §5.6.1.2 charge sites join the host's truncation-error check
    /// (`contract.QStamp`); `vera_interp` which `absdelay` sites interpolate
    /// quadratically; `vera_nodiff` which assignments store no derivative.
    /// Few enough that a list beats a map.
    lte_attrs: std.ArrayList(LteAttr) = .empty,

    /// Returns the `kind` attribute on statement `id`, if any; the last one
    /// wins (§2.9). Linear in `lte_attrs`.
    pub fn stmtLte(self: *const SourceFile, id: StmtId, kind: @FieldType(LteAttr, "kind")) ?LteAttr {
        var out: ?LteAttr = null;
        for (self.lte_attrs.items) |a| if (a.stmt == id and a.kind == kind) {
            out = a;
        };
        return out;
    }

    /// Returns the `kind` attribute suffixed to call `id`'s name, if any.
    pub fn exprLte(self: *const SourceFile, id: ExprId, kind: @FieldType(LteAttr, "kind")) ?LteAttr {
        var out: ?LteAttr = null;
        for (self.lte_attrs.items) |a| if (a.expr == id and a.kind == kind) {
            out = a;
        };
        return out;
    }

    /// Returns `modules` minus the annex E prelude. See `builtin_modules`.
    pub fn userModules(self: *const SourceFile) []const ModuleDecl {
        return self.modules[@min(self.builtin_modules, self.modules.len)..];
    }

    /// Returns the Table E.1 rows: the prelude minus its netlist-derived tail.
    pub fn tablePrimitives(self: *const SourceFile) []const ModuleDecl {
        const end = @min(self.builtin_modules, self.modules.len);
        return self.modules[0 .. end - @min(self.netlist_modules, end)];
    }

    /// Returns the modules a SPICE netlist contributed. See `netlist_modules`.
    pub fn netlistModules(self: *const SourceFile) []const ModuleDecl {
        const end = @min(self.builtin_modules, self.modules.len);
        return self.modules[end - @min(self.netlist_modules, end) .. end];
    }

    pub const empty: SourceFile = .{};

    /// Frees the append-only stores so an AST built on a gpa is leak-free. The
    /// decl slices are not freed; they belong to the arena or caller.
    pub fn deinit(self: *SourceFile, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.exprs.deinit(gpa);
        self.stmts.deinit(gpa);
        self.stmt_toks.deinit(gpa);
        self.* = .empty;
    }

    /// Starts this file from `src`, a parse of a prefix of its source (see
    /// `parser.Seed`). Asserts `self` is empty.
    ///
    /// The strings, expressions and statements are copied with `gpa`, because
    /// later stages append to them; ids stay valid since every column is
    /// append-only. The module, discipline, nature, paramset and connectrules
    /// slices are borrowed: no later stage writes a decl, so `src` must outlive
    /// `self`.
    pub fn seedFrom(self: *SourceFile, gpa: std.mem.Allocator, src: *const SourceFile) !void {
        std.debug.assert(self.strings.strings.items.len == 0);
        std.debug.assert(self.exprs.nodes.len == 0);
        std.debug.assert(self.stmts.items.len == 0);
        self.strings.strings = try src.strings.strings.clone(gpa);
        self.strings.map = try src.strings.map.clone(gpa);
        self.exprs.nodes = try src.exprs.nodes.clone(gpa);
        self.exprs.pool = try src.exprs.pool.clone(gpa);
        self.exprs.reals = try src.exprs.reals.clone(gpa);
        self.exprs.ints = try src.exprs.ints.clone(gpa);
        for (src.exprs.logic.items) |literal| {
            var copy = literal;
            copy.planes = try gpa.dupe(u64, literal.planes);
            errdefer gpa.free(copy.planes);
            try self.exprs.logic.append(gpa, copy);
        }
        self.stmts = try src.stmts.clone(gpa);
        self.stmt_toks = try src.stmt_toks.clone(gpa);
        self.modules = src.modules;
        self.disciplines = src.disciplines;
        self.natures = src.natures;
        self.paramsets = src.paramsets;
        self.connectrules = src.connectrules;
    }

    /// Appends a statement and its token; both columns stay in lockstep.
    pub fn addStmt(self: *SourceFile, gpa: std.mem.Allocator, s: Stmt, main_tok: u32) !StmtId {
        const id: u32 = @intCast(self.stmts.items.len);
        std.debug.assert(id != @intFromEnum(StmtId.none));
        try self.stmts.ensureUnusedCapacity(gpa, 1);
        try self.stmt_toks.ensureUnusedCapacity(gpa, 1);
        self.stmts.appendAssumeCapacity(s);
        self.stmt_toks.appendAssumeCapacity(main_tok);
        return @enumFromInt(id);
    }

    /// Returns statement `id` by value, since the pool may grow during parsing.
    pub fn stmt(self: *const SourceFile, id: StmtId) Stmt {
        return self.stmts.items[@intFromEnum(id)];
    }

    /// Returns the token statement `id` is reported at.
    pub fn stmtTok(self: *const SourceFile, id: StmtId) u32 {
        return self.stmt_toks.items[@intFromEnum(id)];
    }

    /// What an expression edge of a statement is to that statement.
    pub const Edge = enum {
        /// Evaluated for its value.
        read,
        /// §5.7 an assignment target (A.6.2 `variable_lvalue`): written.
        write,
        /// §5.6 a contribution's `branch_lvalue` (A.8.5): the branch driven.
        branch,
    };

    /// Visits every edge of statement `id`: `v.expr(e, edge)` for each of its own
    /// expressions and `v.stmt(s)` for each child statement, in source order,
    /// except that an assignment's intra-assignment timing comes after its
    /// value. `.none` operands and children are passed through. `v` is
    /// duck-typed; this is the statement counterpart of `ExprStore.children`.
    pub fn stmtEdges(self: *const SourceFile, id: StmtId, v: anytype) !void {
        switch (self.stmt(id)) {
            .empty, .event_trigger, .disable => {},
            .block => |b| for (b.body) |s| try v.stmt(s),
            .assign => |a| {
                try v.expr(a.target, .write);
                try v.expr(a.value, .read);
                try v.expr(a.timing, .read);
            },
            .contribute => |c| {
                try v.expr(c.lhs, .branch);
                try v.expr(c.rhs, .read);
            },
            .indirect => |c| {
                try v.expr(c.lhs, .branch);
                try v.expr(c.probe, .read);
                try v.expr(c.eqn, .read);
            },
            .if_stmt => |s| {
                try v.expr(s.cond, .read);
                try v.stmt(s.then_s);
                try v.stmt(s.else_s);
            },
            .case_stmt => |s| {
                try v.expr(s.scrutinee, .read);
                for (s.arms) |arm| {
                    for (arm.labels) |l| try v.expr(l, .read);
                    try v.stmt(arm.body);
                }
            },
            .for_stmt => |s| {
                try v.stmt(s.init);
                try v.expr(s.cond, .read);
                try v.stmt(s.step);
                try v.stmt(s.body);
            },
            .while_stmt => |s| {
                try v.expr(s.cond, .read);
                try v.stmt(s.body);
            },
            .repeat_stmt => |s| {
                try v.expr(s.count, .read);
                try v.stmt(s.body);
            },
            .event_control => |s| {
                try v.expr(s.event, .read);
                try v.stmt(s.body);
            },
            .sys_task => |s| for (s.args) |a| try v.expr(a, .read),
            .jump => |j| try v.expr(j.value, .read),
        }
    }

    /// Appends to `out`, in source order, every lvalue statement `id` writes
    /// through its own expressions. Child statements are not entered; callers
    /// walk them with their own scope rules. `funcs` is the enclosing module's
    /// §4.7.1 function list, which decides an actual's direction.
    ///
    /// The ways a statement writes a variable:
    ///   - §5.7 the assignment target;
    ///   - §4.7.2.3/§4.7.2.4 an actual bound to an `output` or `inout` formal
    ///     ("the last value assigned to the output argument is then assigned to
    ///     the corresponding analog variable reference");
    ///   - §9.13.1/§9.13.2 the seed of `$random`, `$arandom`, `$dist_*` and
    ///     `$rdist_*` ("If the random_seed argument is specified it is an inout
    ///     argument");
    ///   - §9.5.3/§9.5.4 the destinations of `$sscanf`, `$fscanf`, `$fgets`,
    ///     `$ferror`, and the string `$swrite`/`$sformat` write into.
    /// An array actual written as an A.8.1 assignment pattern (§4.7.2.3 "an
    /// array assignment pattern of analog variables") yields its elements.
    /// The appended ids are the lvalues as written (`x[i]` stays `x[i]`); see
    /// `lvalueBase` for the declaration it names.
    pub fn stmtWrites(self: *const SourceFile, funcs: []const FuncDecl, id: StmtId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) !void {
        if (id == .none) return;
        if (self.stmt(id) == .sys_task) {
            const s = self.stmt(id).sys_task;
            for (sysWrites(self.str(s.name), s.args)) |w| try self.addLvalue(w, gpa, out);
        }
        const Writes = struct {
            file: *const SourceFile,
            funcs: []const FuncDecl,
            gpa: std.mem.Allocator,
            out: *std.ArrayList(ExprId),
            pub fn expr(w: @This(), e: ExprId, edge: Edge) std.mem.Allocator.Error!void {
                switch (edge) {
                    .write => try w.file.addLvalue(e, w.gpa, w.out),
                    .read => try w.file.exprWrites(w.funcs, e, w.gpa, w.out),
                    // A branch is driven, not a variable written.
                    .branch => {},
                }
            }
            pub fn stmt(_: @This(), _: StmtId) std.mem.Allocator.Error!void {}
        };
        try self.stmtEdges(id, Writes{ .file = self, .funcs = funcs, .gpa = gpa, .out = out });
    }

    /// The expression half of `stmtWrites`.
    fn exprWrites(self: *const SourceFile, funcs: []const FuncDecl, e: ExprId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) std.mem.Allocator.Error!void {
        if (e == .none) return;
        const ex = &self.exprs;
        switch (ex.tag(e)) {
            // §4.4 a probe's operands are net and branch references, which no
            // expression writes.
            .branch_access, .port_access => return,
            .call => {
                const args = ex.args(e);
                for (funcs) |fd| {
                    if (fd.name != ex.strOf(e)) continue;
                    for (fd.args, 0..) |formal, i| {
                        if (i >= args.len) break;
                        switch (formal.direction) {
                            .output, .inout => try self.addLvalue(args[i], gpa, out),
                            .input, .unspecified => {},
                        }
                    }
                    break;
                }
            },
            .sys_call => for (sysWrites(self.str(ex.strOf(e)), ex.args(e))) |w| try self.addLvalue(w, gpa, out),
            else => {}, // else: every other tag writes only through its children
        }
        var buf: [3]ExprId = undefined;
        for (ex.children(e, &buf)) |c| try self.exprWrites(funcs, c, gpa, out);
    }

    fn addLvalue(self: *const SourceFile, e: ExprId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) std.mem.Allocator.Error!void {
        if (e == .none) return;
        if (self.exprs.tag(e) == .assign_pattern) {
            for (self.exprs.args(e)) |el| try self.addLvalue(el, gpa, out);
            return;
        }
        try out.append(gpa, e);
    }

    /// The arguments of system function or task `name` that it writes through.
    /// The positions are the syntax boxes': Syntax 9-8/9-9 put the seed first,
    /// §9.5.3/§9.5.4.2 put the destinations after the source and format, and
    /// §9.5.4.1/§9.5.7 put `$fgets`'s string first and `$ferror`'s second.
    fn sysWrites(name: []const u8, args: []const ExprId) []const ExprId {
        const eq = std.mem.eql;
        const first = args[0..@min(1, args.len)];
        // §9.13 Table 9-10: all 17 names match one of these four spellings.
        if (eq(u8, name, "$random") or eq(u8, name, "$arandom") or
            std.mem.startsWith(u8, name, "$dist_") or std.mem.startsWith(u8, name, "$rdist_")) return first;
        if (eq(u8, name, "$sscanf") or eq(u8, name, "$fscanf")) return args[@min(2, args.len)..];
        if (eq(u8, name, "$ferror")) return args[@min(1, args.len)..];
        // IEEE 1364 §17.10.2 `$value$plusargs(user_string, variable)`.
        if (eq(u8, name, "$value$plusargs")) return args[@min(1, args.len)..@min(2, args.len)];
        if (eq(u8, name, "$fgets") or eq(u8, name, "$swrite") or eq(u8, name, "$sformat")) return first;
        return &.{};
    }

    /// Returns the declared name an lvalue writes: `x`, `x[i]`, `x[i][j]` and a part
    /// select `x[3:0]` (an `.index` whose index is a `.range`) all write the
    /// declaration `x`. `.none` when the lvalue is not rooted in a plain
    /// identifier.
    pub fn lvalueBase(self: *const SourceFile, e: ExprId) ExprId {
        var t = e;
        while (t != .none and self.exprs.tag(t) == .index) t = self.exprs.lhs(t);
        if (t == .none or self.exprs.tag(t) != .ident) return .none;
        return t;
    }

    /// Returns the interned name `id`; asserts `id != .none`.
    pub fn str(self: *const SourceFile, id: StrId) []const u8 {
        return self.strings.get(id);
    }

    /// Interns `s`, which is borrowed and must outlive the file.
    pub fn intern(self: *SourceFile, gpa: std.mem.Allocator, s: []const u8) !StrId {
        return self.strings.intern(gpa, s);
    }

    /// Returns the value expression a (possibly derived) nature gives `attr`, or
    /// null (§3.6.1.1). A derived nature overrides its base, so the first hit
    /// walking up the parent chain wins; the walk stops after 16 hops.
    /// Lowering and elaboration both call it.
    pub fn natureAttrExpr(self: *const SourceFile, name: StrId, attr: []const u8) ?ExprId {
        var want = name;
        var hops: u32 = 0;
        while (hops < 16) : (hops += 1) {
            const nat = for (self.natures) |*n| {
                if (n.name == want) break n;
            } else return null;
            for (nat.attrs) |a| {
                if (std.mem.eql(u8, self.str(a.name), attr)) return a.value;
            }
            if (nat.parent == .none) return null;
            // A.1.6 `parent_nature ::= nature_identifier | discipline_identifier
            // . potential_or_flow`. In the second form the parent names a
            // discipline, so the walk continues at whichever nature that
            // discipline binds to the named half (§3.6.2.6).
            if (nat.parent_access) |half| {
                const d = for (self.disciplines) |*x| {
                    if (x.name == nat.parent) break x;
                } else return null;
                const bound = switch (half) {
                    .potential => d.potential,
                    .flow => d.flow,
                };
                if (bound == .none) return null;
                want = bound;
                continue;
            }
            want = nat.parent;
        }
        return null;
    }

    fn addExpr(self: *SourceFile, gpa: std.mem.Allocator, node: Node) !ExprId {
        return self.exprs.add(gpa, node);
    }
};

// ponytail: not modelled, because nothing would produce or consume the tag:
//   · `min:typ:max` (A.8.3 mintypmax_expression); the parser keeps the typ
//     value. Add a `.mintypmax` tag if a fixture needs the triple.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

    const sum = try f.addExpr(gpa, .{
        .tag = .binary,
        .main_tok = 2,
        .lhs = one,
        .rhs = two_pt_5,
        .extra = @intFromEnum(BinaryOp.add),
    });
    try std.testing.expectEqual(BinaryOp.add, f.exprs.binOp(sum));
    try std.testing.expectEqual(one, f.exprs.lhs(sum));

    // `V(a)`: §4.4.1 branch access.
    const node_a = try f.addExpr(gpa, .{ .tag = .ident, .main_tok = 3, .str = a });
    const probe = try f.addExpr(gpa, .{ .tag = .branch_access, .main_tok = 4, .lhs = node_a, .str = v });
    try std.testing.expectEqual(ExprId.none, f.exprs.rhs(probe));

    // §4.3 call with an argument list in the shared pool.
    const off = try f.exprs.addExprList(gpa, &.{ sum, probe });
    const call = try f.addExpr(gpa, .{ .tag = .builtin_call, .main_tok = 5, .extra = off, .str = try f.intern(gpa, "pow") });
    try std.testing.expectEqualSlices(ExprId, &.{ sum, probe }, f.exprs.args(call));

    // §4.2.12 ternary keeps its third operand in `extra`.
    const t = try f.addExpr(gpa, .{ .tag = .ternary, .lhs = probe, .rhs = one, .extra = @intFromEnum(two_pt_5) });
    try std.testing.expectEqual(two_pt_5, f.exprs.ternaryElse(t));
}

test "ParamDecl carries §3.4.2 ranges through to lowering" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    // parameter real r = 1k from (0:inf);
    const zero = try f.exprs.addInt(gpa, 0, 0);
    const inf = try f.addExpr(gpa, .{ .tag = .pos_inf, .main_tok = 1 });
    const dflt = try f.exprs.addReal(gpa, 2, 1000.0);
    const ranges = [_]ValueRange{.{
        .kind = .from,
        .lo = zero,
        .hi = inf,
        .lo_inclusive = false,
        .hi_inclusive = false,
    }};
    const p: ParamDecl = .{
        .name = try f.intern(gpa, "r"),
        .ty = .real,
        .default = dflt,
        .ranges = &ranges,
    };
    try std.testing.expectEqual(@as(usize, 1), p.ranges.len);
    try std.testing.expectEqual(ExprTag.pos_inf, f.exprs.tag(p.ranges[0].hi));
    try std.testing.expect(!p.ranges[0].lo_inclusive);
}

test "statement pool keeps handles and token column in lockstep" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const lhs = try f.addExpr(gpa, .{ .tag = .branch_access, .str = try f.intern(gpa, "I") });
    const rhs = try f.exprs.addInt(gpa, 0, 0);
    const s0 = try f.addStmt(gpa, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, 7);
    const s1 = try f.addStmt(gpa, .empty, 9);
    const blk = try f.addStmt(gpa, .{ .block = .{ .body = &.{ s0, s1 } } }, 6);

    try std.testing.expectEqual(@as(u32, 7), f.stmtTok(s0));
    try std.testing.expectEqual(@as(u32, 6), f.stmtTok(blk));
    switch (f.stmt(blk)) {
        .block => |b| try std.testing.expectEqual(@as(usize, 2), b.body.len),
        else => return error.WrongTag,
    }
    switch (f.stmt(s0)) {
        .contribute => |c| try std.testing.expectEqual(lhs, c.lhs),
        else => return error.WrongTag,
    }
}
