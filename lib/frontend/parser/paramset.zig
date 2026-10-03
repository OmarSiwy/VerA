//! Annex A.1.9 paramset_declaration (LRM §6.4): tokens from `paramset` to
//! `endparamset` in, one `Ast.ParamsetDecl` out: the paramset's own
//! declarations and its `.name = expr;` overrides of the target module's
//! parameters. §6.4.1's restrictions on what a paramset body may hold are
//! checked here, including in the statements it skips.
//!
//! LRM clauses cited: §2.9, §6.4, §6.4.1, §6.4.3, §9.18.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_source = @import("source.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses one A.1.9 paramset_declaration (LRM §6.4):
///
///     paramset paramset_identifier module_or_paramset_identifier ;
///         { paramset_item_declaration } { paramset_statement }
///     endparamset
///
/// §6.4: "The paramset itself contains no behavioral code; all of the
/// behavior is determined by the associated module". The result holds the
/// paramset's own declarations and its `.name = expr;` overrides of the
/// module's parameters. Clears `self.attrs`.
pub fn parseParamset(self: *Parser) Error!Ast.ParamsetDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'paramset'
    const name = try self.expectIdent();
    const target = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var aliasparams: std.ArrayList(Ast.AliasParam) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var overrides: std.ArrayList(Ast.ParamsetOverride) = .empty;

    // ponytail: A.1.9's other two statement forms are read and dropped:
    // `paramset_local_identifier = expr ;` (§6.4.3's output variables, whose
    // value a host reports for the instance) and `analog_function_statement`.
    // Nothing downstream has an operating-point reporting path for them
    // (ch06_hierarchy/paramset_output_unsupported.va). The upgrade is an
    // output-variable table on the emitted device, parsed in this loop.
    while (true) {
        const mark = self.attrs.items.len;
        try self.skipAttributes();
        try parse_source.outsideDesignElement(self, "paramset");
        switch (self.peek()) {
            .eof, .kw_endparamset => break,
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_aliasparam => try aliasparams.append(self.arena, try parse_decl.parseAliasparam(self)),
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
                // §6.4.3 "Integer or real variables in the paramset declared
                // with descriptions are considered output variables".
                const described = for (self.attrs.items[mark..]) |a| {
                    if (std.mem.eql(u8, self.file.str(a.name), "desc")) break true;
                } else false;
                for (vars.items[first..]) |*v| v.desc = described;
            },
            // A.1.9 `paramset_statement ::= . module_parameter_identifier =
            // paramset_constant_expression ;` and its `. system_parameter_-
            // identifier` sibling (§9.18's `$mfactor` and friends), told
            // apart by the one token that spells a system name.
            .dot => {
                const tok = self.pos;
                self.pos += 1;
                const is_sys = self.peek() == .system_identifier;
                const pname = try self.expectIdentOrSys();
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
                _ = try self.expect(.semicolon);
                try overrides.append(self.arena, .{
                    .kind = if (is_sys) .system_param else .module_param,
                    .name = pname,
                    .value = value,
                    .main_tok = tok,
                });
            },
            // The two dropped statement forms, and only those. They are
            // skipped by tokens, not parsed: an output assignment's
            // right-hand side may use §6.4.3's `.module_output_variable`
            // spelling, which is not an expression anywhere else. The skip
            // is limited to what A.1.9 admits here, a variable assignment
            // (`ft = 3.0 * .gm;`: an identifier, then `=` or `[`) or a
            // §6.4.1 statement wrapping such assignments, so a misspelled
            // `paramter real rr;` is still refused.
            else => { // else: every other paramset statement, gated to what A.1.9 admits just below
                const legal = (self.identLike(self.pos) and
                    (self.peekAt(1) == .assign_eq or self.peekAt(1) == .lbracket)) or
                    switch (self.peek()) {
                        .kw_if, .kw_case, .kw_for, .kw_while, .kw_repeat, .kw_begin => true,
                        else => false, // else: not a statement keyword A.1.9 admits here
                    };
                if (!legal) try self.report(
                    self.pos,
                    .E0205,
                    "found {s} in a paramset body",
                    .{self.found(self.pos)},
                );
                try skipParamsetStatement(self);
            },
        }
    }
    _ = try self.expect(.kw_endparamset);
    // §2.9 attributes inside a paramset decorate its declarations, and
    // `NatureAttr` collection is per design element, so drop them with the
    // element.
    self.attrs.clearRetainingCapacity();

    return .{
        .name = name,
        .target = target,
        .params = params.items,
        .aliasparams = aliasparams.items,
        .vars = vars.items,
        .overrides = overrides.items,
        .main_tok = main_tok,
    };
}

/// Skips one A.1.9 paramset statement by tokens: to the `;` that ends it,
/// balancing `(...)` (a `for` header holds two semicolons), `begin`/`end`
/// and `case`/`endcase`, and continuing over `else`, so a dropped
/// `if (c) begin ft = 1.0; end else ft = 2.0;` is one skip. A statement
/// that is a block ends at its `end`/`endcase`, which has no `;`.
///
/// Still reports E0237 for what §6.4.1 forbids a paramset: "Shall not use
/// access functions. Shall not use contribution statements or event control
/// statements. Shall not use named blocks." Skipping them silently would
/// accept them.
fn skipParamsetStatement(self: *Parser) Error!void {
    var depth: u32 = 0;
    while (true) : (self.pos += 1) {
        const what: ?[]const u8 = switch (self.peek()) {
            .kw_potential, .kw_flow => if (self.peekAt(1) == .lparen) "an access function" else null,
            .identifier => if (self.peekAt(1) == .lparen and self.access_names.contains(self.tokenText(self.pos))) "an access function" else null,
            .kw_begin => if (self.peekAt(1) == .colon) "a named block" else null,
            .contribute => "a contribution statement",
            .at => "an event control",
            else => null, // else: every other token is legal in a paramset statement
        };
        if (what) |w| try self.report(self.pos, .E0237, "{s}: found {s}", .{ w, self.found(self.pos) });
        switch (self.peek()) {
            .eof, .kw_endparamset => return,
            .lparen, .kw_begin, .kw_case => depth += 1,
            .rparen => depth -|= 1,
            .kw_end, .kw_endcase => {
                depth -|= 1;
                if (depth == 0 and self.peekAt(1) != .kw_else) {
                    self.pos += 1;
                    return;
                }
            },
            .semicolon => if (depth == 0 and self.peekAt(1) != .kw_else) {
                self.pos += 1;
                return;
            },
            else => {}, // else: any other token is inside the statement being skipped
        }
    }
}
