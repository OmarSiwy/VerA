//! Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1).
//!
//! In: tokens from `specify` to `endspecify`, and module-level `specparam`.
//! Out: `ModuleDecl.paths` and `.timing_checks`, and specparams as local parameters.
//!
//! LRM clauses cited: §1.1, §2.8, §3.4.1, §3.4.5, §8, §11.6.15, §14.2.6.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.7 specify blocks: LRM §1.1 (1364 is part of the language), §8
// -----------------------------------------------------------------------

/// Parses one A.7.1 `specify_block ::= specify { specify_item } endspecify`
/// into `b.paths` and `b.timing_checks`, then warns W0251.
///
/// The block is legal source under §1.1, and annex C.16 does not exempt it.
/// Its content is §8 scheduling (A.7.2 path delays, A.7.5 timing checks):
/// §11.6.15's VPI objects read what is recorded, but no simulation applies
/// it, which is what W0251 says. The block is parsed rather than skipped so
/// a typo in a path declaration is still an error.
pub fn parseSpecifyBlock(self: *Parser, b: *parse_module.Body) Error!void {
    const open = self.pos;
    self.pos += 1; // `specify`
    while (!self.reservedIs(self.pos, "endspecify")) {
        if (self.peek() == .eof or self.peek() == .kw_endmodule)
            return self.failAt(self.pos, .E0207, "found {s}: no `endspecify` closes the specify block", .{self.found(self.pos)});
        try parseSpecifyItem(self, b);
    }
    self.pos += 1; // `endspecify`
    try self.bag.add(
        .parse,
        .W0251,
        lexer.tokenSpan(self.src, self.starts, open),
        "",
        .{},
    );
}

/// Parses one A.7.1 `specify_item`, any of the five arms:
///
///     specify_item ::=
///             specparam_declaration
///             | pulsestyle_declaration
///             | showcancelled_declaration
///             | path_declaration
///             | system_timing_check
fn parseSpecifyItem(self: *Parser, b: *parse_module.Body) Error!void {
    switch (self.peek()) {
        .kw_reserved => {
            const w = self.tokenText(self.pos);
            // A.2.1.1's declaration as a specify_item. The list is
            // discarded: a specparam declared inside the block is scoped to
            // it, and the block is not elaborated.
            if (std.mem.eql(u8, w, "specparam")) return parseSpecparamDecl(self, null);
            // A.7.1 `pulsestyle_declaration` / `showcancelled_declaration`,
            // four keywords over one `list_of_path_outputs ;`.
            if (std.mem.eql(u8, w, "pulsestyle_onevent") or
                std.mem.eql(u8, w, "pulsestyle_ondetect") or
                std.mem.eql(u8, w, "showcancelled") or
                std.mem.eql(u8, w, "noshowcancelled"))
            {
                self.pos += 1;
                // A.7.2's `list_of_path_outputs` has no parentheses of its
                // own; §14.2.6's examples write them, so one pair is taken
                // if it is there.
                const paren = self.eat(.lparen);
                _ = try parseSpecifyTerminalList(self);
                if (paren) _ = try self.expect(.rparen);
                _ = try self.expect(.semicolon);
                return;
            }
            // A.7.2 `state_dependent_path_declaration ::= … | ifnone
            // simple_path_declaration`.
            if (std.mem.eql(u8, w, "ifnone")) {
                self.pos += 1;
                return parsePathDeclaration(self, b, .none, true);
            }
            return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)});
        },
        // A.7.2 `state_dependent_path_declaration ::= if ( module_path_expression )`
        // followed by a simple or edge-sensitive path.
        .kw_if => {
            self.pos += 1;
            _ = try self.expect(.lparen);
            const cond = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            return parsePathDeclaration(self, b, cond, false);
        },
        .lparen => return parsePathDeclaration(self, b, .none, false),
        .system_identifier => return parseTimingCheck(self, b),
        else => return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)}), // else: begins no A.7.1 specify_item: E0207
    }
}

/// Parses A.7.3 `specify_input_terminal_descriptor ::= input_identifier
/// [ [ constant_range_expression ] ]` or its output twin. They differ only
/// in which port directions the name may have, which is judged where the
/// ports are known, not here.
fn parseSpecifyTerminal(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    const name = try self.expectIdent();
    const e = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    return if (self.peek() == .lbracket) parse_expr.parseSelect(self, e) else e;
}

/// Parses A.7.2 `list_of_path_inputs` or `list_of_path_outputs`, the same
/// comma-separated run of A.7.3 descriptors under two names. Returns an
/// arena slice of at least one descriptor.
fn parseSpecifyTerminalList(self: *Parser) Error![]const Ast.ExprId {
    var out: std.ArrayList(Ast.ExprId) = .empty;
    while (true) {
        try out.append(self.arena, try parseSpecifyTerminal(self));
        if (!self.eat(.comma)) return out.items;
    }
}

/// Parses one A.7.2 `path_declaration` into `b.paths`, any arm:
///
///     parallel_path_description ::=
///             ( specify_input_terminal_descriptor [ polarity_operator ]
///               => specify_output_terminal_descriptor )
///     full_path_description ::=
///             ( list_of_path_inputs [ polarity_operator ] *> list_of_path_outputs )
///     parallel_edge_sensitive_path_description ::=
///             ( [ edge_identifier ] specify_input_terminal_descriptor =>
///               ( specify_output_terminal_descriptor [ polarity_operator ]
///                 : data_source_expression ) )
///
/// The descriptions differ only in which optional pieces are present:
/// `=>` versus `*>` chooses parallel from full, and a `(` after the arrow
/// chooses edge-sensitive from simple. The caller has consumed any
/// `if (…)` or `ifnone` prefix, passed as `cond` and `ifnone`.
fn parsePathDeclaration(self: *Parser, b: *parse_module.Body, cond: Ast.ExprId, ifnone: bool) Error!void {
    const main_tok = self.pos;
    _ = try self.expect(.lparen);
    // A.7.4 `edge_identifier ::= posedge | negedge`, present only on the
    // two edge-sensitive descriptions.
    const edge: Ast.SpecEdge = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    const src_tok = self.pos;
    const sources = try parseSpecifyTerminalList(self);
    // A.7.4 `polarity_operator ::= + | -`.
    const polarity = eatPolarity(self);
    const parallel = self.eatSymbol("=>");
    if (!parallel and !self.eatSymbol("*>")) return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a path description connects its terminals with `=>` or `*>`",
        .{self.found(self.pos)},
    );
    // A.7.2: both `=>` arms put one `specify_input_terminal_descriptor`
    // before the arrow and one output descriptor after it; lists are the
    // full path's (`*>`).
    const dst_tok = self.pos;
    var data: Ast.ExprId = .none;
    var data_polarity: Ast.SpecPolarity = .none;
    const outputs = if (self.eat(.lparen)) edge: {
        // The edge-sensitive arms: the outputs, a polarity and the
        // `data_source_expression` the path's value comes from.
        const outs = try parseSpecifyTerminalList(self);
        data_polarity = eatPolarity(self);
        _ = try self.expect(.colon);
        data = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        break :edge outs;
    } else try parseSpecifyTerminalList(self);
    if (parallel and (sources.len != 1 or outputs.len != 1)) return self.failAt(
        if (sources.len != 1) src_tok else dst_tok,
        .E0207,
        "a parallel path (`=>`) connects one source to one destination, and this one lists {d} source(s) and {d} destination(s); lists need the full path `*>` (A.7.2)",
        .{ sources.len, outputs.len },
    );
    _ = try self.expect(.rparen);
    _ = try self.expect(.assign_eq);
    // A.7.4 `path_delay_value ::= list_of_path_delay_expressions
    // | ( list_of_path_delay_expressions )`. The parenthesis is read here,
    // not by `parseExpr`, because `( tplh , tphl )` is a list of two.
    const bracketed = self.eat(.lparen);
    const delay_tok = self.pos;
    var delays: std.ArrayList(Ast.ExprId) = .empty;
    while (true) {
        try delays.append(self.arena, try parse_expr.parseExpr(self));
        if (!self.eat(.comma)) break;
    }
    // A.7.4 `list_of_path_delay_expressions` has five arms: one value,
    // rise/fall, rise/fall/z, the six transition delays and the twelve.
    switch (delays.items.len) {
        1, 2, 3, 6, 12 => {},
        else => return self.failAt(
            delay_tok,
            .E0207,
            "a path delay lists 1, 2, 3, 6 or 12 values (A.7.4 list_of_path_delay_expressions), not {d}",
            .{delays.items.len},
        ),
    }
    if (bracketed) _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    try b.paths.append(self.arena, .{
        .full = !parallel,
        .edge = edge,
        .polarity = polarity,
        .cond = cond,
        .ifnone = ifnone,
        .ins = sources,
        .outs = outputs,
        .data = data,
        .data_polarity = data_polarity,
        .delays = delays.items,
        .main_tok = main_tok,
    });
}

fn eatPolarity(self: *Parser) Ast.SpecPolarity {
    if (self.eat(.plus)) return .positive;
    if (self.eat(.minus)) return .negative;
    return .none;
}

/// A.7.5.1's twelve `system_timing_check` commands and their argument
/// counts `{ mandatory, mandatory + optional }`, counted off A.7.5.1: e.g.
/// `$setup ( data_event , reference_event , timing_check_limit
/// [ , [ notifier ] ] ) ;` is 3 and 4.
pub const timing_checks = std.StaticStringMap(struct { u8, u8 }).initComptime(.{
    .{ "$setup", .{ 3, 4 } },
    .{ "$hold", .{ 3, 4 } },
    .{ "$setuphold", .{ 4, 9 } },
    .{ "$recovery", .{ 3, 4 } },
    .{ "$removal", .{ 3, 4 } },
    .{ "$recrem", .{ 4, 9 } },
    .{ "$skew", .{ 3, 4 } },
    .{ "$timeskew", .{ 3, 6 } },
    .{ "$fullskew", .{ 4, 7 } },
    .{ "$period", .{ 2, 3 } },
    .{ "$width", .{ 2, 4 } },
    .{ "$nochange", .{ 4, 5 } },
});

/// The two commands whose first argument is a `controlled_reference_event`.
const controlled_first = std.StaticStringMap(void).initComptime(.{ .{"$period"}, .{"$width"} });

/// Parses one A.7.5.1 `system_timing_check` into `b.timing_checks`. A.7.1
/// admits no other system task in a specify block, so a name not in
/// `timing_checks` is E0207, as is a wrong argument count.
fn parseTimingCheck(self: *Parser, b: *parse_module.Body) Error!void {
    const tok = self.pos;
    var args: std.ArrayList(Ast.ExprId) = .empty;
    var edges: std.ArrayList(Ast.SpecEdge) = .empty;
    const arity = timing_checks.get(self.tokenText(tok)) orelse return self.failAt(
        tok,
        .E0207,
        "found {s}: A.7.1 admits only A.7.5.1's twelve timing checks inside a specify block",
        .{self.found(tok)},
    );
    self.pos += 1;
    _ = try self.expect(.lparen);
    var n: u8 = 0;
    if (self.peek() != .rparen) while (true) {
        // A.7.5.1 writes the optional arguments `[ , [ notifier ] ]`, the
        // comma outside the inner bracket, so a slot may be present and
        // empty. That is why an argument is counted before it is read.
        n +|= 1;
        const arg = self.pos;
        var slot: Ast.ExprId = .none;
        var ev: Ast.SpecEdge = .none;
        const controlled = self.peek() != .comma and self.peek() != .rparen and try parseTimingCheckArg(self, &slot, &ev);
        try args.append(self.arena, slot);
        try edges.append(self.arena, ev);
        // A.7.5.1: `$period` and `$width` open with a
        // `controlled_reference_event`, and A.7.5.3's
        // `controlled_timing_check_event` makes its event control
        // mandatory, unlike `timing_check_event`'s bracketed one.
        if (n == 1 and !controlled and controlled_first.has(self.tokenText(tok))) return self.failAt(
            arg,
            .E0207,
            "`{s}` timing check requires an event control (posedge, negedge or edge) on its reference event (A.7.5.3 controlled_timing_check_event)",
            .{self.tokenText(tok)},
        );
        // A.7.5.2 `notifier ::= variable_identifier`, the reg a violation
        // toggles. A.7.5.1 puts it first among the optional arguments of
        // every command, except `$width`, whose optional `threshold` comes
        // before it.
        const notifier: u8 = if (std.mem.eql(u8, self.tokenText(tok), "$width")) 4 else arity[0] + 1;
        if (n == notifier and self.pos != arg and
            !(self.pos == arg + 1 and (self.tags[arg] == .identifier or self.tags[arg] == .escaped_identifier)))
            return self.failAt(arg, .E0207, "found {s}: the notifier argument of `{s}` names a variable (A.7.5.2 notifier ::= variable_identifier)", .{ self.found(arg), self.tokenText(tok) });
        if (!self.eat(.comma)) break;
    };
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    if (n < arity[0] or n > arity[1]) return self.failAt(
        tok,
        .E0207,
        "`{s}` takes {d} to {d} arguments, not {d}",
        .{ self.tokenText(tok), arity[0], arity[1], n },
    );
    try b.timing_checks.append(self.arena, .{
        .name = try self.internTok(tok),
        .args = args.items,
        .edges = edges.items,
        .main_tok = tok,
    });
}

/// Parses one argument of an A.7.5.1 command into `slot` and `ev`, and
/// returns whether it had an event control. A.7.5.2's argument productions
/// are all `expression` except the two event slots, which A.7.5.3 gives a
/// prefix and a suffix:
///
///     timing_check_event ::= [ timing_check_event_control ]
///             specify_terminal_descriptor [ &&& timing_check_condition ]
///     timing_check_event_control ::= posedge | negedge | edge_control_specifier
///
/// Every argument accepts that union; `parseTimingCheck` enforces the
/// mandatory control of a `controlled_reference_event` (`$period`,
/// `$width`).
fn parseTimingCheckArg(self: *Parser, slot: *Ast.ExprId, ev: *Ast.SpecEdge) Error!bool {
    ev.* = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    var controlled = ev.* != .none;
    if (!controlled and self.reservedIs(self.pos, "edge")) {
        controlled = true;
        ev.* = .edge;
        // A.7.5.3 `edge_control_specifier ::= edge [ edge_descriptor
        // { , edge_descriptor } ]`. The descriptors are two-character
        // symbols (`01`, `z1`, `0x`) that lex as numbers or identifiers
        // depending on their characters, so the bracket is skipped as a
        // balanced run.
        // ponytail: an unchecked descriptor set. A table of the ten
        // spellings A.7.5.3 admits is the upgrade; no fixture asks.
        self.pos += 1;
        if (self.eat(.lbracket)) while (!self.eat(.rbracket)) {
            if (self.peek() == .eof) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
            self.pos += 1;
        };
    }
    slot.* = try parse_expr.parseExpr(self);
    // A.7.5.3's `&&&`, which is three tokens' worth of `&` in a stream that
    // has no tag for it.
    if (self.eatSymbol("&&&")) _ = try parse_expr.parseExpr(self);
    return controlled;
}

/// Parses one A.2.1.1 `specparam_declaration ::= specparam [ range ]
/// list_of_specparam_assignments ;` with A.2.4's assignments:
///
///     specparam_assignment ::=
///             specparam_identifier = constant_mintypmax_expression
///             | pulse_control_specparam
///
/// `out` is the module's parameter list for the Syntax 6-1 module-item
/// form, where each specparam becomes a §3.4.5 `localparam` (a constant
/// with a mandatory default that no `parameter_value_assignment` can name).
/// `out` is null for an A.7.1 `specify_item`, whose specparams are scoped to
/// a block this compiler does not elaborate.
///
/// A.2.4's `pulse_control_specparam` (`PATHPULSE$ = ( … )`) is not read: §2.8
/// admits no `$` in an identifier, so the lexer cannot produce its name.
pub fn parseSpecparamDecl(self: *Parser, out: ?*std.ArrayList(Ast.ParamDecl)) Error!void {
    // ponytail: 1364's specparams are what SDF back-annotation overrides,
    // and a `localparam` cannot be overridden. VerA reads no SDF; reading
    // it needs separate storage.
    self.pos += 1; // `specparam`
    const packed_range: ?Ast.Dim = try parse_decl.optDim(self);
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        _ = try self.expect(.assign_eq);
        const default = try parse_expr.parseExpr(self);
        if (out) |o| try o.append(self.arena, .{
            .name = name,
            .ty = .unspecified, // §3.4.1: derived from the default, as for `parameter`
            .default = default,
            .is_local = true,
            .packed_range = packed_range,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
