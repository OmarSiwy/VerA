//! Annex A.4.2 generate constructs (LRM §6.6).
//!
//! In: generate regions, loop and conditional generates. Out: an `Ast.AnalogBlock` whose body
//! is the `for`/`if`, which lowering unrolls (§6.6.1).
//!
//! LRM clauses this file's code cites: §3.6.3, §3.6.3.2, §5.9.2, §6.5.2, §6.5.2.2, §6.6, §6.6.1, §6.6.2, §6.8, §6.9.1, §7.4.4, §7.9.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_generate.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const constfold = @import("../constfold.zig");
const Error = parser.Error;
const found = Parser.found;

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
        else => unreachable,
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
    const init_s = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.semicolon);
    const cond = try parse_expr.parseExpr(self);
    _ = try self.expect(.semicolon);
    const step = try parse_stmt.parseAssignNoSemi(self);
    _ = try self.expect(.rparen);
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
    const tok = self.pos;
    // A.4.2 has no null generate_block, but `if (c) ;` is what a model
    // writes for a deliberately empty arm and refusing it would only move
    // the error off the rule the source actually breaks.
    if (self.eat(.semicolon)) return self.file.addStmt(self.arena, .empty, tok);

    var blk: Ast.SeqBlock = .{};
    var gb: parse_module.Body = .{};
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
    for (gb.instances.items) |inst| try self.report(inst.main_tok, .E0235, "a module instance", .{});
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
    return self.file.addStmt(self.arena, .{ .block = blk }, tok);
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
    for (b.gen_blocks.items, 0..) |g, i| {
        // Every ordinary declaration space of the module. A port is listed
        // as well as a net: §6.5's header names are declarations too.
        // ponytail: stdlib membership over interned IDs; index declarations
        // if large modules make these linear scans hot.
        const clash = nameIn(Ast.Port, b.ports.items, g.name) or
            nameIn(Ast.ParamDecl, b.params.items, g.name) or
            nameIn(Ast.VarDecl, b.vars.items, g.name) or
            nameIn(Ast.NetDecl, b.nets.items, g.name) or
            nameIn(Ast.BranchDecl, b.branches.items, g.name) or
            nameIn(Ast.FuncDecl, b.functions.items, g.name) or
            std.mem.indexOfScalar(Ast.StrId, b.genvars.items, g.name) != null or
            alias: {
                // §3.4.6 an aliasparam's own identifier is a declaration.
                for (b.aliasparams.items) |a| if (a.alias == g.name) break :alias true;
                break :alias false;
            } or
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
pub fn nameIn(comptime T: type, decls: []const T, name: Ast.StrId) bool {
    for (decls) |d| if (d.name == name) return true;
    return false;
}

/// §6.5.2 body port declaration: it re-declares a header port's direction
/// and discipline, it does not introduce a new terminal.
pub fn parsePortDecl(self: *Parser, b: *parse_module.Body) Error!void {
    const dir = parse_module.portDirection(self.peek()).?;
    const dir_tok = self.pos;
    self.pos += 1;
    // A.2.1.2's `[ net_type | wreal ]`, which used to be eaten and dropped.
    // It is §7.9's resolution input — see `Ast.Port.kind`.
    var kind: Ast.NetKind = .wire;
    var signed = false;
    const disc = try parse_module.optPortType(self, &kind, &signed);
    // A.2.1.2's two VARIABLE arms, which only `output` has:
    //
    //     output_declaration ::=
    //         output [ discipline_identifier ] [ net_type | wreal ] [ signed ]
    //             [ range ] list_of_port_identifiers
    //       | output [ discipline_identifier ] reg [ signed ] [ range ]
    //             list_of_variable_port_identifiers
    //       | output output_variable_type list_of_variable_port_identifiers
    //     output_variable_type ::= integer | time
    //
    // `optDiscipline` above has already eaten the `[ net_type ]` of the
    // first arm and the `[ signed ]` all three share, so the only thing
    // left to tell the arms apart is this keyword. The port is then a
    // VARIABLE and not a net — §6.5.2 calls it a port type declaration —
    // which is why the name list gets a `VarDecl` below as well as the
    // direction, and why the `[ = constant_expression ]` of
    // `list_of_variable_port_identifiers` (A.2.3) is read here and nowhere
    // else in this function.
    const var_storage: ?@FieldType(Ast.VarDecl, "storage") = switch (self.peek()) {
        .kw_integer => .variable, // A.2.2.1 output_variable_type
        .kw_time => .time, // …its other alternative
        .kw_reg => .reg, // A.2.1.2's second arm
        else => null,
    };
    if (var_storage != null) {
        if (dir != .output) return self.failAt(
            self.pos,
            .E0207,
            "found {s}: A.2.1.2 gives a variable type to `output` only",
            .{self.found(self.pos)},
        );
        self.pos += 1;
        signed = self.eat(.kw_signed);
    }
    // A.2.1.2 `inout [ range ] list_of_port_identifiers ;` — §6.5.2.2's
    // "port direction declaration", the half of the clause that carries
    // the direction. Its range is compared against the port TYPE
    // declaration's in lowering, so it lands in its own field.
    const range: ?Ast.Dim = if (self.peek() == .lbracket) try parse_decl.parseDim(self) else null;
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        if (var_storage) |storage| {
            // A.2.3 `list_of_variable_port_identifiers ::= port_identifier
            // [ = constant_expression ] { , … }` — the initializer slot the
            // net arms do not have.
            const init_expr: Ast.ExprId = if (self.eat(.assign_eq)) try parse_expr.parseExpr(self) else .none;
            try b.vars.append(self.arena, .{
                .name = name,
                // Both arms are integral: A.2.2.1's `output_variable_type`
                // is `integer | time`, and §3.4.1 folds `time` to the same
                // representation VerA gives an `integer`; Table 7-1 does
                // the same for a `reg`'s bits.
                .ty = .integer,
                .init = init_expr,
                .storage = storage,
                .packed_range = range,
                .is_signed = signed,
                .main_tok = tok,
            });
        }
        if (findPort(b, name)) |p| {
            if (signed) p.is_signed = true;
            // §6.2 "Ports declared in the list of port declarations shall
            // not be redeclared within the body of the module." A direction
            // is what a `list_of_port_declarations` header carries and a
            // bare `list_of_ports` header cannot (Syntax 6-1), so a port
            // that already has one was declared already — in the ANSI
            // header, or by an earlier body declaration (§6.8's duplicate).
            if (p.direction != .unspecified) {
                try self.report(tok, .E0218, "`{s}`", .{self.file.str(name)});
            } else {
                p.direction = dir;
                if (disc != .none) p.discipline = disc;
                if (range != null) p.range = range;
                if (kind != .wire) p.kind = kind;
            }
        } else {
            try self.report(tok, .E0206, "`{s}`", .{self.file.str(name)});
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
    // A.2.1.2's `wreal` alternative, refused AFTER the declaration is read
    // and recorded — see `parseWrealDecl` for the clause and for why
    // silence is the one answer that is not available.
    if (kind == .wreal) try self.report(dir_tok, .E1100, parse_module.wreal_unimplemented, .{});
}

pub fn findPort(b: *parse_module.Body, name: Ast.StrId) ?*Ast.Port {
    for (b.ports.items) |*p| if (p.name == name) return p;
    return null;
}

/// A.2.1.3 `list_of_net_identifiers ;` (§3.6.3). A net that names a header
/// port binds the discipline to that port instead of declaring a new net,
/// so lowering sees one object per terminal.
///
/// §3.6.3 Syntax 3-6 puts the vector range between the discipline and the
/// names — `electrical [3:0] p, q;` — so it is parsed here, once, and
/// sticks to every name in the list.
///
/// A `net_decl_assignment` (`electrical n = 5.0;`) parses here too — see the
/// §3.6.3.2 note at the `assign_eq` arm below for what happens to the value.
/// §6.7 a hierarchical name in a DECLARATION position, interned as ONE
/// string with the source's own `.` between the parts.
///
/// That join is the whole mechanism, and it is deliberate: `Elaborate.sep`
/// is the same period, so the string a `defparam` path or an Annex F.2.1
/// out-of-context declaration writes IS the flat name elaboration gives the
/// entity it names. Neither needs a path walk, and neither needs a second
/// representation. A name with no dot in it interns exactly as it did
/// before, so the ordinary declaration paths are untouched.
///
/// The parts are `expectIdent`s, so each has been through `internTok` and no
/// longer carries a period of its own — which is what lets the join below be
/// the whole mechanism rather than an approximation of one.
///
/// `allow_index`: A.9.3 `hierarchical_identifier ::= { identifier [ [
/// constant_expression ] ] . } identifier` — a per-segment index naming ONE
/// element of a §6.2.2 instance array, legal on every segment but the last
/// (the production puts it inside the braces, before the `.`). The index is
/// folded HERE and spelled into the stored text as `[{d}]`, because
/// elaboration mints instance-array elements under exactly that spelling
/// (`Flatten.walkInstances`) and the shared representation's whole point is
/// that a defparam key IS the flat name. A value the fold cannot reach is
/// E0231 — interned text has no digits for an unevaluated expression.
///
/// The net-declaration caller passes `false`: not because F.2.1's
/// out-of-context form forbids an index, but because in that position a `[`
/// after the name is how A.2.1.3's `ams_net_identifier` spells a vector
/// range, and consuming it as an index would trade one diagnostic for a
/// wronger one.
pub fn parseDottedName(self: *Parser, allow_index: bool) Error!Ast.StrId {
    const first = try self.expectIdent();
    if (self.peek() != .dot and !(allow_index and self.peek() == .lbracket)) return first;
    var joined: std.ArrayList(u8) = .empty;
    try joined.appendSlice(self.arena, self.file.str(first));
    while (true) {
        if (allow_index and self.peek() == .lbracket) {
            const tok = self.pos;
            self.pos += 1;
            const idx = try parse_expr.parseExpr(self);
            _ = try self.expect(.rbracket);
            const k = constIndex(self, idx) orelse return self.failAt(tok, .E0231, "", .{});
            var buf: [24]u8 = undefined;
            try joined.appendSlice(self.arena, std.fmt.bufPrint(&buf, "[{d}]", .{k}) catch unreachable);
            // A.9.3 an indexed segment is always followed by `.` — the
            // final identifier of a path carries no index.
            _ = try self.expect(.dot);
        } else if (!self.eat(.dot)) break;
        const part = try self.expectIdent();
        try joined.append(self.arena, '.');
        try joined.appendSlice(self.arena, self.file.str(part));
    }
    return self.file.intern(self.arena, joined.items);
}

/// Fold A.9.3's `[ constant_expression ]` through the one constant kernel:
/// literals and every operator over them, with §4.2's integer typing — the
/// same fold `Elaborate.constInt` applies to the instance-array RANGE these
/// indices select from. Not parameter reads: the parameter table is
/// elaboration's, and a value not in hand here cannot be spelled into
/// interned text. A real-valued index is not one.
pub fn constIndex(self: *Parser, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(&self.file, e, constfold.literal_env) orelse return null;
    return if (c == .int) c.int else null;
}

/// A.2.2.1 net_type keyword -> `Ast.NetKind`, null for a token that is not
/// one. A declaration naming no net type resolves as `.wire` (§7.9); that
/// default is the caller's, not a spelling's.
pub fn netKind(tag: token.Tag) ?Ast.NetKind {
    return switch (tag) {
        .kw_wire => .wire,
        .kw_tri => .tri,
        .kw_tri0 => .tri0,
        .kw_tri1 => .tri1,
        .kw_triand => .triand,
        .kw_trior => .trior,
        .kw_trireg => .trireg,
        .kw_wand => .wand,
        .kw_wor => .wor,
        .kw_uwire => .uwire,
        .kw_supply0 => .supply0,
        .kw_supply1 => .supply1,
        else => null,
    };
}

/// A.2.2.2, one keyword: its IEEE 1364-2005 clause 7 level and which of the
/// production's two sides it may occupy. `strength0 ::= supply0 | strong0 |
/// pull0 | weak0` and its `highz0` partner are the 0 side; the `1` spellings
/// are the 1 side. `small`/`medium`/`large` are a `charge_strength`, a
/// DIFFERENT production that appears only in A.2.1.3's `trireg`
/// alternatives, so they are listed here to be recognised and refused — a
/// parser that accepted any parenthesised strength after any net type would
/// make `wire (small) w;` legal, and A.2.2.1 has no such derivation.
pub const StrengthWord = struct { level: Ast.Strength, side: u8 };
pub const strength_words = std.StaticStringMap(StrengthWord).initComptime(.{
    .{ "supply0", StrengthWord{ .level = .supply, .side = 0 } },
    .{ "strong0", StrengthWord{ .level = .strong, .side = 0 } },
    .{ "pull0", StrengthWord{ .level = .pull, .side = 0 } },
    .{ "weak0", StrengthWord{ .level = .weak, .side = 0 } },
    .{ "highz0", StrengthWord{ .level = .highz, .side = 0 } },
    .{ "supply1", StrengthWord{ .level = .supply, .side = 1 } },
    .{ "strong1", StrengthWord{ .level = .strong, .side = 1 } },
    .{ "pull1", StrengthWord{ .level = .pull, .side = 1 } },
    .{ "weak1", StrengthWord{ .level = .weak, .side = 1 } },
    .{ "highz1", StrengthWord{ .level = .highz, .side = 1 } },
    // side 2: a charge strength, which belongs to neither.
    .{ "small", StrengthWord{ .level = .small, .side = 2 } },
    .{ "medium", StrengthWord{ .level = .medium, .side = 2 } },
    .{ "large", StrengthWord{ .level = .large, .side = 2 } },
});

/// The eight drive strengths lex as `.kw_reserved` except `supply0`/
/// `supply1`, which are also A.2.2.1 net types and so carry their own tags.
/// Both paths end at the spelling, which is what A.2.2.2 is written in.
pub fn strengthWord(self: *const Parser, i: u32) ?StrengthWord {
    return switch (self.tags[i]) {
        .kw_reserved, .kw_supply0, .kw_supply1 => strength_words.get(parse_expr.tokenText(self, i)),
        else => null,
    };
}

/// A.2.2.2 `drive_strength`, whose six alternatives all say the same thing:
/// one 0-side spec and one 1-side spec, in either order. The caller has seen
/// the `(` and decided it cannot begin anything else.
pub fn parseDriveStrength(self: *Parser, s0: *Ast.Strength, s1: *Ast.Strength) Error!void {
    _ = try self.expect(.lparen);
    const first_tok = self.pos;
    const a = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.comma);
    const b = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.rparen);
    // `(strong0, pull0)` is derivable from no alternative of A.2.2.2, and
    // is exactly what an implementation that lexed two strength keywords
    // and took a maximum would wave through.
    if (a.side == b.side or a.side == 2 or b.side == 2)
        return self.failAt(first_tok, .E0207, "a drive strength pairs one 0-side with one 1-side strength", .{});
    s0.* = if (a.side == 0) a.level else b.level;
    s1.* = if (a.side == 1) a.level else b.level;
    // A.2.2.2 pairs `highz0`/`highz1` only with a real strength on the other
    // side, and IEEE 1364-2005 §6.1.4 says why: "(highz1, highz0) and
    // (highz0, highz1) shall be treated as illegal constructs".
    if (s0.* == .highz and s1.* == .highz)
        return self.failAt(first_tok, .E0207, "§6.1.4: both drive strengths cannot be high impedance", .{});
}

/// A.2.1.3 gives `trireg` alternatives of its own, and they are the only
/// ones carrying `charge_strength ::= ( small ) | ( medium ) | ( large )`.
/// A `drive_strength` on a net DECLARATION is a separate alternative that
/// nothing in this tree writes, so a parenthesis after any other net type
/// is refused here rather than read as the other production — which is the
/// cheap wrong parser that would make `wire (small) w;` legal.
pub fn parseChargeStrength(self: *Parser, kind: Ast.NetKind) Error!Ast.Strength {
    _ = try self.expect(.lparen);
    const tok = self.pos;
    const w = strengthWord(self, self.pos) orelse return self.failAt(tok, .E0207, "found {s}, which is not a charge strength", .{self.found(tok)});
    self.pos += 1;
    _ = try self.expect(.rparen);
    if (kind != .trireg or w.side != 2)
        return self.failAt(tok, .E0207, "a charge strength is only legal on a trireg", .{});
    return w.level;
}

/// A.2.2.3 `delay3 ::= # delay_value | # ( delay_value [ , delay_value
/// [ , delay_value ] ] )`. The cursor is on the `#`.
///
/// One value is all three transitions (IEEE 1364-2005 §7.14). Two leave
/// `off` unset, because the clause derives it as the SMALLER of the two and
/// that is arithmetic on the evaluated values, not a syntax node.
pub fn parseDelay3(self: *Parser) Error!Ast.Delay3 {
    _ = try self.expect(.hash);
    if (!self.eat(.lparen)) {
        const v = try parseDelayValue(self);
        return .{ .rise = v, .fall = v, .off = v };
    }
    var out: Ast.Delay3 = .{};
    out.rise = try parseDelayValue(self);
    out.fall = out.rise;
    out.off = out.rise;
    if (self.eat(.comma)) {
        out.fall = try parseDelayValue(self);
        out.off = if (self.eat(.comma)) try parseDelayValue(self) else .none;
    }
    // A.2.2.3's innermost bracket pair closes after the THIRD value, so
    // from there the only terminal the production admits is `)`. A fourth
    // value is a missing parenthesis, and E0210 is the diagnostic that says
    // so — not E0207's generic "unexpected token", which would send the
    // reader looking for the end of the previous statement.
    if (self.peek() != .rparen) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
    self.pos += 1;
    return out;
}

/// A.2.2.3 `delay_value`. `mintypmax_expression` is not admitted: A.2.2.3
/// spells it `mintypmax_expression` only inside `delay_control`, and the
/// `:`-separated form has no selector in this compiler to choose from.
pub fn parseDelayValue(self: *Parser) Error!Ast.ExprId {
    return parse_expr.parseExpr(self);
}

pub fn parseNetNames(self: *Parser, b: *parse_module.Body, disc: Ast.StrId, kind: Ast.NetKind, is_ground: bool, st: Ast.NetStrength, signed: bool) Error!void {
    const range: ?Ast.Dim = if (self.peek() == .lbracket) try parse_decl.parseDim(self) else null;
    // A.2.1.3 puts `[ delay3 ]` between the range and the name list, and it
    // belongs to the NET, not to the declaration's optional assignment:
    // `wire #3 y = ~a;` delays y's own transition.
    //
    // NOT gated on `digital`. The bracket used to be an E0207 ("a net delay
    // has no meaning outside a digital design element") outside a `.v`
    // source, which is a verdict on the SEMANTICS written as a refusal of
    // the SYNTAX: §1.1 makes "the complete IEEE Std 1364 Verilog
    // specification" part of Verilog-AMS HDL, and A.2.1.3 grants the
    // bracket to every one of its twelve alternatives. A delay VerA has no
    // discrete kernel to honour is a delay it drops, the way it drops the
    // strength brackets above — silently dropping a timing annotation is
    // what every analog-only tool does with one, and it is not the same
    // claim as "this text is not derivable from the annex".
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parseDelay3(self) else .{};
    while (true) {
        const tok = self.pos;
        // Annex F.2.1 step 3 / §3.10 order 1: an OUT-OF-CONTEXT declaration,
        // which the LRM prints as `electrical top.middle.bottom.sig;` and
        // which "overrides any discipline which may be declared for sig in
        // the module where sig was declared". The dotted name is interned
        // whole; `findPort` below cannot match it, so it lands as a net
        // declaration under its path and elaboration reads it as one.
        const name = try parseDottedName(self, false);
        // §3.6.3.2 / Syntax 3-6 `net_decl_assignment ::= ams_net_identifier =
        // expression` — a NODESET value: "the initializer shall be a
        // constant_expression and will be used as a nodeset value for the
        // potential of the net BY THE ANALOG SOLVER". Not an assignment and
        // not a clamp, so it changes no answer the device computes; it is an
        // initial guess handed to the host's solver. `ground` has no such
        // form (Syntax 3-7 gives it `list_of_net_identifiers`), so the `=`
        // there is still E0207.
        //
        // Carried on `NetDecl.init` and folded by lowering, which is where
        // both of the clause's rules can be judged: "shall be a
        // constant_expression" is E0365 (lowering owns the folder) and
        // "nets of non-continuous disciplines are not [allowed one]" is
        // E0366 (lowering owns the discipline table, and §10.2's default
        // has not been applied yet at this point in the parse).
        const nodeset: Ast.ExprId = if (!is_ground and self.eat(.assign_eq))
            try parse_expr.parseExpr(self)
        else
            .none;
        // Only the FIRST declaration binds. A port that already carries a
        // discipline gets a net entry instead, so lowering sees BOTH
        // declarations and can apply §7.4.4 (E0902) — overwriting here is
        // what used to make the second one invisible. The entry adds no
        // node: internNode finds the port's existing slot by name.
        const port = if (is_ground) null else findPort(b, name);
        if (port != null and signed) port.?.is_signed = true;
        if (port != null and port.?.discipline == .none) {
            port.?.discipline = disc;
            // §6.5.2.2: this IS the port type declaration. Recorded beside
            // the direction declaration's range rather than over it — see
            // Ast.Port.type_range.
            port.?.type_range = range;
            // …and the net TYPE with it. A.2.1.3 gives every one of its
            // twelve alternatives a `net_type`, and §7.9's resolution is a
            // function of it, so dropping it here made `tri0 p;` on a port
            // resolve as a plain `wire`. `.wire` is what a discipline-only
            // declaration passes in, which is also A.2.1.3's default, so the
            // assignment is a no-op for every net that never named a type.
            port.?.kind = kind;
            // `electrical p = 5.0;` on a header port lands here, and the
            // discipline is all this branch can carry: a Port has no
            // initializer slot. The nodeset gets a net entry of its own
            // with NO discipline — `.none` is what keeps it out of §7.4.4
            // (E0902), and `internNode` with an empty discipline finds the
            // port's slot without overwriting what this branch just bound.
            if (nodeset != .none) try b.nets.append(self.arena, .{
                .name = name,
                .range = range,
                .init = nodeset,
                .main_tok = tok,
            });
        } else {
            try b.nets.append(self.arena, .{
                .name = name,
                .kind = kind,
                .discipline = disc,
                .is_ground = is_ground,
                .range = range,
                .is_signed = signed,
                .charge = st.charge,
                .strength0 = st.strength0,
                .strength1 = st.strength1,
                .delay = delay,
                .init = nodeset,
                .main_tok = tok,
            });
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// LRM §3.12 / A.2.1.3, both arms of `branch_declaration`:
///
///     branch ( a [, b] )  list_of_branch_identifiers ;
///     branch ( < p > )    list_of_branch_identifiers ;   // Syntax 3-9
///
/// The second is the §3.12.1 PORT BRANCH, "a branch between the upper and
/// lower connections of the port" — the same quantity `I(<p>)` reads, given
/// a name. It is told from the first by one token, and the `<` is also what
/// A.8.9's port_probe_function_call uses, so `parseAccess` spells it the
/// same way.
///
/// A.2.3 puts an optional `[ range ]` on each branch_identifier: a branch
/// ARRAY, several branches over one terminal pair. The range rides on the
/// declaration and lowering expands it, because that is where a constant
/// expression can be folded.
pub fn parseBranchDecl(self: *Parser, b: *parse_module.Body) Error!void {
    self.pos += 1; // 'branch'
    _ = try self.expect(.lparen);
    const is_port_branch = self.eat(.lt);
    const hi = try parse_expr.parseNetRef(self);
    var lo: Ast.ExprId = .none;
    if (is_port_branch) {
        _ = try self.expect(.gt);
    } else if (self.eat(.comma)) {
        lo = try parse_expr.parseNetRef(self);
    }
    _ = try self.expect(.rparen);
    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        try b.branches.append(self.arena, .{
            .name = name,
            .hi = hi,
            .lo = lo,
            .is_port_branch = is_port_branch,
            .range = if (self.peek() == .lbracket) try parse_decl.parseDim(self) else null,
            .main_tok = name_tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
