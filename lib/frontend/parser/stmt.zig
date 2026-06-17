//! Annex A.6.4 analog_statement (LRM Clause 5): statement tokens inside an
//! analog block, function or discrete process in, `Ast.StmtId`s out.
//! Digital-only statements (IEEE 1364-2005 Clause 9) parse only in the
//! discrete grammar.
//! LRM clauses cited: §4.7.1, §4.7.2.2, §5.6, §5.7, §5.8, §5.8.3, §5.9, §5.9.1,
//! §5.9.2, §5.10, §5.10.4, §5.11.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_module = @import("module.zig");
const parse_specify = @import("specify.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.6.4 analog_statement, LRM Clause 5
// -----------------------------------------------------------------------

/// Parses one statement where A.6.4 admits no null statement, reporting a
/// bare `;` as E0219 in an analog source and then parsing on (the `;` is
/// consumed and `.empty` returned), so later mistakes are still reported.
///
/// A bare `;` derives only through `analog_statement_or_null`, reached from
/// a conditional arm, a case item and an event statement (annex G.2.2);
/// those sites call `parseStmt`. `analog_seq_block` (A.6.3) and
/// `analog_construct` (A.6.2) take `analog_statement`, so they call this.
pub fn parseStmtNoNull(self: *Parser) Error!Ast.StmtId {
    if (!self.digital and self.peek() == .semicolon)
        try self.report(self.pos, .E0219, "", .{});
    return parseStmt(self);
}

/// Parses one statement (A.6.4), null statement included. Outside the
/// discrete grammar (`discreteGrammar`), `#`, `wait`, `forever`, a task
/// enable and the procedural continuous assignments are not statements:
/// they fall through to the expression statement and report "expected
/// expression". `fork` parses only in a digital source. `casex`/`casez`
/// parse everywhere: §7.3.2 makes them analog statements in Verilog-AMS.
pub fn parseStmt(self: *Parser) Error!Ast.StmtId {
    try self.enter();
    defer self.depth -= 1;
    const mark = self.attrs.items.len;
    try self.skipAttributes();
    // A.6.4 `{ attribute_instance } <statement>`: a statement keeps VerA's
    // own attributes (`Ast.SourceFile.lte_attrs`). Read before the body,
    // whose nested statements append their attributes after.
    const lte = self.lteSince(mark);
    const id = try parseStmtBody(self);
    try self.keepLte(lte, id, .none);
    return id;
}

fn parseStmtBody(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    if (self.discreteGrammar() and self.eat(.hash)) {
        const delay = try parseDelay(self);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = delay, .body = body, .kind = .delay } }, tok);
    }
    // A.6.5 `wait_statement ::= wait ( expression ) statement_or_null`:
    // digital only, like `#`; A.6.4 has no analog alternative for it.
    if (self.discreteGrammar() and self.peek() == .kw_wait) {
        self.pos += 1;
        _ = try self.expect(.lparen);
        const cond = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = cond, .body = body, .kind = .level } }, tok);
    }
    // A.6.2 `procedural_continuous_assignments` (IEEE 1364-2005 §9.3),
    // digital statements only: `assign`/`force lvalue = expr;`,
    // `deassign`/`release lvalue;`. §8.5.3.2 gives each its process.
    if (self.discreteGrammar()) {
        const kind: ?Ast.ProcContinuous = if (self.peek() == .kw_assign) .assign else if (self.reservedIs(self.pos, "force")) .force else if (self.reservedIs(self.pos, "deassign")) .deassign else if (self.reservedIs(self.pos, "release")) .release else null;
        if (kind) |k| {
            self.pos += 1;
            const target = try parse_expr.parsePostfix(self);
            var value: Ast.ExprId = .none;
            if (k == .assign or k == .force) {
                _ = try self.expect(.assign_eq);
                value = try parse_expr.parseExpr(self);
            }
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value, .continuous = k } }, tok);
        }
    }
    // A.6.8 `loop_statement ::= forever statement` (IEEE 1364-2005 §9.6:
    // "Continuously executes a statement"), digital only. A.6.8's
    // `analog_loop_statement` has no forever (annex G.2.1 retired it), so
    // outside the discrete context the keyword falls through to the
    // expression statement and is E0209. The body is `statement`, not
    // `statement_or_null`, so `forever ;` is E0296 (a null body would also
    // never suspend).
    //
    // Recorded as `while (1) body`: §9.6 gives the two the same meaning, so
    // no walk over `Ast.StmtKind` needs a separate arm. The `1` is an
    // unsized decimal (§2.6.1: signed, 32-bit) anchored on `forever`.
    if (self.discreteGrammar() and self.peek() == .kw_forever) {
        self.pos += 1;
        const always = try self.file.exprs.addIntLiteral(self.arena, tok, .{ .value = 1, .width = 0, .signed = true });
        if (self.peek() == .semicolon) return self.failAt(self.pos, .E0296, "", .{});
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = always, .body = body } }, tok);
    }
    // A.6.3 `par_block`, IEEE 1364-2005 §9.8.2, digital only.
    if (self.digital and self.reservedIs(self.pos, "fork")) return parseSeqBlock(self);
    switch (self.peek()) {
        .semicolon => {
            self.pos += 1;
            return self.file.addStmt(self.arena, .empty, tok);
        },
        .kw_begin => return parseSeqBlock(self),
        .kw_if => return parse_generate.parseIf(self, null, tok), // §5.8 / A.6.6
        // §5.8.3 / A.6.7. `casex`/`casez` share the production; §7.3.2
        // lists all three among the analog context's four-state features.
        .kw_case => return parseCase(self, .normal, null),
        .kw_casex => return parseCase(self, .casex, null),
        .kw_casez => return parseCase(self, .casez, null),
        .kw_for => return parse_generate.parseFor(self, null, tok), // §5.9.2 / A.6.8
        .kw_while => { // §5.9.1
            self.pos += 1;
            _ = try self.expect(.lparen);
            const cond = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            const body = try parseStmt(self);
            return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = cond, .body = body } }, tok);
        },
        .kw_repeat => { // §5.9
            self.pos += 1;
            _ = try self.expect(.lparen);
            const count = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            const body = try parseStmt(self);
            return self.file.addStmt(self.arena, .{ .repeat_stmt = .{ .count = count, .body = body } }, tok);
        },
        .at => return parseEventControl(self), // §5.10 / A.6.5
        // A.6.5 `event_trigger ::= -> hierarchical_event_identifier
        // { [ expression ] } ;` (§5.10.4). The bracketed expressions index
        // an event array, which A.2.1.3's `list_of_event_identifiers` cannot
        // declare in this subset, so only the scalar form is parsed.
        .arrow => {
            self.pos += 1;
            const name = try self.expectIdent();
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .event_trigger = .{ .name = name } }, tok);
        },
        .kw_disable => { // §5.11
            self.pos += 1;
            const name = try self.expectIdent();
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .disable = .{ .name = name } }, tok);
        },
        .kw_return => { // A.6.5 jump_statement (§4.7.1)
            self.pos += 1;
            // §4.7.2.2: "When the return statement is used, the function
            // shall specify an expression with the return of the correct
            // type for the function." A bare `return;` specifies none, and
            // is not a spelling of §4.7.2.1's default. Outside a function,
            // lowering reports `return` (E0403).
            const value: Ast.ExprId = if (self.peek() == .semicolon) v: {
                if (self.in_analog_fn) {
                    var d = self.failWith(tok, .E0227);
                    d.help("write `return <expr>;`", .{});
                    try d.emit();
                }
                break :v .none;
            } else try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .jump = .{ .kind = .ret, .value = value } }, tok);
        },
        .kw_break, .kw_continue => {
            const kind: Ast.Stmt.JumpKind = if (self.peek() == .kw_break) .brk else .cont;
            self.pos += 1;
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .jump = .{ .kind = kind } }, tok);
        },
        // A.6.9 analog_system_task_enable (§5.12, ch9)
        .system_identifier => return parseSysTask(self),
        else => return parseExprOrContributeStmt(self), // else: not a statement keyword, so an expression or contribution statement
    }
}

/// Parses a §5.3.2 / A.6.3 analog_seq_block, or a digital `fork … join`.
/// Local declarations are only legal on a named block but are accepted on
/// any, leaving lowering to report the resulting undeclared name.
fn parseSeqBlock(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const parallel = self.peek() != .kw_begin; // `fork`
    self.pos += 1; // 'begin' / 'fork'
    var blk: Ast.SeqBlock = .{ .parallel = parallel };
    if (self.eat(.colon)) {
        const at = self.pos;
        blk.name = try self.expectIdent();
        // §4.7.1: an analog function "shall not use named blocks".
        // Non-fatal, so the rest of the body is still parsed.
        if (self.in_analog_fn) {
            var d = self.failWith(at, .E0226);
            d.msg("`{s}`", .{self.file.str(blk.name)});
            d.help("remove the label", .{});
            try d.emit();
        }
    }

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var events: std.ArrayList(Ast.StrId) = .empty;
    while (true) {
        const before_attrs = self.pos;
        const attr_mark = self.attrs.items.len;
        try self.skipAttributes();
        // IEEE 1364-2005 A.6.3: `begin [ : block_identifier
        // { block_item_declaration } ]`, so an unnamed block declares nothing.
        if (self.digital and blk.name == .none) switch (self.peek()) {
            .kw_parameter, .kw_localparam, .kw_integer, .kw_real, .kw_realtime, .kw_time, .kw_reg, .kw_event => return self.failAt(self.pos, .E0209, "found {s}: only a named block has block_item_declarations (A.6.3)", .{self.found(self.pos)}),
            else => {}, // else: not a declaration
        };
        switch (self.peek()) {
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
            },
            // IEEE 1364-2005 A.2.8 `block_item_declaration`'s digital arms,
            // which A.6.3 gives a named block only.
            .kw_reg => if (self.digital and blk.name != .none) try parse_decl.parseRegDecl(self, &vars) else {
                self.pos = before_attrs;
                self.attrs.shrinkRetainingCapacity(attr_mark);
                break;
            },
            .kw_event => if (self.digital and blk.name != .none) {
                self.pos += 1;
                while (true) {
                    try events.append(self.arena, try self.expectIdent());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            } else {
                self.pos = before_attrs;
                self.attrs.shrinkRetainingCapacity(attr_mark);
                break;
            },
            else => { // else: not a declaration: the block's statements start here
                // The attributes just read prefix the first statement
                // (A.6.4), so they are handed back for `parseStmt`.
                self.pos = before_attrs;
                self.attrs.shrinkRetainingCapacity(attr_mark);
                break;
            },
        }
    }

    var body: std.ArrayList(Ast.StmtId) = .empty;
    while (!(if (parallel) self.reservedIs(self.pos, "join") else self.peek() == .kw_end) and self.peek() != .eof) {
        const before = self.pos;
        // A.6.3 `analog_seq_block ::= begin [ : id ... ] { analog_statement }`
        // has no null alternative, so a stray `;` here is E0219.
        const s = parseStmtNoNull(self) catch |e| {
            if (e == error.OutOfMemory) return e;
            self.recoverStatement(before);
            continue;
        };
        try body.append(self.arena, s);
    }
    if (parallel) {
        if (!self.reservedIs(self.pos, "join")) return self.failAt(self.pos, .E0207, "found {s}: no `join` closes the fork", .{self.found(self.pos)});
        self.pos += 1;
    } else _ = try self.expect(.kw_end);

    blk.params = params.items;
    blk.vars = vars.items;
    blk.events = events.items;
    blk.body = body.items;
    return self.file.addStmt(self.arena, .{ .block = blk }, tok);
}

/// Parses a §5.8.3 / A.6.7 case statement of `kind`, or, when `gen` is
/// non-null, a Syntax 6-8 `case_generate_construct ::= case
/// ( constant_expression ) case_generate_item { case_generate_item }
/// endcase` whose arm bodies are generate blocks appended to `gen`. The two
/// productions differ only in what an arm body is.
pub fn parseCase(self: *Parser, kind: Ast.CaseKind, gen: ?*parse_module.Body) Error!Ast.StmtId {
    const tok = self.pos;
    self.pos += 1; // 'case' / 'casex' / 'casez'
    _ = try self.expect(.lparen);
    const scrutinee = try parse_expr.parseExpr(self);
    _ = try self.expect(.rparen);

    var arms: std.ArrayList(Ast.CaseArm) = .empty;
    while (self.peek() != .kw_endcase and self.peek() != .eof) {
        try self.skipAttributes();
        var labels: std.ArrayList(Ast.ExprId) = .empty;
        if (self.eat(.kw_default)) {
            _ = self.eat(.colon); // A.6.7: `default [ : ]`
        } else {
            while (true) {
                try labels.append(self.arena, try parse_expr.parseExpr(self));
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.colon);
        }
        const body = if (gen) |b| try parse_generate.parseGenerateBlock(self, b) else try parseStmt(self);
        try arms.append(self.arena, .{ .labels = labels.items, .body = body });
    }
    _ = try self.expect(.kw_endcase);
    return self.file.addStmt(
        self.arena,
        .{ .case_stmt = .{
            .kind = kind,
            .scrutinee = scrutinee,
            .arms = arms.items,
            .is_generate = gen != null,
        } },
        tok,
    );
}

/// Parses an A.6.5 analog_event_control_statement (§5.10) from its `@`.
fn parseEventControl(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    self.pos += 1; // '@'
    // A.6.5 `event_control ::= … | @* | @ (*)`. Both spellings mean the
    // same implicit list and carry no expression, so the statement records
    // `.none` (`Ast.StmtKind.event_control`). The §2.9 attribute tokens split
    // `(*)` three ways: `(*` `)`, `(` `*)`, `(` `*` `)`.
    const star_toks: u32 = switch (self.peek()) {
        .star => 1,
        .attr_open => if (self.peekAt(1) == .rparen) 2 else 0,
        .lparen => if (self.peekAt(1) == .attr_close) 2 else if (self.peekAt(1) == .star and self.peekAt(2) == .rparen) 3 else 0,
        else => 0, // else: any other token after `@` starts an event expression or a name
    };
    if (star_toks != 0) {
        self.pos += star_toks;
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try parseStmt(self) } }, tok);
    }
    const event = try parseEvent(self);
    const body = try parseStmt(self);
    return self.file.addStmt(self.arena, .{ .event_control = .{ .event = event, .body = body } }, tok);
}

/// Parses an A.6.5 `delay_control` after the `#`: `( mintypmax_expression )`
/// or a `delay_value`.
fn parseDelay(self: *Parser) Error!Ast.ExprId {
    if (!self.eat(.lparen)) return parse_expr.parsePrimary(self);
    const value = try parse_expr.parseExpr(self);
    _ = try self.expect(.rparen);
    return value;
}

/// Parses an A.6.5 `event_control` after the `@`: `( event_expression )` or
/// `hierarchical_event_identifier`.
fn parseEvent(self: *Parser) Error!Ast.ExprId {
    if (self.eat(.lparen)) {
        const e = try parseEventExpr(self);
        _ = try self.expect(.rparen);
        return e;
    }
    const id_tok = self.pos;
    const name = try self.expectIdent();
    return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name });
}

/// Parses an A.6.5 analog_event_expression. `or` and `,` both build
/// `.event_or` (§4.2.2 puts them at the `||` level, below everything else).
fn parseEventExpr(self: *Parser) Error!Ast.ExprId {
    var lhs = try parseEventTerm(self);
    while (self.peek() == .kw_or or self.peek() == .comma) {
        const tok = self.pos;
        self.pos += 1;
        const rhs = try parseEventTerm(self);
        lhs = try self.file.exprs.add(self.arena, .{
            .tag = .event_or,
            .main_tok = tok,
            .lhs = lhs,
            .rhs = rhs,
        });
    }
    return lhs;
}

/// Parses one term of an event expression. §5.10.2 step events carry a list
/// of analysis name strings, not expressions (A.6.5); anything else is an
/// ordinary expression, and `cross`/`above`/`timer`/`absdelta` become
/// `.event_function` in `parsePrimary`.
pub fn parseEventTerm(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    // A.6.5 `event_expression ::= … | driver_update expression` is digital,
    // absent from `analog_event_expression`, and legal only in a §7.6
    // connect module (§9.22). Elsewhere the keyword falls through to
    // `parseExpr` and is "expected an expression" (§2.8.2).
    if (self.in_connect_module and self.peek() == .kw_driver_update) {
        self.pos += 1;
        const sig = try parse_expr.parseExpr(self);
        return self.file.exprs.add(self.arena, .{ .tag = .event_driver_update, .main_tok = tok, .lhs = sig });
    }
    // A.6.5 `event_expression ::= posedge expression | negedge expression`,
    // digital like `driver_update` but legal in any discrete event
    // expression.
    if (self.peek() == .kw_posedge or self.peek() == .kw_negedge) {
        const edge: Ast.ExprTag = if (self.peek() == .kw_posedge) .event_posedge else .event_negedge;
        self.pos += 1;
        const sig = try parse_expr.parseExpr(self);
        return self.file.exprs.add(self.arena, .{ .tag = edge, .main_tok = tok, .lhs = sig });
    }
    const tag: Ast.ExprTag = switch (self.peek()) {
        .kw_initial_step => .event_initial_step,
        .kw_final_step => .event_final_step,
        else => return parse_expr.parseExpr(self), // else: not a §5.10.2 global event, so an event expression
    };
    self.pos += 1;
    var names: std.ArrayList(Ast.StrId) = .empty;
    if (self.eat(.lparen)) {
        // A.6.5 makes the analysis list non-empty and the parenthesised
        // group optional, so `final_step()` has no derivation (annex G
        // Table G.2 item 13: "without arguments should not have
        // parenthesis").
        if (self.peek() == .rparen)
            try self.report(self.pos, .E0220, "after `{s}`", .{@tagName(tag)[6..]});
        if (self.peek() != .rparen) while (true) {
            const s = try self.expect(.string_literal);
            try names.append(self.arena, try parse_expr.internString(self, s));
            if (!self.eat(.comma)) break;
        };
        _ = try self.expect(.rparen);
    }
    const off = try self.file.exprs.addStrList(self.arena, names.items);
    return self.file.exprs.add(self.arena, .{ .tag = tag, .main_tok = tok, .extra = off });
}

/// Parses an A.6.9 `$task [ ( [expr] {, [expr]} ) ] ;` (Clause 9). The name
/// keeps its `$` so lowering reports it as written.
fn parseSysTask(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    // IEEE 1364-2005 §15.1: "no timing check can appear in procedural code".
    if (parse_specify.timing_checks.has(self.tokenText(tok)))
        return self.failAt(tok, .E0207, "`{s}` is a timing check, which only a specify block holds (§15.1)", .{self.tokenText(tok)});
    const name = try self.internTok(tok);
    self.pos += 1;
    var args: []const Ast.ExprId = &.{};
    if (self.peek() == .lparen) args = try parse_expr.parseCallArgs(self);
    _ = try self.expect(.semicolon);
    return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = name, .args = args } }, tok);
}

/// Parses a contribution (§5.6), an indirect contribution (§5.6.7) or a
/// procedural assignment (§5.7). One expression is parsed first (`<+`, `=`
/// and `:` bind looser than every Table 4-3 operator), then the operator
/// decides. In the discrete grammar also a nonblocking assignment or a task
/// enable. Anything else after the expression is E0214.
fn parseExprOrContributeStmt(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const lhs = if (self.discreteGrammar()) try parse_expr.parsePostfix(self) else try parse_expr.parseExpr(self);
    if (self.discreteGrammar() and self.eat(.lt_eq)) {
        const timing = try parseIntraTiming(self);
        const value = try parse_expr.parseExpr(self);
        _ = try self.expect(.semicolon);
        return self.file.addStmt(self.arena, .{ .assign = .{
            .target = lhs,
            .value = value,
            .nonblocking = true,
            .timing = timing.expr,
            .timing_is_delay = timing.is_delay,
            .timing_repeat = timing.count,
        } }, tok);
    }
    // A.6.4 `task_enable ::= hierarchical_task_identifier [ ( expression
    // { , expression } ) ] ;` (IEEE 1364-2005 §10.2.2). Recorded as a
    // `sys_task` row whose name has no `$`: a digital statement only, where
    // the engine tells the two apart by that first character.
    if (self.discreteGrammar() and self.peek() == .semicolon) {
        const ex = &self.file.exprs;
        if (ex.tag(lhs) == .ident or ex.tag(lhs) == .call) {
            self.pos += 1;
            const args: []const Ast.ExprId = if (ex.tag(lhs) == .call) ex.args(lhs) else &.{};
            return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = ex.strOf(lhs), .args = args } }, tok);
        }
    }
    switch (self.peek()) {
        .contribute => { // §5.6 / A.6.10
            self.pos += 1;
            const rhs = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, tok);
        },
        .assign_eq => { // §5.7 / A.6.2
            self.pos += 1;
            const timing = try parseIntraTiming(self);
            const value = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .assign = .{
                .target = lhs,
                .value = value,
                .timing = timing.expr,
                .timing_is_delay = timing.is_delay,
                .timing_repeat = timing.count,
            } }, tok);
        },
        .colon => { // §5.6.7 / A.6.10 indirect contribution
            self.pos += 1;
            const probe = try parse_expr.parsePrimary(self);
            _ = try self.expect(.eq_eq);
            const eqn = try parse_expr.parseExpr(self);
            _ = try self.expect(.semicolon);
            return self.file.addStmt(
                self.arena,
                .{ .indirect = .{ .lhs = lhs, .probe = probe, .eqn = eqn } },
                tok,
            );
        },
        else => return self.failAt(self.pos, .E0214, "found {s}", .{self.found(self.pos)}), // else: an lvalue is followed by `<+`, `=` or `:`: E0214
    }
}

/// Parses A.6.2's optional `delay_or_event_control` after the assignment
/// operator: A.6.5 `delay_control | event_control`. Analog has no such
/// production, so outside the discrete grammar this reads nothing and the
/// expression parser reports a `#` or `@`.
fn parseIntraTiming(self: *Parser) Error!struct { expr: Ast.ExprId, is_delay: bool, count: Ast.ExprId = .none } {
    if (!self.discreteGrammar()) return .{ .expr = .none, .is_delay = false };
    switch (self.peek()) {
        .hash => {
            self.pos += 1;
            return .{ .expr = try parseDelay(self), .is_delay = true };
        },
        .at => {
            self.pos += 1;
            return .{ .expr = try parseEvent(self), .is_delay = false };
        },
        // A.6.5 `repeat ( expression ) event_control`.
        .kw_repeat => {
            self.pos += 1;
            _ = try self.expect(.lparen);
            const count = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            _ = try self.expect(.at);
            return .{ .expr = try parseEvent(self), .is_delay = false, .count = count };
        },
        else => return .{ .expr = .none, .is_delay = false }, // else: no intra-assignment timing control
    }
}

/// Parses an A.6.8 `for` header assignment: an analog_variable_assignment
/// with no terminating `;`.
pub fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const target = try parse_expr.parseExpr(self);
    _ = try self.expect(.assign_eq);
    const value = try parse_expr.parseExpr(self);
    return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value } }, tok);
}
