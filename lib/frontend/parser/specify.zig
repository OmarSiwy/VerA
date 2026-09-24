//! Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1).
//!
//! In: tokens from `specify` to `endspecify`. Out: the parsed block, so a clause-level rule
//! (W0253), not a token error, answers it.
//!
//! LRM clauses this file's code cites: §1, §1.1, §2.8, §2.9, §3.4.1, §3.4.5, §6.2.2, §6.3, §7.2.2, §8, §8.5.3.5, §9.18.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_specify.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;
const found = Parser.found;

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
// ponytail: nothing is recorded, because nothing consumes it — same call as
// `parsePassSwitch`. The upgrade path is a discrete half in `Flatten`, and
// until that exists an AST field for a path delay is dead weight.
pub fn parseSpecifyBlock(self: *Parser) Error!void {
    const open = self.pos;
    self.pos += 1; // `specify`
    while (!parse_module.reservedIs(self, self.pos, "endspecify")) {
        if (self.peek() == .eof or self.peek() == .kw_endmodule)
            return self.failAt(self.pos, .E0207, "found {s}: no `endspecify` closes the specify block", .{self.found(self.pos)});
        try parseSpecifyItem(self);
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
pub fn parseSpecifyItem(self: *Parser) Error!void {
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
                return parsePathDeclaration(self);
            }
            return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)});
        },
        // A.7.2 `state_dependent_path_declaration ::= if ( module_path_expression )`
        // followed by a simple or edge-sensitive path.
        .kw_if => {
            self.pos += 1;
            _ = try self.expect(.lparen);
            _ = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            return parsePathDeclaration(self);
        },
        .lparen => return parsePathDeclaration(self),
        .system_identifier => return parseTimingCheck(self),
        else => return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)}), // else: begins no A.7.1 specify_item: E0207
    }
}

/// A.7.3 `specify_input_terminal_descriptor ::= input_identifier
/// [ [ constant_range_expression ] ]` and its output twin, which differ
/// only in which port directions the identifier may name — a rule about
/// the NAME, judged where the ports are known, not here.
pub fn parseSpecifyTerminal(self: *Parser) Error!void {
    _ = try self.expectIdent();
    if (!self.eat(.lbracket)) return;
    _ = try parse_expr.parseExpr(self);
    if (self.eat(.colon)) _ = try parse_expr.parseExpr(self);
    _ = try self.expect(.rbracket);
}

/// A.7.2 `list_of_path_inputs` / `list_of_path_outputs` — the same
/// comma-separated run of A.7.3 descriptors under two names. Returns how
/// many it read, for the parallel path's one-to-one rule.
pub fn parseSpecifyTerminalList(self: *Parser) Error!u32 {
    var n: u32 = 0;
    while (true) {
        try parseSpecifyTerminal(self);
        n += 1;
        if (!self.eat(.comma)) return n;
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
pub fn parsePathDeclaration(self: *Parser) Error!void {
    _ = try self.expect(.lparen);
    // A.7.4 `edge_identifier ::= posedge | negedge`, present only on the
    // two edge-sensitive descriptions.
    _ = self.eat(.kw_posedge) or self.eat(.kw_negedge);
    const src_tok = self.pos;
    const sources = try parseSpecifyTerminalList(self);
    // A.7.4 `polarity_operator ::= + | -`.
    _ = self.eat(.plus) or self.eat(.minus);
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
    const outputs = if (self.eat(.lparen)) edge: {
        // The edge-sensitive arms: the outputs, a polarity and the
        // `data_source_expression` the path's value comes from.
        const n = try parseSpecifyTerminalList(self);
        _ = self.eat(.plus) or self.eat(.minus);
        _ = try self.expect(.colon);
        _ = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        break :edge n;
    } else try parseSpecifyTerminalList(self);
    if (parallel and (sources != 1 or outputs != 1)) return self.failAt(
        if (sources != 1) src_tok else dst_tok,
        .E0207,
        "a parallel path (`=>`) connects one source to one destination, and this one lists {d} source(s) and {d} destination(s); lists need the full path `*>` (A.7.2)",
        .{ sources, outputs },
    );
    _ = try self.expect(.rparen);
    _ = try self.expect(.assign_eq);
    // A.7.4 `path_delay_value ::= list_of_path_delay_expressions
    // | ( list_of_path_delay_expressions )`. The parenthesis is read HERE
    // and not by `parseExpr`, because `( tplh , tphl )` is a list of two
    // and a parenthesized expression is one.
    const bracketed = self.eat(.lparen);
    const delay_tok = self.pos;
    var delays: u32 = 0;
    while (true) {
        _ = try parse_expr.parseExpr(self);
        delays += 1;
        if (!self.eat(.comma)) break;
    }
    // A.7.4 `list_of_path_delay_expressions` has five arms: one value,
    // rise/fall, rise/fall/z, the six transition delays and the twelve.
    switch (delays) {
        1, 2, 3, 6, 12 => {},
        else => return self.failAt(
            delay_tok,
            .E0207,
            "a path delay lists 1, 2, 3, 6 or 12 values (A.7.4 list_of_path_delay_expressions), not {d}",
            .{delays},
        ),
    }
    if (bracketed) _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
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
pub fn parseTimingCheck(self: *Parser) Error!void {
    const tok = self.pos;
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
        const controlled = self.peek() != .comma and self.peek() != .rparen and try parseTimingCheckArg(self);
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
pub fn parseTimingCheckArg(self: *Parser) Error!bool {
    var controlled = self.eat(.kw_posedge) or self.eat(.kw_negedge);
    if (!controlled and parse_module.reservedIs(self, self.pos, "edge")) {
        controlled = true;
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
    _ = try parse_expr.parseExpr(self);
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
    const packed_range: ?Ast.Dim = if (self.peek() == .lbracket) try parse_decl.parseDim(self) else null;
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

/// A.4.1 module_instantiation — LRM §6.2.2 (instances), §6.3 (overrides).
///
///     module_or_paramset_identifier [ #( ... ) ]
///         name [ range ] ( port_connections ) { , name [ range ] ( ... ) } ;
///
/// Every instance in the statement shares the ONE parameter_value_assignment
/// ("`integrator #(1.0) I1(...), I2(...)`" is two instances with the same
/// overrides), so the slice is parsed once and handed to each row.
///
/// Nothing is resolved here: the target module may be declared later in the
/// file, an override's value is a constant expression over the PARENT's
/// parameters, and a port connection is a net reference in the parent. All
/// three are elaboration's questions (`ir/elaborate.zig`), which is also
/// where a name that resolves to nothing is diagnosed.
pub fn parseInstantiation(self: *Parser, b: *parse_module.Body) Error!void {
    const module = try self.internTok(self.pos);
    self.pos += 1;
    const params = try parseParamValueAssignment(self);

    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        const range: ?Ast.Dim = if (self.peek() == .lbracket) try parse_decl.parseDim(self) else null;
        _ = try self.expect(.lparen);
        var ports: std.ArrayList(Ast.PortConn) = .empty;
        if (!self.eat(.rparen)) {
            while (true) {
                // A.4.1.1 gives BOTH connection forms a leading
                // `{ attribute_instance }`, and E.3.2.1's per-port
                // `port_discipline` is the reason the slot exists: "it shall
                // only apply to either the analog primitive itself or the port
                // to which it is attached", and the port is a connection in
                // this list. Skipped, not stored, for the same reason
                // §2.9 attributes are skipped everywhere else — `ModuleDecl
                // .attrs` already collects every attr_spec in the module for
                // the two rules that are about an attribute alone, and the
                // DISCIPLINE the attribute asks for is not read from here: see
                // `Elaborate.primitiveAccess` for where E.3.2 is applied and
                // why the connected net answers it.
                try self.skipAttributes();
                const tok = self.pos;
                if (self.eat(.dot)) {
                    const pname = try self.expectIdent();
                    _ = try self.expect(.lparen);
                    // §6.2.2 "an unconnected port can be indicated either by
                    // omitting it in the port list or by providing no
                    // expression in the parentheses".
                    const e = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseExpr(self);
                    _ = try self.expect(.rparen);
                    try ports.append(self.arena, .{ .name = pname, .expr = e, .main_tok = tok });
                } else {
                    // A.4.1 `ordered_port_connection ::= { attribute_instance
                    // } [ expression ]` — the expression is OPTIONAL, so a
                    // blank holds the position of a port "not to be
                    // connected". It must still occupy a row or the list
                    // shifts left and every later port binds to the wrong net.
                    const e = if (self.peek() == .comma or self.peek() == .rparen)
                        Ast.ExprId.none
                    else
                        try parse_expr.parseExpr(self);
                    try ports.append(self.arena, .{ .expr = e, .main_tok = tok });
                }
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
        try b.instances.append(self.arena, .{
            .module = module,
            .name = name,
            .range = range,
            .params = params,
            .ports = ports.items,
            .main_tok = name_tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// §6.3 `#( list_of_parameter_assignments )`, A.4.1
/// parameter_value_assignment — OPTIONAL: an empty slice when the cursor is
/// not on `#`. A.4.1 gives both arms; a leading `.` is the named one, and
/// the two may not be mixed. Shared between a module instantiation and a
/// §7.7.3 connect statement, which A.1.8 gives the same nonterminal.
pub fn parseParamValueAssignment(self: *Parser) Error![]const Ast.ParamOverride {
    var params: std.ArrayList(Ast.ParamOverride) = .empty;
    if (self.eat(.hash)) {
        _ = try self.expect(.lparen);
        if (!self.eat(.rparen)) {
            while (true) {
                const tok = self.pos;
                if (self.eat(.dot)) {
                    // §6.3.6/§9.18 `.$mfactor(expr)` — A.4.1's
                    // `parameter_identifier` covers the §9.18 system
                    // parameters too, and §9.18 Example 1 prints
                    // `module_b #(.$mfactor(2)) B1(p,n);`. One extra token
                    // tag, not a second production.
                    const name = if (self.peek() == .system_identifier)
                        try self.internTok(self.pos)
                    else
                        null;
                    if (name != null) self.pos += 1;
                    const pname = name orelse try self.expectIdent();
                    _ = try self.expect(.lparen);
                    const v = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseExpr(self);
                    _ = try self.expect(.rparen);
                    try params.append(self.arena, .{ .name = pname, .value = v, .main_tok = tok });
                } else {
                    try params.append(self.arena, .{ .value = try parse_expr.parseExpr(self), .main_tok = tok });
                }
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
    }
    return params.items;
}

/// One shared diagnostic for what VerA leaves out at module scope although
/// A.1.4 derives it: an annex B spelling with no production here, a digital
/// `task` in an analog parse, a generate-case with no region above it …
pub fn unsupportedItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0205, "found {s}", .{self.found(self.pos)});
}

/// A.1.4: text no `module_item` alternative derives — a syntax error, not a
/// missing feature, so it is not E0205.
pub fn notAModuleItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0240, "found {s}", .{self.found(self.pos)});
}

/// A.3.1 `gate_instantiation` for A.3.4's computing gate types:
///
///     n_input_gatetype  [drive_strength] [delay2] n_input_gate_instance …
///     n_output_gatetype [drive_strength] [delay2] n_output_gate_instance …
///     enable_gatetype   [drive_strength] [delay3] enable_gate_instance …
///
/// The strength and the delay belong to the STATEMENT, so every instance in
/// the list shares them. `delay2` is a `delay3` with no turn-off value, and
/// `parseDelay3` already returns `.none` for an omitted one, so the three
/// arms need no separate delay parser — an n-input gate never turns off, so
/// a third value would be rejected by §7.14 rather than by the grammar.
///
/// OUTSIDE A DIGITAL RUN the instance is accepted and modelled by nothing,
/// out loud (W0252) — see `gateNotModelled`.
pub fn parseGates(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
    const kind: Ast.GateKind = switch (self.peek()) {
        .kw_and => .g_and,
        .kw_nand => .g_nand,
        .kw_or => .g_or,
        .kw_nor => .g_nor,
        .kw_xor => .g_xor,
        .kw_xnor => .g_xnor,
        .kw_buf => .g_buf,
        .kw_not => .g_not,
        .kw_bufif0 => .g_bufif0,
        .kw_bufif1 => .g_bufif1,
        .kw_notif0 => .g_notif0,
        .kw_notif1 => .g_notif1,
        else => unreachable, // else: the caller dispatched on exactly these
    };
    self.pos += 1;
    // Unlike `assign`, a `(` here is ambiguous: A.3.1 makes the instance
    // NAME optional, so `and (w, a, b);` opens a terminal list with the
    // same token A.2.2.2's drive strength opens. The word inside settles
    // it — A.2.2.2's alternatives all begin with a strength keyword, and no
    // terminal can, since those spellings are reserved words.
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_generate.strengthWord(self, self.pos + 1) != null) try parse_generate.parseDriveStrength(self, &s0, &s1);
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_generate.parseDelay3(self) else .{};
    while (true) {
        const tok = self.pos;
        // A.3.1 makes `name_of_gate_instance` optional; `(` after the name
        // tells the two apart, as in `parsePassSwitch`. A.3.1's
        // `name_of_gate_instance ::= gate_instance_identifier [ range ]` is
        // §7.1.5's instance array.
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            self.pos += 1;
            if (self.peek() == .lbracket) range = try parse_decl.parseDim(self);
        }
        _ = try self.expect(.lparen);
        var terms: std.ArrayList(Ast.ExprId) = .empty;
        while (true) {
            try terms.append(self.arena, try parse_expr.parseExpr(self));
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
        // A.3.3 `output_terminal ::= net_lvalue`: a gate drives its outputs,
        // so each must be a net it can drive. buf/not lead with every
        // terminal but the last as an output; every other gate with one.
        const n_out = switch (kind) {
            .g_buf, .g_not => terms.items.len -| 1,
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => @min(terms.items.len, 1),
        };
        for (terms.items[0..n_out]) |out| if (!isNetLvalue(self, out)) return self.failAt(
            self.file.exprs.mainTok(out),
            .E0207,
            "found {s}: a gate's output terminal is a net_lvalue (A.3.3), a net the gate can drive",
            .{self.found(self.file.exprs.mainTok(out))},
        );
        switch (kind) {
            // A.3.1 `( output_terminal { , output_terminal } ,
            // input_terminal )` — buf/not are the only gates whose list
            // runs the other way: everything up to the LAST terminal is an
            // output, and each is a separate driver of its own net.
            .g_buf, .g_not => {
                if (terms.items.len < 2) return self.failAt(tok, .E0209, "a buf/not gate needs at least one output and one input", .{});
                const input = terms.items[terms.items.len - 1];
                for (terms.items[0 .. terms.items.len - 1]) |out|
                    try b.gates.append(self.arena, .{ .kind = kind, .out = out, .ins = input_only: {
                        const one = try self.arena.alloc(Ast.ExprId, 1);
                        one[0] = input;
                        break :input_only one;
                    }, .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal , enable_terminal )`
            .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
                if (terms.items.len != 3) return self.failAt(tok, .E0209, "an enable gate takes an output, a data input and an enable", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal { , input_terminal } )`
            // — one input is enough, and IEEE 1364-2005 §7.2 says so in words:
            // "These six logic gates shall have one output and one or more
            // inputs."
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => {
                if (terms.items.len < 2) return self.failAt(tok, .E0209, "an n-input gate takes an output and at least one input", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.8.5 `net_lvalue`: a (hierarchical) net name with optional selects, or a
/// concatenation of net_lvalues.
fn isNetLvalue(self: *const Parser, e: Ast.ExprId) bool {
    const x = &self.file.exprs;
    return switch (x.tag(e)) {
        .ident, .hier_ident => true,
        .index => isNetLvalue(self, x.lhs(e)),
        .concat => for (x.args(e)) |a| {
            if (!isNetLvalue(self, a)) break false;
        } else true,
        else => false, // else: a literal, operator, call, access or pattern names no net; a new name form would be a new arm above
    };
}

/// W0252 for the primitive at the cursor, when the artifact being built is
/// an analog device. §8.5.3.5's first paragraph is the clause: "The
/// event-driven simulation algorithm described in 11 of IEEE Std 1364
/// Verilog depends on unidirectional signal flow … The IEEE Std 1364
/// Verilog provides switch-level modeling in addition to behavioral and
/// GATE-LEVEL modeling." A gate's update is an event, and a compiled analog
/// device has no queue to schedule one on, so the instance reaches nothing.
///
/// Silent was the wrong answer and E0205 was the other wrong answer: the
/// source is derivable from A.3.1 and §1.1 makes it VerA's to accept, so
/// refusing it said "not derivable" about text that is. `--deny=W0252` is
/// the refusal, for a model that cannot afford the omission.
///
/// Not reported under `--run`: the discrete engine executes the gate there,
/// so there is nothing missing to warn about.
pub fn gateNotModelled(self: *Parser) Error!void {
    if (self.digital) return;
    try self.bag.add(
        .parse,
        .W0252,
        lexer.tokenSpan(self.src, self.starts, self.pos),
        "{s} primitive",
        .{self.found(self.pos)},
    );
}

/// A.3.1's last two `gate_instantiation` arms, which are the only ones with
/// a one-terminal instance and a strength set of their own:
///
///     | pulldown [pulldown_strength] pull_gate_instance { , … } ;
///     | pullup   [pullup_strength]   pull_gate_instance { , … } ;
///     pull_gate_instance ::= [ name_of_gate_instance ] ( output_terminal )
///
/// A.3.2's brackets are NOT A.2.2.2's, which is why they have a clause to
/// themselves and this routine does not call `parseDriveStrength`:
///
///     pulldown_strength ::= ( strength0 , strength1 ) | ( strength1 , strength0 )
///             | ( strength0 )
///     pullup_strength   ::= ( strength0 , strength1 ) | ( strength1 , strength0 )
///             | ( strength1 )
///
/// Two differences, both checked below: the single-strength arm exists here
/// and does not in A.2.2.2, and it is the SIDE the gate pulls toward —
/// `strength0` for a `pulldown`, `strength1` for a `pullup` — so
/// `pulldown (strong1)` is derivable from neither of the two productions.
/// `highz0`/`highz1` are the other difference: A.2.2.2 admits them and
/// A.3.2 does not, which `strengthWord`'s `.side == 2` test is.
///
/// A `pull_gate_instance` takes ONE terminal and drives it to a constant,
/// so like every other A.3.1 arm outside a digital run it is accepted and
/// modelled by nothing (W0252). Each instance is recorded on `b.pulls`,
/// which the digital engine executes and an analog compile never reads.
pub fn parsePullGate(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
    // A.3.2's `strength0`/`strength1` name the side the gate pulls toward:
    // 0 for `pulldown`, 1 for `pullup`, which is also `StrengthWord.side`.
    const side: u8 = if (parse_module.reservedIs(self, self.pos, "pulldown")) 0 else 1;
    const main_tok = self.pos;
    self.pos += 1;
    // §7.8: "pull strength in the absence of a strength specification", and
    // only the strength on the side the source pulls toward is kept.
    var strength: Ast.Strength = .pull;
    if (self.peek() == .lparen and parse_generate.strengthWord(self, self.pos + 1) != null) {
        const tok = self.pos + 1;
        if (self.peekAt(2) == .comma) {
            var s0: Ast.Strength = .strong;
            var s1: Ast.Strength = .strong;
            try parse_generate.parseDriveStrength(self, &s0, &s1);
            strength = if (side == 1) s1 else s0;
        } else {
            self.pos += 1;
            const w = parse_generate.strengthWord(self, self.pos).?;
            self.pos += 1;
            _ = try self.expect(.rparen);
            if (w.side != side) return self.failAt(
                tok,
                .E0207,
                "a single-strength bracket on this gate is A.3.2's `( strength{d} )`",
                .{side},
            );
            strength = w.level;
        }
    }
    while (true) {
        // A.3.1 makes `name_of_gate_instance` optional here too; `(` after
        // the name tells the two apart, as in `parseGates`.
        if (self.identLike(self.pos)) self.pos += 1;
        _ = try self.expect(.lparen);
        const out = try parse_expr.parseNetRef(self); // A.3.3 output_terminal ::= net_lvalue
        try b.pulls.append(self.arena, .{ .out = out, .one = side == 1, .strength = strength, .main_tok = main_tok });
        _ = try self.expect(.rparen);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// The shape of one A.3.1 switch arm, which is all four of them differ by:
/// how many terminals an instance takes, how many of those are A.3.3
/// `net_lvalue`s (everything after them is an `expression`), and whether a
/// delay bracket precedes the instance list.
pub const SwitchArm = struct { terminals: u8, lvalues: u8, delay: bool };

/// A.3.4's ten switch spellings, keyed the way annex B reserves them — by
/// SPELLING. Eight of the ten share `.kw_reserved` (`tran` and `rtran` are
/// the two with tags, because A.4.1 needed them before this did), so a tag
/// dispatch would have to be two dispatches; this is one.
pub const switch_arms = std.StaticStringMap(SwitchArm).initComptime(.{
    // `cmos_switchtype [delay3] ( output , input , ncontrol , pcontrol )`
    .{ "cmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true } },
    .{ "rcmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true } },
    // `mos_switchtype [delay3] ( output , input , enable )`
    .{ "nmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true } },
    .{ "pmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true } },
    .{ "rnmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true } },
    .{ "rpmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true } },
    // `pass_switchtype ( inout , inout )` — the one arm with no delay
    // bracket at all, which is why A.4.1 prints it on its own.
    .{ "tran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false } },
    .{ "rtran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false } },
    // `pass_en_switchtype [delay2] ( inout , inout , enable )`. `delay2` is
    // a `delay3` that stops at two values, which `parseDelay3` already
    // returns for a two-value list.
    .{ "tranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true } },
    .{ "tranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true } },
    .{ "rtranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true } },
    .{ "rtranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true } },
});

/// A.3.1's four switch arms — the primitives whose output is a CONDUCTION
/// PATH rather than a computed value:
///
///     | cmos_switchtype    [delay3] cmos_switch_instance         { , … } ;
///     | mos_switchtype     [delay3] mos_switch_instance          { , … } ;
///     | pass_en_switchtype [delay2] pass_enable_switch_instance  { , … } ;
///     | pass_switchtype            pass_switch_instance          { , … } ;
///
///     cmos_switch_instance ::= [ name_of_gate_instance ] ( output_terminal ,
///             input_terminal , ncontrol_terminal , pcontrol_terminal )
///     mos_switch_instance ::= [ name_of_gate_instance ]
///             ( output_terminal , input_terminal , enable_terminal )
///     pass_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal )
///     pass_enable_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal , enable_terminal )
///
/// Only `tran`/`rtran` reached a production before this; the other eight
/// A.3.4 spellings were `E0205: unsupported module item`, which says "this
/// text is not derivable" about text the annex above derives — the same
/// wrong answer `gateNotModelled`'s docstring retired for A.3.1's computing
/// arms. §1.1 ("Verilog-AMS HDL consists of the complete IEEE Std 1364
/// Verilog specification") is what makes the grammar VerA's to read.
///
/// Every instance is recorded (`ModuleDecl.switches`) — not as an
/// `Ast.GateKind`: §7.12's strength REDUCTION and §7.6's bidirectional
/// conduction are neither of them a function of input bits. §8.5.3.5 puts
/// switch processing in the discrete simulation cycle, so the digital engine
/// runs it (under `--run`, and as a mixed module's discrete half); a compiled
/// analog device has no equation to stamp, and lowering says so (W0250) when
/// the module has no discrete half to carry it.
pub fn parseSwitch(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const spelling = parse_expr.tokenText(self, main_tok);
    const arm = switch_arms.get(spelling).?; // the caller dispatched on exactly these
    const kind = std.meta.stringToEnum(Ast.SwitchKind, spelling).?;
    self.pos += 1;
    const delay: Ast.Delay3 = if (arm.delay and self.peek() == .hash) try parse_generate.parseDelay3(self) else .{};
    while (true) {
        const inst_tok = self.pos;
        // A.3.1 makes `name_of_gate_instance ::= gate_instance_identifier
        // [ range ]` optional, and the fixture's `tran (a, b);` uses that
        // arm. `(` after the name tells the two apart, as in `parseGates`.
        if (self.identLike(self.pos)) {
            self.pos += 1;
            if (self.peek() == .lbracket) _ = try parse_decl.parseDim(self);
        }
        _ = try self.expect(.lparen);
        const terms = try self.arena.alloc(Ast.ExprId, arm.terminals);
        for (terms, 0..) |*t, i| {
            if (i != 0) _ = try self.expect(.comma);
            // A.3.3: `output_terminal` and `inout_terminal` are
            // `net_lvalue`s and lead; `input_terminal`, `enable_terminal`,
            // `ncontrol_terminal` and `pcontrol_terminal` are all
            // `expression`, so `cmos (o, d, ~g, g)` is derivable and
            // `cmos (~o, d, ng, g)` is not.
            t.* = if (i < arm.lvalues) try parse_expr.parseNetRef(self) else try parse_expr.parseExpr(self);
        }
        _ = try self.expect(.rparen);
        try b.switches.append(self.arena, .{ .kind = kind, .terms = terms, .delay = delay, .main_tok = inst_tok });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.6.2 `initial_construct ::= initial statement` /
/// `always_construct ::= always statement` — §7.2.2's DISCRETE context.
///
/// Both keywords are module items of every module (A.1.4), and the body is
/// A.6.4's `statement`, whose digital forms (`#`, `wait`, `<=`, intra-
/// assignment timing) are admitted by `in_discrete` whatever the file's
/// extension. Whether a given discrete process can be EXECUTED is not a
/// grammar question: lowering answers it (`Lower.checkDiscreteContext`), with
/// the clause that decides it.
pub fn parseDiscrete(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const is_always = self.peek() == .kw_always;
    self.pos += 1;
    const saved = self.in_discrete;
    self.in_discrete = true;
    defer self.in_discrete = saved;
    const body = try parse_stmt.parseStmtNoNull(self);
    try b.discrete.append(self.arena, .{
        .is_always = is_always,
        .body = body,
        .main_tok = main_tok,
    });
}
