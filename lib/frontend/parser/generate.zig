//! Annex A.4.2 generate constructs (LRM §6.6).
//!
//! In: generate regions, loop and conditional generates. Out: an `Ast.AnalogBlock` whose body
//! is the `for`/`if`, which lowering unrolls (§6.6.1).
//!
//! LRM clauses this file's code cites: §2.8, §3.4.6, §3.5, §5.2.1, §5.9.2, §5.10.4, §6.5, §6.6, §6.6.1, §6.6.2, §6.6.3, §6.8, §6.9.1, §12.4.2.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_generate.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.4.2 generate constructs — LRM §6.6
//
// A generate construct is turned into ONE `Ast.AnalogBlock` whose body is
// the `for`/`if` statement, with the generated blocks spliced in as
// statements. That is not a shortcut around elaboration, it is where
// elaboration already lives: `Lower.tryUnrollFor` unrolls a genvar `for` at
// compile time with the genvar bound as a constant for the duration of each
// copy — §6.6.1's implicit localparam, "whose value is the genvar value at
// the time the instance was elaborated" — and a constant `if` is folded the
// same way. §6.9.1 is what makes the splice faithful rather than merely
// convenient: every analog block in a module is concatenated in source
// order anyway, and unrolling order is source order, so a generated block
// occupies exactly the slot it would have occupied written out by hand.
// -----------------------------------------------------------------------

/// Enter/leave one generate CONSTRUCT. `gen_construct` is bumped only on the
/// outermost one, and that is what makes §6.6.2's two naming rules one test:
/// "it is permissible for more than one block within a single conditional
/// generate construct to have the same name (since at most one is
/// instantiated)" — those arms share the id — while "named generate blocks
/// may not have the same name as blocks in any other generate construct in
/// the same scope" gets a different one. §6.6.2's direct-nesting exception
/// falls out too: an `else if` chain is an if_generate_construct nested in
/// the outer construct's block, so it inherits the id rather than starting
/// a new one.
pub fn parseGenerate(self: *Parser, b: *parse_module.Body, comptime kind: token.Tag) Error!void {
    if (self.gen_construct_depth == 0) self.gen_construct += 1;
    b.gen_count += 1; // §6.6.3 this construct's number in its scope
    self.gen_construct_depth += 1;
    self.gen_depth += 1;
    defer {
        self.gen_construct_depth -= 1;
        self.gen_depth -= 1;
    }
    const tok = self.pos;
    const s = switch (kind) {
        .kw_for => try parseFor(self, b, tok),
        .kw_if => try parseIf(self, b, tok),
        .kw_case => try parse_stmt.parseCase(self, .normal, b),
        else => unreachable, // else: the caller dispatched on exactly these three
    };
    try b.analog.append(self.arena, .{ .body = s, .main_tok = tok });
}

/// Syntax 6-8 `loop_generate_construct ::= for ( genvar_initialization ;
/// genvar_expression ; genvar_iteration ) generate_block`.
///
/// The three parts are the same shape as §5.9.2's `for`, and the same node
/// carries them: lowering tells the two apart by looking the loop variable
/// up in `ModuleDecl.genvars` (§3.5), not by which parser produced it. That
/// is also why the non-constant scheme diagnostics (E0417 init, E0418
/// condition, E0419 iteration, E0420 non-terminating) need nothing here —
/// and why the §6.6 scheme rule the if/case forms carry (E0428) does not
/// apply to this node: for a `for` it is those four codes instead.
/// `gen` is either a module Body pointer or comptime null for a statement.
/// Inline specialization shares the grammar without a runtime dispatch.
pub inline fn parseFor(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
    self.pos += 1; // 'for'
    _ = try self.expect(.lparen);
    // A.4.2 `genvar_initialization ::= genvar_identifier = constant_expression`:
    // checked against the module's genvars by `checkGenBlockNames`.
    if (@TypeOf(gen) != @TypeOf(null) and self.identLike(self.pos))
        try gen.gen_loops.append(self.arena, .{ .name = try self.internTok(self.pos), .tok = self.pos, .construct = self.gen_construct });
    const init_s = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.semicolon);
    const cond = try parse_expr.parseExpr(self);
    _ = try self.expect(.semicolon);
    const step = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.rparen);
    if (@TypeOf(gen) != @TypeOf(null)) self.gen_loop_body = true;
    const body = if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen);
    return self.file.addStmt(self.arena, .{ .for_stmt = .{
        .init = init_s,
        .cond = cond,
        .step = step,
        .body = body,
    } }, tok);
}

/// Syntax 6-8 `if_generate_construct ::= if ( constant_expression )
/// generate_block [ else generate_block ]`.
///
/// `else if` needs no arm of its own: an if_generate_construct is itself a
/// module_or_generate_item, so the chain is a one-item generate_block in
/// the `else`, which `parseGenerateBlock` reaches through `parseModuleItem`.
pub inline fn parseIf(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
    self.pos += 1; // 'if'
    _ = try self.expect(.lparen);
    const cond = try parse_expr.parseExpr(self);
    _ = try self.expect(.rparen);
    const then_s = if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen);
    const else_s: Ast.StmtId = if (self.eat(.kw_else))
        if (@TypeOf(gen) == @TypeOf(null)) try parse_stmt.parseStmt(self) else try parseGenerateBlock(self, gen)
    else
        .none;
    return self.file.addStmt(
        self.arena,
        .{
            .if_stmt = .{
                .cond = cond,
                .then_s = then_s,
                .else_s = else_s,
                // §6.6's "all expressions in generate schemes shall be constant
                // expressions" is judged in lowering (E0428), which is the only
                // stage that can evaluate one.
                .is_generate = @TypeOf(gen) != @TypeOf(null),
            },
        },
        tok,
    );
}

/// Syntax 6-8 `generate_block ::= module_or_generate_item | begin
/// [ : generate_block_identifier ] { module_or_generate_item } end`.
///
/// The items are collected into a scratch `Body` and then split by what
/// scope they belong to. §6.6 gives the block its own scope, so its
/// parameters and variables become the `SeqBlock`'s — which is also what
/// the old statement-shaped parse produced, so nothing that already
/// depended on them moves. Everything else (nets, branches, genvars,
/// analog functions) is hoisted to the module.
///
/// ponytail: hoisting is right for a conditional generate, which elaborates
/// at most once, and short of the LRM for a loop generate, which should get
/// one renamed copy of each declaration per iteration (§6.6.1 names them
/// `blk[0].n`). No fixture declares a net inside a loop; the day one does,
/// the copies have to be made in `Lower.tryUnrollFor` where the trip count
/// is known, not here where it is not.
pub fn parseGenerateBlock(self: *Parser, b: *parse_module.Body) Error!Ast.StmtId {
    try self.enter();
    defer self.depth -= 1;
    const tok = self.pos;
    const loop_body = self.gen_loop_body;
    self.gen_loop_body = false;
    // A.4.2 has no null generate_block, but `if (c) ;` is what a model
    // writes for a deliberately empty arm and refusing it would only move
    // the error off the rule the source actually breaks.
    if (self.eat(.semicolon)) return self.file.addStmt(self.arena, .empty, tok);

    var blk: Ast.SeqBlock = .{};
    var gb: parse_module.Body = .{};
    // §6.6.2 direct nesting (IEEE 1364-2005 §12.4.2): a generate block that is
    // one conditional generate construct with no begin/end "is not treated as a
    // separate scope", and its construct's blocks are named as the enclosing
    // construct's (§6.6.3) — so the inner construct takes the outer number.
    var direct = false;
    if (self.eat(.kw_begin)) {
        if (self.eat(.colon)) {
            const name_tok = self.pos;
            blk.name = try self.expectIdent();
            // §6.6.1: "If the generate block is named, IT IS A DECLARATION
            // OF AN ARRAY of generate block instances"; §6.6.2: "its name
            // declares a generate block instance and is the name for the
            // scope it creates". Either way the identifier lands in the
            // ENCLOSING scope, and `checkGenBlockNames` is what enforces it.
            try b.gen_blocks.append(self.arena, .{
                .name = blk.name,
                .tok = name_tok,
                .construct = self.gen_construct,
            });
        }
        while (self.peek() != .kw_end and self.peek() != .eof) {
            try self.skipAttributes();
            if (self.peek() == .kw_end) break;
            const before = self.pos;
            parse_module.parseModuleItem(self, &gb) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.recoverStatement(before);
            };
        }
        _ = try self.expect(.kw_end);
    } else {
        try self.skipAttributes();
        direct = !loop_body and (self.peek() == .kw_if or self.peek() == .kw_case);
        if (direct) gb.gen_count = b.gen_count - 1;
        try parse_module.parseModuleItem(self, &gb);
    }

    var body: std.ArrayList(Ast.StmtId) = .empty;
    // ponytail: `analog initial` (§5.2.1) inside a generate block is
    // spliced onto the ordinary spine like any other analog construct, so
    // it loses its initialization-only scheduling. Give `Ast.SeqBlock` an
    // is_initial statement, or hand the block back to `b.analog`, when a
    // model needs one — neither is free, and nothing asks yet.
    for (gb.analog.items) |ab| try body.append(self.arena, ab.body);
    blk.params = gb.params.items;
    blk.vars = gb.vars.items;
    blk.body = body.items;

    try b.ports.appendSlice(self.arena, gb.ports.items);
    try b.aliasparams.appendSlice(self.arena, gb.aliasparams.items);
    try b.nets.appendSlice(self.arena, gb.nets.items);
    try b.branches.appendSlice(self.arena, gb.branches.items);
    // §6.6: a generate block "brings the objects, behavioral constructs, and
    // module instances within the block into existence" — a conditional
    // generate for at most one block of its alternatives, a loop generate once
    // per iteration. Hoisting a module instance, a defparam or an
    // `initial`/`always` to the module elaborated it exactly once WHATEVER the
    // scheme said: the unselected arm's instance was built too. The analog
    // bodies above stay under the scheme; these have nowhere to go until a
    // generate block keeps its own items for elaboration to select or unroll,
    // so they are refused (E0235) instead of silently misplaced, and not
    // hoisted, so an enclosing block does not report them again.
    // ponytail: interim. Per-block items selected/unrolled in elaboration
    // replace this refusal. Nothing a block holds may be dropped silently:
    // every Body list is either hoisted above, kept under `blk`, or refused.
    // A digital parse keeps the instances on the block, whose scheme the
    // digital engine decides (`src/sim/digital/root.zig`, `generate`).
    // An analog one too: elaboration gates an if-generate's instances by the
    // scheme and refuses (E0235) the rest (`Flatten.genInstances`).
    blk.instances = gb.instances.items;
    for (gb.defparams.items) |d| try self.report(d.main_tok, .E0235, "a defparam", .{});
    for (gb.discrete.items) |d|
        try self.report(d.main_tok, .E0235, "an `{s}` block", .{if (d.is_always) "always" else "initial"});
    // The same for the three the body used to DROP outright, with no message:
    // a continuous assignment (A.6.1) and a gate (A.3.1) are drivers the
    // scheme decides the existence of exactly as it does an instance's, and a
    // named event (§5.10.4) is a declaration of the block's scope.
    for (gb.assigns.items) |a| try self.report(a.main_tok, .E0235, "a continuous assignment", .{});
    for (gb.gates.items) |g| try self.report(g.main_tok, .E0235, "a gate instance", .{});
    for (gb.pulls.items) |g| try self.report(g.main_tok, .E0235, "a pull gate instance", .{});
    for (gb.tasks.items) |t| try self.report(t.main_tok, .E0235, "a task or function declaration", .{});
    for (gb.switches.items) |sw| try self.report(sw.main_tok, .E0235, "a switch instance", .{});
    if (gb.events.items.len != 0) try self.report(tok, .E0235, "an event declaration (`{s}`)", .{self.file.str(gb.events.items[0])});
    try b.genvars.appendSlice(self.arena, gb.genvars.items);
    try b.functions.appendSlice(self.arena, gb.functions.items);
    // A nested generate construct's block names are declarations of the
    // scope they sit in and this one is not it — §6.6.2's rule is about "the
    // same scope", and VerA has no generate scope to hold them, so they ride
    // up to the module with the nets. That is what makes the §6.6.2
    // direct-nesting permission work: `construct` already says which
    // construct each came from.
    try b.gen_blocks.appendSlice(self.arena, gb.gen_blocks.items);
    try b.gen_loops.appendSlice(self.arena, gb.gen_loops.items);
    if (direct) {
        // Not a scope: the inner construct's blocks are named in OURS.
        try b.gen_auto.appendSlice(self.arena, gb.gen_auto.items);
    } else {
        try nameGenBlocks(self, &gb);
        blk.gen_name = blk.name;
    }
    const id = try self.file.addStmt(self.arena, .{ .block = blk }, tok);
    if (!direct and blk.name == .none) try b.gen_auto.append(self.arena, .{ .stmt = id, .n = b.gen_count });
    return id;
}

/// §6.6.3 External names for unnamed generate blocks: "All unnamed generate
/// blocks are given the name genblk<n> where <n> is the assigned number. If such
/// a name would conflict with an explicitly declared name, leading zeroes are
/// added until the name does not conflict." Run when `b`'s scope is complete,
/// so a declaration written after the construct still counts.
pub fn nameGenBlocks(self: *Parser, b: *parse_module.Body) error{OutOfMemory}!void {
    for (b.gen_auto.items) |g| {
        var zeros: usize = 0;
        const name = while (true) : (zeros += 1) {
            const text = try std.fmt.allocPrint(self.arena, "genblk{s}{d}", .{ ("00000000")[0..@min(zeros, 8)], g.n });
            const id = try self.file.intern(self.arena, text);
            if (zeros >= 8 or !declaredIn(b, id)) break id;
        };
        self.file.stmts.items[@intFromEnum(g.stmt)].block.gen_name = name;
    }
    b.gen_auto.clearRetainingCapacity();
}

/// Is `name` explicitly declared in the scope `b` collected? The declaration
/// spaces `checkGenBlockNames` reads, plus instances and named events.
fn declaredIn(b: *const parse_module.Body, name: Ast.StrId) bool {
    for (b.gen_blocks.items) |g| if (g.name == name) return true;
    for (b.instances.items) |i| if (i.name == name) return true;
    return inDeclSpaces(b, name) or
        std.mem.indexOfScalar(Ast.StrId, b.events.items, name) != null;
}

/// Is `name` in one of the module's ordinary declaration spaces? A port is
/// listed as well as a net: §6.5's header names are declarations too, and
/// §3.4.6 an aliasparam's own identifier is a declaration.
/// ponytail: stdlib membership over interned IDs; index declarations if large
/// modules make these linear scans hot.
fn inDeclSpaces(b: *const parse_module.Body, name: Ast.StrId) bool {
    for (b.aliasparams.items) |a| if (a.alias == name) return true;
    return nameIn(Ast.Port, b.ports.items, name) or
        nameIn(Ast.ParamDecl, b.params.items, name) or
        nameIn(Ast.VarDecl, b.vars.items, name) or
        nameIn(Ast.NetDecl, b.nets.items, name) or
        nameIn(Ast.BranchDecl, b.branches.items, name) or
        nameIn(Ast.FuncDecl, b.functions.items, name) or
        std.mem.indexOfScalar(Ast.StrId, b.genvars.items, name) != null;
}

/// §6.6.1/§6.6.2/§6.8: a named generate block's name is a DECLARATION in
/// the enclosing scope — "it shall be an error if the name of a generate
/// block instance array conflicts with any other declaration, including any
/// other generate block instance array" (§6.6.1), "named generate blocks may
/// not have the same name as any other declaration in the same scope … or as
/// blocks in any other generate construct in the same scope, EVEN IF NOT
/// SELECTED FOR INSTANTIATION" (§6.6.2). §6.8 states the general rule and
/// adds that it applies "regardless of whether the generate block is
/// instantiated", which is why nothing here consults the scheme.
///
/// Run once at the end of the module, not at the `begin : name` itself: a
/// declaration may follow the generate construct in the text, and the clause
/// is about one SCOPE, not about source order.
///
/// Diagnosed and carried on (`report`, like the E0222 width check) so that
/// a second, unrelated mistake in the same module is still reported;
/// `self.failed` is what refuses the file.
///
/// ponytail: two named blocks collide only across different OUTERMOST
/// constructs. §6.6.2 permits arms of one conditional construct to share a
/// name and extends that through direct nesting, and `gen_construct` keys on
/// the root of the nest — so a loop generate nested inside one arm is let off
/// as well, which the clause does not license. Key on the construct itself
/// rather than its root the day a fixture asks; that needs generate blocks to
/// be real scope objects, which is also what §6.6.3 hierarchical names want.
pub fn checkGenBlockNames(self: *Parser, b: *parse_module.Body) error{OutOfMemory}!void {
    // A.4.2 `genvar_initialization ::= genvar_identifier = constant_expression`,
    // and a genvar_identifier is what a `genvar_declaration` introduces.
    for (b.gen_loops.items) |l| if (std.mem.indexOfScalar(Ast.StrId, b.genvars.items, l.name) == null)
        try self.report(l.tok, .E0238, "`{s}`", .{self.file.strings.get(l.name)});
    for (b.gen_blocks.items, 0..) |g, i| {
        const clash = inDeclSpaces(b, g.name) or
            other: {
                for (b.gen_blocks.items[0..i]) |h| {
                    if (h.name == g.name and h.construct != g.construct) break :other true;
                }
                break :other false;
            };
        if (clash) try self.report(g.tok, .E0230, "`{s}`", .{
            self.file.strings.get(g.name),
        });
    }
}

/// Is `name` the name of one of `decls`? One helper for eight declaration
/// slices, which all carry a `.name: StrId` — and a StrId comparison is a
/// name comparison because §2.8 identifiers are interned.
fn nameIn(comptime T: type, decls: []const T, name: Ast.StrId) bool {
    for (decls) |d| if (d.name == name) return true;
    return false;
}
