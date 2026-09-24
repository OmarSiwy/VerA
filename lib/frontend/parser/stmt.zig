//! Annex A.6.4 analog_statement (LRM Clause 5).
//!
//! In: statement tokens inside an analog block or function. Out: `Ast.StmtId`s.
//!
//! LRM clauses this file's code cites: §4.7.1, §4.7.2.2, §5.6, §5.7, §5.8, §5.8.3, §5.9, §5.9.1, §5.9.2, §5.10, §5.10.4, §5.11.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_stmt.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_module = @import("module.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;
const found = Parser.found;

// -----------------------------------------------------------------------
// A.6.4 analog_statement — LRM ch5
// -----------------------------------------------------------------------

/// A.6.4 gives `analog_statement` NO null alternative. A bare `;` is only
/// derivable through `analog_statement_or_null`, which is reached from a
/// conditional arm, a case item and an event statement — exactly the three
/// survivors annex G.2.2 names in prose. `analog_seq_block` (A.6.3) takes
/// `{ analog_statement }` and `analog_construct` (A.6.2) takes one, so a
/// stray `;` in either is underivable.
///
/// The three legal sites call `parseStmt`; everywhere else calls this. It
/// reports and CARRIES ON — the `;` is consumed and `.empty` returned — so
/// the rest of the block is still parsed, a second mistake is still
/// reported, and `recoverStatement` is never involved.
pub fn parseStmtNoNull(self: *Parser) Error!Ast.StmtId {
    if (!self.digital and self.peek() == .semicolon)
        try self.report(self.pos, .E0219, "", .{});
    return parseStmt(self);
}

/// One analog statement (A.6.4). Outside the discrete context
/// (`discreteGrammar`), `fork`/`join`, `wait`, a task enable and the
/// procedural continuous assignments are NOT dispatched here: they fall
/// through to the expression statement and report "expected expression" —
/// they are not analog statements. `casex`/`casez` ARE dispatched, to
/// `parseCase`: §7.3.2 makes them analog statements in Verilog-AMS.
pub fn parseStmt(self: *Parser) Error!Ast.StmtId {
    const mark = self.attrs.items.len;
    try self.skipAttributes();
    // A.6.4 `{ attribute_instance } <statement>`: VerA's `vera_lte` is the one
    // attribute a statement keeps (`Ast.SourceFile.lte_attrs`). Read BEFORE
    // the body, whose own nested statements append their attributes after.
    const lte = self.lteSince(mark);
    const id = try parseStmtBody(self);
    if (lte) |a| try self.file.lte_attrs.append(self.arena, .{ .stmt = id, .value = a.value, .main_tok = a.main_tok });
    return id;
}

fn parseStmtBody(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    if (self.discreteGrammar() and self.eat(.hash)) {
        const delay = if (self.eat(.lparen)) blk: {
            const value = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            break :blk value;
        } else try parse_expr.parsePrimary(self);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = delay, .body = body, .kind = .delay } }, tok);
    }
    // A.6.5 `wait_statement ::= wait ( expression ) statement_or_null` —
    // digital only, like `#`: A.6.4 has no analog alternative for it.
    if (self.discreteGrammar() and self.peek() == .kw_wait) {
        self.pos += 1;
        _ = try self.expect(.lparen);
        const cond = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        const body = try parseStmt(self);
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = cond, .body = body, .kind = .level } }, tok);
    }
    // A.6.2 `procedural_continuous_assignments` (IEEE 1364-2005 §9.3) —
    // digital statements only: `assign`/`force lvalue = expr;`,
    // `deassign`/`release lvalue;`. §8.5.3.2 gives each its process.
    if (self.discreteGrammar()) {
        const kind: ?Ast.ProcContinuous = if (self.peek() == .kw_assign) .assign else if (parse_module.reservedIs(self, self.pos, "force")) .force else if (parse_module.reservedIs(self, self.pos, "deassign")) .deassign else if (parse_module.reservedIs(self, self.pos, "release")) .release else null;
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
    // "Continuously executes a statement") — digital only. A.6.8's
    // `analog_loop_statement` has repeat/while/for and NO forever: annex
    // G.2.1 retired the analog one, so outside the discrete context the
    // keyword falls through to the expression statement and is E0209, as
    // before. The body is `statement`, not `statement_or_null`, hence
    // `parseStmtNoNull`.
    //
    // Recorded as `while (1) body`: §9.6 gives the two the same meaning, and
    // one loop node keeps every walk over `Ast.StmtKind` (lowering, the
    // digital compiler, clone, the visitors) from growing a fifth arm that
    // would say the same thing as the `while` one. The `1` is an unsized
    // decimal (§2.6.1: signed, 32-bit) anchored on the `forever` token.
    if (self.discreteGrammar() and self.peek() == .kw_forever) {
        self.pos += 1;
        const always = try self.file.exprs.addIntLiteral(self.arena, tok, .{ .value = 1, .width = 0, .signed = true });
        const body = try parseStmtNoNull(self);
        return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = always, .body = body } }, tok);
    }
    // A.6.3 `par_block`, IEEE 1364-2005 §9.8.2 — digital only.
    if (self.digital and parse_module.reservedIs(self, self.pos, "fork")) return parseSeqBlock(self);
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
        // an event ARRAY, which A.2.1.3's `list_of_event_identifiers` cannot
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
            // is NOT a third spelling of §4.7.2.1's default. Outside a
            // function `return` has no return slot at all and lowering
            // owns that verdict (E0403).
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

/// §5.3.2 / A.6.3 analog_seq_block. Local declarations are only legal on a
/// named block; accepting them either way costs nothing and keeps the
/// diagnostic for the real error (an undeclared name) in lowering.
pub fn parseSeqBlock(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const parallel = self.peek() != .kw_begin; // `fork`
    self.pos += 1; // 'begin' / 'fork'
    var blk: Ast.SeqBlock = .{ .parallel = parallel };
    if (self.eat(.colon)) {
        const at = self.pos;
        blk.name = try self.expectIdent();
        // §4.7.1 bullet list: an analog function "shall not use named
        // blocks". Non-fatal, so the rest of the body is still parsed and
        // whatever else is wrong with it is reported in the same run.
        if (self.in_analog_fn) {
            var d = self.failWith(at, .E0226);
            d.msg("`{s}`", .{self.file.str(blk.name)});
            d.help("remove the label", .{});
            try d.emit();
        }
    }

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    while (true) {
        const before_attrs = self.pos;
        const attr_mark = self.attrs.items.len;
        try self.skipAttributes();
        switch (self.peek()) {
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
            },
            else => { // else: not a declaration: the block's statements start here
                // Not a declaration: the block's statements start here, and
                // the attributes just read prefix the first of them (A.6.4),
                // so they are handed back for `parseStmt` to read again.
                self.pos = before_attrs;
                self.attrs.shrinkRetainingCapacity(attr_mark);
                break;
            },
        }
    }

    var body: std.ArrayList(Ast.StmtId) = .empty;
    while (!(if (parallel) parse_module.reservedIs(self, self.pos, "join") else self.peek() == .kw_end) and self.peek() != .eof) {
        const before = self.pos;
        // A.6.3 `analog_seq_block ::= begin [ : id ... ] { analog_statement }`
        // — no null alternative, so a stray `;` here is E0219.
        const s = parseStmtNoNull(self) catch |e| {
            if (e == error.OutOfMemory) return e;
            self.recoverStatement(before);
            continue;
        };
        try body.append(self.arena, s);
    }
    if (parallel) {
        if (!parse_module.reservedIs(self, self.pos, "join")) return self.failAt(self.pos, .E0207, "found {s}: no `join` closes the fork", .{self.found(self.pos)});
        self.pos += 1;
    } else _ = try self.expect(.kw_end);

    blk.params = params.items;
    blk.vars = vars.items;
    blk.body = body.items;
    return self.file.addStmt(self.arena, .{ .block = blk }, tok);
}

/// Syntax 6-8 `case_generate_construct ::= case ( constant_expression )
/// case_generate_item { case_generate_item } endcase`.
///
/// §5.8.3 / A.6.7 analog_case_statement. `casex`/`casez` are out of the
/// analog subset (annex C.7); they parse here and `lowerCase` refuses the
/// kind, so the diagnostic names the rule instead of the grammar.
/// A.6.7 `case_statement`, and — when `gen` is non-null — Syntax 6-8's
/// `case_generate_construct`. The two productions differ in exactly one
/// place, what an arm body is: an `analog_statement_or_null` there, a
/// `generate_block_or_null` here.
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

/// A.6.5 analog_event_control_statement (§5.10).
pub fn parseEventControl(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    self.pos += 1; // '@'
    // A.6.5 `event_control ::= … | @* | @ (*)`. Both spellings mean the same
    // implicit list, and neither carries an expression at all, so the
    // statement records `.none` — see `Ast.StmtKind.event_control`.
    if (self.peek() == .star) {
        self.pos += 1;
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try parseStmt(self) } }, tok);
    }
    const event = if (self.eat(.lparen)) blk: {
        if (self.peek() == .star and self.peekAt(1) == .rparen) {
            self.pos += 2;
            return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try parseStmt(self) } }, tok);
        }
        const e = try parseEventExpr(self);
        _ = try self.expect(.rparen);
        break :blk e;
    } else blk: {
        // `@ hierarchical_event_identifier`
        const id_tok = self.pos;
        const name = try self.expectIdent();
        break :blk try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name });
    };
    const body = try parseStmt(self);
    return self.file.addStmt(self.arena, .{ .event_control = .{ .event = event, .body = body } }, tok);
}

/// A.6.5 analog_event_expression — `or` and `,` both build `.event_or`
/// (§4.2.2 puts them at the `||` precedence level, below everything else).
pub fn parseEventExpr(self: *Parser) Error!Ast.ExprId {
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

/// §5.10.2 step events carry a list of *analysis name strings*, not
/// expressions (A.6.5); everything else is an ordinary expression —
/// `cross`/`above`/`timer`/`absdelta` become `.event_function` in
/// `parsePrimary`.
pub fn parseEventTerm(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    // A.6.5 `event_expression ::= … | driver_update expression` — DIGITAL,
    // and it appears in `event_expression`, never in
    // `analog_event_expression`, so it is legal only in the discrete context
    // of a §7.6 connect module (§9.22 paragraph 3). Outside one the keyword
    // falls through to `parseExpr` and is the ordinary "expected an
    // expression" — a keyword is not an identifier (§2.8.2).
    if (self.in_connect_module and self.peek() == .kw_driver_update) {
        self.pos += 1;
        const sig = try parse_expr.parseExpr(self);
        return self.file.exprs.add(self.arena, .{ .tag = .event_driver_update, .main_tok = tok, .lhs = sig });
    }
    // A.6.5 `event_expression ::= posedge expression | negedge expression`
    // — DIGITAL like `driver_update`, but legal in any discrete event
    // expression, not only a connect module's.
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
        // A.6.5 makes the analysis list NON-EMPTY and the whole
        // parenthesised group optional, so `final_step()` has no
        // derivation — annex G Table G.2 item 13 says it in prose
        // ("without arguments should not have parenthesis").
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

/// A.6.9 `$task [ ( [expr] {, [expr]} ) ] ;` — ch9 system tasks. The name
/// keeps its `$` so lowering reports it the way the user wrote it.
pub fn parseSysTask(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const name = try self.internTok(tok);
    self.pos += 1;
    var args: []const Ast.ExprId = &.{};
    if (self.peek() == .lparen) args = try parse_expr.parseCallArgs(self);
    _ = try self.expect(.semicolon);
    return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = name, .args = args } }, tok);
}

/// Contribution vs procedural-assignment disambiguation. LRM §5.6, §5.7.
/// One expression is parsed first (`<+`, `=` and `:` all bind looser than
/// every operator in Table 4-3), then the operator decides the statement.
pub fn parseExprOrContributeStmt(self: *Parser) Error!Ast.StmtId {
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

/// A.6.2's optional `delay_or_event_control` after the assignment operator
/// — A.6.5 `delay_control | event_control | repeat ( expression )
/// event_control`. Analog has no such production, so it is recognized only
/// in a digital source; elsewhere `#`/`@` fall through and the expression
/// parser reports them.
///
/// ponytail: no `repeat ( n ) @(e)`. A.6.5's third alternative needs a
/// countdown around the waiter and nothing asks for it yet; add it beside
/// the `.at` arm when something does.
pub fn parseIntraTiming(self: *Parser) Error!struct { expr: Ast.ExprId, is_delay: bool } {
    if (!self.discreteGrammar()) return .{ .expr = .none, .is_delay = false };
    switch (self.peek()) {
        .hash => {
            self.pos += 1;
            if (self.eat(.lparen)) {
                const value = try parse_expr.parseExpr(self);
                _ = try self.expect(.rparen);
                return .{ .expr = value, .is_delay = true };
            }
            return .{ .expr = try parse_expr.parsePrimary(self), .is_delay = true };
        },
        .at => {
            self.pos += 1;
            if (self.eat(.lparen)) {
                const e = try parseEventExpr(self);
                _ = try self.expect(.rparen);
                return .{ .expr = e, .is_delay = false };
            }
            const id_tok = self.pos;
            const name = try self.expectIdent();
            return .{ .expr = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name }), .is_delay = false };
        },
        else => return .{ .expr = .none, .is_delay = false }, // else: no intra-assignment timing control
    }
}

/// A.6.8 `for` header assignment — an analog_variable_assignment with no
/// terminating `;`.
pub fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId {
    const tok = self.pos;
    const target = try parse_expr.parseExpr(self);
    _ = try self.expect(.assign_eq);
    const value = try parse_expr.parseExpr(self);
    return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value } }, tok);
}
