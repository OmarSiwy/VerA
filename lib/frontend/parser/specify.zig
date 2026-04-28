//! Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1).
//!
//! In: tokens from `specify` to `endspecify`. Out: the parsed block, so a clause-level rule
//! (W0253), not a token error, answers it.
//!
//! LRM clauses this file's code cites: §1.1, §2.8, §3.4.1, §3.4.5, §8, §11.6.15, §14.2.6.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_specify.f(self, ...)`; `parser.zig` aliases only what other modules call.

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
// A.7 specify blocks — LRM §1.1 (1364 is part of the language), §8
// -----------------------------------------------------------------------

/// A.7.1 `specify_block ::= specify { specify_item } endspecify`.
///
/// READ IN FULL AND MODELLED BY NOTHING (W0251) — W0250's shape, and the
/// reasoning is that entry's. The block is legal source under §1.1, and
/// annex C.16 does not exempt it (`specify` is not one of the spellings
/// that clause lists as unused by Verilog-A), so refusing it was refusing
/// text the standard requires a full-AMS compiler to take. Its content is
/// entirely §8 scheduling — A.7.2 path delays, A.7.5 system timing checks —
/// and a compiled analog device has no event queue to schedule a path delay
/// on, so there is nothing to record and nothing that could read it.
///
/// PARSED, not skipped to `endspecify`. A token skip would accept any text
/// at all between the keywords, which is a strictly weaker claim than the
/// annex makes and would let a typo in a path declaration ship silently.
// The paths and timing checks ARE recorded (`ModuleDecl.paths`,
// `.timing_checks`): §11.6.15's VPI objects read them. No simulation applies
// them, which is what W0251 still says.
pub fn parseSpecifyBlock(self: *Parser, b: *parse_module.Body) Error!void {
    const open = self.pos;
    self.pos += 1; // `specify`
    while (!parse_module.reservedIs(self, self.pos, "endspecify")) {
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

/// A.7.1 `specify_item`, all five arms:
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
            const w = parse_expr.tokenText(self, self.pos);
            // A.2.1.1's declaration, here as a specify_item. The list is
            // DISCARDED rather than appended to the module's parameters:
            // a specparam declared inside the block is scoped to it, and
            // the block is not elaborated.
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

/// A.7.3 `specify_input_terminal_descriptor ::= input_identifier
/// [ [ constant_range_expression ] ]` and its output twin, which differ
/// only in which port directions the identifier may name — a rule about
/// the NAME, judged where the ports are known, not here.
fn parseSpecifyTerminal(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    const name = try self.expectIdent();
    const e = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    return if (self.peek() == .lbracket) parse_expr.parseSelect(self, e) else e;
}

/// A.7.2 `list_of_path_inputs` / `list_of_path_outputs` — the same
/// comma-separated run of A.7.3 descriptors under two names. Returns how
/// many it read, for the parallel path's one-to-one rule.
fn parseSpecifyTerminalList(self: *Parser) Error![]const Ast.ExprId {
    var out: std.ArrayList(Ast.ExprId) = .empty;
    while (true) {
        try out.append(self.arena, try parseSpecifyTerminal(self));
        if (!self.eat(.comma)) return out.items;
    }
}

/// A.7.2 `path_declaration`, all three arms and both descriptions:
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
/// One routine for all of them, because the four descriptions differ only
/// in which optional pieces are present and the grammar disambiguates each
/// one by a token the cursor is already on: `=>` versus `*>` chooses
/// parallel from full, and a `(` after the arrow chooses edge-sensitive
/// from simple. The caller has consumed any `if (…)` or `ifnone` prefix.
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
    const parallel = parse_module.eatSymbol(self, "=>");
    if (!parallel and !parse_module.eatSymbol(self, "*>")) return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a path description connects its terminals with `=>` or `*>`",
        .{self.found(self.pos)},
    );
    // A.7.2: both `=>` arms put ONE `specify_input_terminal_descriptor`
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
    // | ( list_of_path_delay_expressions )`. The parenthesis is read HERE
    // and not by `parseExpr`, because `( tplh , tphl )` is a list of two
    // and a parenthesized expression is one.
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

/// A.7.5.1's twelve `system_timing_check` commands, as the argument counts
/// their productions give them. The whole content of the clause that a
/// parser can check is the NAME and the ARITY: every command is
/// `$name ( arg { , arg } ) ;`, and the arms differ only in how many
/// arguments are mandatory and how many optional brackets follow.
///
/// The pairs are `{ mandatory, mandatory + optional }`, counted straight
/// off A.7.5.1 — e.g. `$setup ( data_event , reference_event ,
/// timing_check_limit [ , [ notifier ] ] ) ;` is 3 and 4.
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

/// A.7.5.1 `system_timing_check`. A `$name` inside a specify block is one
/// of exactly twelve commands — A.7.1 admits no other system task there —
/// so a name the table does not hold is an error rather than a call.
fn parseTimingCheck(self: *Parser, b: *parse_module.Body) Error!void {
    const tok = self.pos;
    var args: std.ArrayList(Ast.ExprId) = .empty;
    var edges: std.ArrayList(Ast.SpecEdge) = .empty;
    const arity = timing_checks.get(parse_expr.tokenText(self, tok)) orelse return self.failAt(
        tok,
        .E0207,
        "found {s}: A.7.1 admits only A.7.5.1's twelve timing checks inside a specify block",
        .{self.found(tok)},
    );
    self.pos += 1;
    _ = try self.expect(.lparen);
    var n: u8 = 0;
    if (self.peek() != .rparen) while (true) {
        // A.7.5.1 writes the optional arguments `[ , [ notifier ] ]` — the
        // comma outside the inner bracket, so the slot may be present and
        // EMPTY. That is why an argument is counted before it is read.
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
        // MANDATORY, unlike `timing_check_event`'s bracketed one.
        if (n == 1 and !controlled and controlled_first.has(parse_expr.tokenText(self, tok))) return self.failAt(
            arg,
            .E0207,
            "`{s}` timing check requires an event control (posedge, negedge or edge) on its reference event (A.7.5.3 controlled_timing_check_event)",
            .{parse_expr.tokenText(self, tok)},
        );
        // A.7.5.2 `notifier ::= variable_identifier` — the reg a violation
        // toggles. A.7.5.1 puts it first among the optional arguments of
        // every command, except `$width`, whose optional `threshold` comes
        // before it.
        const notifier: u8 = if (std.mem.eql(u8, parse_expr.tokenText(self, tok), "$width")) 4 else arity[0] + 1;
        if (n == notifier and self.pos != arg and
            !(self.pos == arg + 1 and (self.tags[arg] == .identifier or self.tags[arg] == .escaped_identifier)))
            return self.failAt(arg, .E0207, "found {s}: the notifier argument of `{s}` names a variable (A.7.5.2 notifier ::= variable_identifier)", .{ self.found(arg), parse_expr.tokenText(self, tok) });
        if (!self.eat(.comma)) break;
    };
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    if (n < arity[0] or n > arity[1]) return self.failAt(
        tok,
        .E0207,
        "`{s}` takes {d} to {d} arguments, not {d}",
        .{ parse_expr.tokenText(self, tok), arity[0], arity[1], n },
    );
    try b.timing_checks.append(self.arena, .{
        .name = try self.internTok(tok),
        .args = args.items,
        .edges = edges.items,
        .main_tok = tok,
    });
}

/// One argument of A.7.5.1's commands. The clause's argument productions
/// (A.7.5.2) are `expression` under a dozen names — `timing_check_limit`,
/// `threshold`, `notifier`, the two offsets — except for the two event
/// slots, which A.7.5.3 gives a prefix and a suffix:
///
///     timing_check_event ::= [ timing_check_event_control ]
///             specify_terminal_descriptor [ &&& timing_check_condition ]
///     timing_check_event_control ::= posedge | negedge | edge_control_specifier
///
/// One routine takes the union and returns whether an event control was
/// read; `parseTimingCheck` enforces the MANDATORY one of a
/// `controlled_reference_event` (`$period`, `$width`). The union means
/// every optional piece of A.7.5.3 is read rather than skipped.
fn parseTimingCheckArg(self: *Parser, slot: *Ast.ExprId, ev: *Ast.SpecEdge) Error!bool {
    ev.* = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    var controlled = ev.* != .none;
    if (!controlled and parse_module.reservedIs(self, self.pos, "edge")) {
        controlled = true;
        ev.* = .edge;
        // A.7.5.3 `edge_control_specifier ::= edge [ edge_descriptor
        // { , edge_descriptor } ]`. The descriptors are two-character
        // symbols (`01`, `z1`, `0x`) that reach here as numbers or
        // identifiers depending on which characters they hold, so the
        // bracket is read as a balanced run rather than as a list of
        // values nothing would consume.
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
    if (parse_module.eatSymbol(self, "&&&")) _ = try parse_expr.parseExpr(self);
    return controlled;
}

/// A.2.1.1 `specparam_declaration ::= specparam [ range ]
/// list_of_specparam_assignments ;`, and A.2.4:
///
///     specparam_assignment ::=
///             specparam_identifier = constant_mintypmax_expression
///             | pulse_control_specparam
///
/// `out` is the module's parameter list for the Syntax 6-1 module-item
/// form and `null` for an A.7.1 `specify_item`, whose specparams are scoped
/// to a block this compiler does not elaborate.
///
/// A LOCALPARAM is what the module-item form becomes: a specparam is a
/// constant with a mandatory default and no `parameter_value_assignment`
/// can name it, which is exactly `localparam`'s shape in §3.4.5.
// ponytail: that is an approximation with a known edge. 1364's specparams
// are the values an SDF back-annotation overrides, and a `localparam`
// cannot be overridden by anything. VerA reads no SDF, so the two are
// indistinguishable here; the day it does, this needs its own storage.
//
// `pulse_control_specparam` — A.2.4's `PATHPULSE$ = ( … )` arm — is not
// read. Its identifier holds a `$`, which §2.8 does not admit in an
// identifier at all, so it is not a token this lexer can produce.
pub fn parseSpecparamDecl(self: *Parser, out: ?*std.ArrayList(Ast.ParamDecl)) Error!void {
    self.pos += 1; // `specparam`
    const packed_range: ?Ast.Dim = try parse_decl.optDim(self);
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        _ = try self.expect(.assign_eq);
        const default = try parse_expr.parseExpr(self);
        if (out) |o| try o.append(self.arena, .{
            .name = name,
            .ty = .unspecified, // §3.4.1 — derived from the default, as for `parameter`
            .default = default,
            .is_local = true,
            .packed_range = packed_range,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
