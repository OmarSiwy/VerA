//! The AST the parser builds from the token stream (LRM annex A, ch3 declarations).
//! Expressions are SoA rows addressed by `ExprId`, statements a flat pool addressed
//! by `StmtId`, names interned as `StrId`; variable-arity payloads share one `u32`
//! pool. Every store is append-only, so the same tokens give the same ids. Lists are
//! unmanaged and meant for the compilation arena; `deinit` exists so tests can use a
//! gpa. Interned slices are borrowed and must outlive the `SourceFile`.
//!
//! This file holds the handles, the string table and `SourceFile`, the root
//! that owns every store. The row types live by table: expressions in
//! ast_expr.zig, declarations in ast_decl.zig, statements and their walks in
//! ast_stmt.zig; the aliases below are their API.

const std = @import("std");
const expr_file = @import("ast_expr.zig");
const decl_file = @import("ast_decl.zig");
const stmt_file = @import("ast_stmt.zig");

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

// Expressions: LRM §4.2-§4.6, A.8 (ast_expr.zig).
pub const UnaryOp = expr_file.UnaryOp;
pub const BinaryOp = expr_file.BinaryOp;
pub const branch_ref_hier_unnamed = expr_file.branch_ref_hier_unnamed;
pub const ExprTag = expr_file.ExprTag;
pub const Node = expr_file.Node;
pub const ExprStore = expr_file.ExprStore;

// Declarations: LRM ch3, §4.7, ch6, §7.7, A.5, IEEE 1364-2005 §13.3 (ast_decl.zig).
pub const Dim = decl_file.Dim;
pub const ValueRange = decl_file.ValueRange;
pub const ParamDecl = decl_file.ParamDecl;
pub const AliasParam = decl_file.AliasParam;
pub const VarDecl = decl_file.VarDecl;
pub const NetKind = decl_file.NetKind;
pub const Strength = decl_file.Strength;
pub const NetStrength = decl_file.NetStrength;
pub const Delay3 = decl_file.Delay3;
pub const NetDecl = decl_file.NetDecl;
pub const BranchDecl = decl_file.BranchDecl;
pub const Port = decl_file.Port;
pub const FuncArg = decl_file.FuncArg;
pub const Subroutine = decl_file.Subroutine;
pub const EventDecl = decl_file.EventDecl;
pub const TfPort = decl_file.TfPort;
pub const FuncDecl = decl_file.FuncDecl;
pub const AnalogBlock = decl_file.AnalogBlock;
pub const DiscreteBlock = decl_file.DiscreteBlock;
pub const ContAssign = decl_file.ContAssign;
pub const GateKind = decl_file.GateKind;
pub const GateInst = decl_file.GateInst;
pub const SpecEdge = decl_file.SpecEdge;
pub const SpecPolarity = decl_file.SpecPolarity;
pub const SpecPath = decl_file.SpecPath;
pub const TimingCheck = decl_file.TimingCheck;
pub const PullInst = decl_file.PullInst;
pub const SwitchKind = decl_file.SwitchKind;
pub const SwitchInst = decl_file.SwitchInst;
pub const PortConn = decl_file.PortConn;
pub const ParamOverride = decl_file.ParamOverride;
pub const Defparam = decl_file.Defparam;
pub const Instance = decl_file.Instance;
pub const ModuleDecl = decl_file.ModuleDecl;
pub const LteAttr = decl_file.LteAttr;
pub const NatureAttr = decl_file.NatureAttr;
pub const AttributeOwner = decl_file.AttributeOwner;
pub const AttributeBinding = decl_file.AttributeBinding;
pub const NatureDecl = decl_file.NatureDecl;
pub const DisciplineDecl = decl_file.DisciplineDecl;
pub const ParamsetDecl = decl_file.ParamsetDecl;
pub const ParamsetOverride = decl_file.ParamsetOverride;
pub const ConnectRulesDecl = decl_file.ConnectRulesDecl;
pub const ConnectInsertion = decl_file.ConnectInsertion;
pub const ConnectResolution = decl_file.ConnectResolution;
pub const UdpRow = decl_file.UdpRow;
pub const UdpDecl = decl_file.UdpDecl;
pub const LibCell = decl_file.LibCell;
pub const ConfigRule = decl_file.ConfigRule;
pub const ConfigDecl = decl_file.ConfigDecl;

// Statements: LRM ch5, A.6 (ast_stmt.zig).
pub const Stmt = stmt_file.Stmt;
pub const StmtRow = stmt_file.StmtRow;
pub const BlockId = stmt_file.BlockId;
pub const ProcContinuous = stmt_file.ProcContinuous;
pub const CaseKind = stmt_file.CaseKind;
pub const CaseArm = stmt_file.CaseArm;
pub const GenItems = stmt_file.GenItems;
pub const SeqBlock = stmt_file.SeqBlock;

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
    /// The text of each id, indexed by `StrId`.
    strings: std.ArrayList([]const u8) = .empty,
    /// The set of ids, hashed by their text. The key is the 4-byte id, not
    /// the 16-byte slice `strings` already holds: 5 bytes a slot instead of
    /// 21 (3,640 names in 8,192 slots on psp103, in both the AST's table and
    /// the MIR's).
    map: std.HashMapUnmanaged(StrId, void, IdContext, std.hash_map.default_max_load_percentage) = .empty,

    /// Hashes an id by its text, for the map's own rehashing.
    const IdContext = struct {
        strings: []const []const u8,
        pub fn hash(c: IdContext, id: StrId) u64 {
            return std.hash_map.hashString(c.strings[@backingInt(id)]);
        }
        pub fn eql(_: IdContext, a: StrId, b: StrId) bool {
            return a == b;
        }
    };

    /// Looks a text up among the ids without interning it.
    const TextAdapter = struct {
        strings: []const []const u8,
        pub fn hash(_: TextAdapter, s: []const u8) u64 {
            return std.hash_map.hashString(s);
        }
        pub fn eql(a: TextAdapter, s: []const u8, id: StrId) bool {
            return std.mem.eql(u8, s, a.strings[@backingInt(id)]);
        }
    };

    pub const empty: StringInterner = .{};

    /// Frees both tables; the interned slices are borrowed and left alone.
    pub fn deinit(self: *StringInterner, gpa: std.mem.Allocator) void {
        self.strings.deinit(gpa);
        self.map.deinit(gpa);
        self.* = .empty;
    }

    /// Returns the id for `s`, adding it if new. `s` is borrowed and must
    /// outlive the table. On OOM the table is unchanged.
    pub fn intern(self: *StringInterner, gpa: std.mem.Allocator, s: []const u8) !StrId {
        // Room for the text first, so a failed append can never leave the
        // map holding an id with no string.
        try self.strings.ensureUnusedCapacity(gpa, 1);
        const items = self.strings.items;
        const gop = try self.map.getOrPutContextAdapted(gpa, s, TextAdapter{ .strings = items }, .{ .strings = items });
        if (gop.found_existing) return gop.key_ptr.*;
        const id: StrId = @fromBackingInt(@intCast(@as(u32, @intCast(items.len))));
        gop.key_ptr.* = id;
        self.strings.appendAssumeCapacity(s);
        return id;
    }

    /// Returns the string for `id`; asserts `id != .none`.
    pub fn get(self: *const StringInterner, id: StrId) []const u8 {
        std.debug.assert(id != .none);
        return self.strings.items[@backingInt(id)];
    }

    /// Returns the id for `s` without inserting it.
    pub fn find(self: *const StringInterner, s: []const u8) ?StrId {
        return self.map.getKeyAdapted(s, TextAdapter{ .strings = self.strings.items });
    }

    /// Returns a copy whose tables are `gpa`'s; the interned slices stay
    /// borrowed. Caller owns the copy and frees it with `deinit(gpa)`.
    pub fn clone(self: *const StringInterner, gpa: std.mem.Allocator) !StringInterner {
        var strings = try self.strings.clone(gpa);
        errdefer strings.deinit(gpa);
        return .{ .strings = strings, .map = try self.map.cloneContext(gpa, IdContext{ .strings = self.strings.items }) };
    }

    /// Returns whether `id` names `s`; false for `.none`.
    pub fn eql(self: *const StringInterner, id: StrId, s: []const u8) bool {
        return id != .none and std.mem.eql(u8, self.get(id), s);
    }
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
    /// §5 statement pool; a StmtId indexes it. Read through `stmt`.
    stmts: std.ArrayList(StmtRow) = .empty,
    /// The `SeqBlock` of every `.block` row, in statement order; a row's
    /// `BlockId` indexes it.
    blocks: std.ArrayList(SeqBlock) = .empty,
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
    /// E.1.2 bullet 2: the netlist's `.MODEL` cards whose type names a
    /// primitive VerA does not support, as lower-case `name type`. They
    /// declare no module; elaboration refuses an instance of one (E0952).
    netlist_unsupported: []const []const u8 = &.{},

    /// VerA's vendor attributes, `vera_lte`, `vera_interp`, `vera_nodiff` and
    /// `vera_timepoint` (§2.9 `attribute_instance`), where one decorates an analog statement
    /// (A.6.4) or suffixes an operator call's name (A.8.2 gives that slot only
    /// to `analog_function_call`; VerA extends it). All attributes also keep
    /// their parsed owners below and remain in `ModuleDecl.attrs` for
    /// constant-expression validation. `vera_lte` decides which
    /// §5.6.1.2 charge sites join the host's truncation-error check
    /// (`contract.QStamp`); `vera_interp` which `absdelay` sites interpolate
    /// quadratically; `vera_nodiff` which assignments store no derivative;
    /// `vera_timepoint` which statements run once per timepoint.
    /// Few enough that a list beats a map.
    lte_attrs: std.ArrayList(LteAttr) = .empty,
    /// Every source attribute, including vendor attributes, with its owner.
    attributes: std.ArrayList(AttributeBinding) = .empty,

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
        self.blocks.deinit(gpa);
        self.stmt_toks.deinit(gpa);
        self.attributes.deinit(gpa);
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
        self.strings = try src.strings.clone(gpa);
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
        self.blocks = try src.blocks.clone(gpa);
        self.stmt_toks = try src.stmt_toks.clone(gpa);
        // Attribute specs are immutable borrowed declaration data; owner
        // rows are copied because a resumed parser appends/reclassifies them.
        self.attributes = try src.attributes.clone(gpa);
        self.modules = src.modules;
        self.disciplines = src.disciplines;
        self.natures = src.natures;
        self.paramsets = src.paramsets;
        self.connectrules = src.connectrules;
    }

    /// Appends a statement and its token; both columns stay in lockstep, and a
    /// `.block`'s `SeqBlock` goes to `blocks`. On OOM nothing is appended.
    pub fn addStmt(self: *SourceFile, gpa: std.mem.Allocator, s: Stmt, main_tok: u32) !StmtId {
        const id: u32 = @intCast(self.stmts.items.len);
        std.debug.assert(id != @backingInt(StmtId.none));
        try self.stmts.ensureUnusedCapacity(gpa, 1);
        try self.stmt_toks.ensureUnusedCapacity(gpa, 1);
        if (s == .block) try self.blocks.ensureUnusedCapacity(gpa, 1);
        self.stmts.appendAssumeCapacity(switch (s) {
            .block => |b| blk: {
                self.blocks.appendAssumeCapacity(b);
                break :blk .{ .block = @fromBackingInt(@intCast(self.blocks.items.len - 1)) };
            },
            inline else => |payload, tag| @unionInit(StmtRow, @tagName(tag), payload), // else: every other arm is stored as it is
        });
        self.stmt_toks.appendAssumeCapacity(main_tok);
        return @fromBackingInt(@intCast(id));
    }

    /// Returns statement `id` by value, since the pool may grow during parsing.
    pub fn stmt(self: *const SourceFile, id: StmtId) Stmt {
        return switch (self.stmts.items[@backingInt(id)]) {
            .block => |b| .{ .block = self.blocks.items[@backingInt(b)] },
            inline else => |payload, tag| @unionInit(Stmt, @tagName(tag), payload), // else: every other arm is stored as it is
        };
    }

    /// Returns the token statement `id` is reported at.
    pub fn stmtTok(self: *const SourceFile, id: StmtId) u32 {
        return self.stmt_toks.items[@backingInt(id)];
    }

    /// Returns the §5.3.2 block statement `id` for in-place editing (the
    /// parser names a generate block after the fact, §6.6.3). Asserts `id`
    /// is a `.block`. Invalidated by the next `addStmt`.
    pub fn seqBlockMut(self: *SourceFile, id: StmtId) *SeqBlock {
        return &self.blocks.items[@backingInt(self.stmts.items[@backingInt(id)].block)];
    }

    /// Returns an iterator over every §5.3.2 block statement in the pool, in
    /// statement order, for a pass that wants every block's declarations.
    pub fn seqBlocks(self: *const SourceFile) SeqBlockIterator {
        return .{ .blocks = self.blocks.items };
    }

    /// See `seqBlocks`. Valid until the next `addStmt`.
    pub const SeqBlockIterator = struct {
        blocks: []const SeqBlock,
        i: u32 = 0,

        /// Returns the next block, or null after the last.
        pub fn next(it: *SeqBlockIterator) ?*const SeqBlock {
            if (it.i == it.blocks.len) return null;
            defer it.i += 1;
            return &it.blocks[it.i];
        }
    };

    // The statement walks (ast_stmt.zig) and the nature walk (ast_decl.zig),
    // callable as methods.
    pub const Edge = stmt_file.Edge;
    pub const stmtEdges = stmt_file.stmtEdges;
    pub const stmtWrites = stmt_file.stmtWrites;
    pub const lvalueBase = stmt_file.lvalueBase;

    /// Returns the interned name `id`; asserts `id != .none`.
    pub fn str(self: *const SourceFile, id: StrId) []const u8 {
        return self.strings.get(id);
    }

    /// Interns `s`, which is borrowed and must outlive the file.
    pub fn intern(self: *SourceFile, gpa: std.mem.Allocator, s: []const u8) !StrId {
        return self.strings.intern(gpa, s);
    }

    pub const natureAttrExpr = decl_file.natureAttrExpr;
};

test {
    _ = expr_file;
    _ = decl_file;
    _ = stmt_file;
}
