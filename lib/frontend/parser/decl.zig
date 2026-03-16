//! Annex A.2.1.1 parameters (§3.4), A.2.6 analog functions (§4.7.1), A.1.6/A.1.7 natures and disciplines (§3.6).
//!
//! In: declaration tokens. Out: `Ast.ParamDecl`, `Ast.FuncDecl`, `Ast.NatureDecl`,
//! `Ast.DisciplineDecl`.
//!
//! LRM clauses this file's code cites: §3.2, §3.2.2, §3.3, §3.4, §3.4.1, §3.4.2, §3.4.4, §3.4.5, §3.6.1.4, §4.7.1, §4.7.2.3, §5.2.1.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_decl.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const Ast = @import("../ast.zig");
const token = @import("../token.zig");
const Error = parser.Error;
const found = Parser.found;

// -----------------------------------------------------------------------
// A.2.1.1 parameter declarations — LRM §3.4
// -----------------------------------------------------------------------

/// Parameter declaration incl. ranges. LRM §3.4, §3.4.1, §3.4.2, §3.4.5.
///
/// `parameter real a = 1, b = 2;` is one
/// declaration but N `ParamDecl`s, so the list is an out-parameter.
pub fn parseParamDecl(self: *Parser, out: *std.ArrayList(Ast.ParamDecl)) Error!void {
    const is_local = self.peek() == .kw_localparam;
    self.pos += 1;
    _ = self.eat(.kw_signed);
    // §3.4.1: no type keyword is `.unspecified`, inferred from the default
    // by lowering.
    const ty = varType(self.peek()) orelse .unspecified;
    if (ty != .unspecified) self.pos += 1;
    // A.2.1.1's FIRST arm, the `[ range ]` slot between `[ signed ]` and the
    // assignment list:
    //
    //     parameter_declaration ::=
    //         parameter [ signed ] [ range ] list_of_param_assignments
    //         | parameter parameter_type list_of_param_assignments
    //
    // A.2.5's `range ::= [ msb_constant_expression :
    // lsb_constant_expression ]` — a WIDTH, which is why it cannot go in
    // `dims` (§3.4.4 array parameters, which lowering scalarizes) and gets
    // the same `packed_range` slot `VarDecl` gives a `reg`'s. The two arms
    // are exclusive in the production, so a range is only read when no
    // `parameter_type` was written.
    //
    // The TYPE is not forced by the bracket: §3.4.1 — "If the type of a
    // parameter is not specified, it is derived from the type of the final
    // value assigned to the parameter, after any value overrides have been
    // applied" — so `.unspecified` stays and lowering infers `integer`
    // from `4'h5` exactly as it would without the bracket.
    //
    // ponytail: the width is CARRIED, not enforced. `parameter [3:0] p =
    // 8'hff;` reads 255 here and 15 in a tool that truncates to the
    // declared width. Enforcing it is a fold of two constant expressions
    // and a mask in `ir/lower.zig`, where the parameter's default is
    // already folded; nothing in the suite asks for it yet.
    const packed_range: ?Ast.Dim =
        if (ty == .unspecified and self.peek() == .lbracket) try parseDim(self) else null;

    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        const dims = try parseDims(self);
        _ = try self.expect(.assign_eq);
        const default = try parse_expr.parseExpr(self);

        var ranges: std.ArrayList(Ast.ValueRange) = .empty;
        while (self.peek() == .kw_from or self.peek() == .kw_exclude) {
            try ranges.append(self.arena, try parseRange(self));
        }
        try out.append(self.arena, .{
            .name = name,
            .ty = ty,
            .default = default,
            .is_local = is_local,
            .dims = dims,
            .packed_range = packed_range,
            .ranges = ranges.items,
            .main_tok = tok,
        });
        // A.1.3 `parameter_declaration { , parameter_declaration }` and
        // A.2.1.1 `list_of_param_assignments` are separated by the SAME
        // comma, so a `parameter` keyword after one starts a new
        // declaration and this list is over. Only a
        // module_parameter_port_list can actually reach that — a body
        // declaration ends at `;` — and there stopping turns the illegal
        // `parameter real a = 1, parameter real b = 2;` from E0208 into
        // E0207, the same verdict on the same token.
        if (self.peek() != .comma) break;
        if (self.tags[self.pos + 1] == .kw_parameter or
            self.tags[self.pos + 1] == .kw_localparam) break;
        self.pos += 1;
    }
}

/// LRM §3.4.2 / A.2.5 value_range. CRITICAL: this is the only bound
/// evidence class 6 (proof.zig) gets — it must reach `ParamDecl.ranges`.
pub fn parseRange(self: *Parser) Error!Ast.ValueRange {
    const kind: Ast.ValueRange.Kind = if (self.peek() == .kw_from) .from else .exclude;
    self.pos += 1;

    // `from '{"a", "b"}` — string-set range (§3.4.2).
    if (self.peek() == .apostrophe_lbrace) {
        self.pos += 1;
        var names: std.ArrayList(Ast.StrId) = .empty;
        if (self.peek() != .rbrace) while (true) {
            const tok = try self.expect(.string_literal);
            try names.append(self.arena, try parse_expr.internString(self, tok));
            if (!self.eat(.comma)) break;
        };
        _ = try self.expect(.rbrace);
        const off = try self.file.exprs.addStrList(self.arena, names.items);
        return .{ .kind = kind, .lo = .none, .strings = off };
    }

    // `exclude constant_expression` — A.2.5 gives the bare form to
    // `exclude` ONLY; `from` is always bracketed. `from 5` is user source,
    // not a parser invariant, so it is a diagnostic: as an assert it was
    // `unreachable` in ReleaseFast, i.e. UB at the trust boundary.
    if (self.peek() != .lparen and self.peek() != .lbracket) {
        if (kind == .from) {
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected `(` or `[` — only `exclude` takes a bare value", .{});
            try d.emit();
            return error.ParseError;
        }
        return .{ .kind = kind, .lo = try parseValueRangeExpr(self) };
    }

    const lo_inclusive = self.peek() == .lbracket;
    self.pos += 1;
    const lo = try parseValueRangeExpr(self);
    // `exclude ( expr )` — a parenthesized single value, not a range.
    if (self.peek() != .colon) {
        _ = try self.expect(.rparen);
        return .{ .kind = kind, .lo = lo };
    }
    self.pos += 1;
    const hi = try parseValueRangeExpr(self);
    const hi_inclusive = switch (self.peek()) {
        .rbracket => true,
        .rparen => false,
        else => return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)}), // else: a value_range closes with `]` or `)` and nothing else: E0210
    };
    self.pos += 1;
    return .{
        .kind = kind,
        .lo = lo,
        .hi = hi,
        .lo_inclusive = lo_inclusive,
        .hi_inclusive = hi_inclusive,
    };
}

/// A.2.5 value_range_expression ::= constant_expression | -inf | inf
pub fn parseValueRangeExpr(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    if (self.peek() == .minus and self.peekAt(1) == .kw_inf) {
        self.pos += 2;
        return self.file.exprs.add(self.arena, .{ .tag = .neg_inf, .main_tok = tok });
    }
    if (self.peek() == .kw_inf) {
        self.pos += 1;
        return self.file.exprs.add(self.arena, .{ .tag = .pos_inf, .main_tok = tok });
    }
    return parse_expr.parseExpr(self);
}

/// A.2.1.3 / A.2.7 variable type keyword -> `Ast.Type`, null for any other
/// token. `time` folds to integer and `realtime` to real (§3.4.1). An analog
/// function's RETURN type is narrower (`integer | real | string`, A.2.6), so
/// `parseFuncDecl` does not use this.
pub fn varType(tag: token.Tag) ?Ast.Type {
    return switch (tag) {
        .kw_integer, .kw_time => .integer,
        .kw_real, .kw_realtime => .real,
        .kw_string => .string,
        else => null, // else: not one of the five variable-type keywords
    };
}

/// A.2.1.3 integer/real/string declaration (§3.2, §3.3). One VarDecl per
/// name; `variable_type ::= id { dimension } [ = expr ]` (A.2.2.1).
pub fn parseVarDecl(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
    const storage: @FieldType(Ast.VarDecl, "storage") = if (self.peek() == .kw_time) .time else .variable;
    const ty = varType(self.peek()).?;
    self.pos += 1;
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        const dims = try parseDims(self);
        var init_expr: Ast.ExprId = .none;
        if (self.eat(.assign_eq)) init_expr = try parse_expr.parseExpr(self);
        try out.append(self.arena, .{
            .name = name,
            .ty = ty,
            .dims = dims,
            .init = init_expr,
            .storage = storage,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
}

/// IEEE 1364-2005 §10.2/§10.4, A.2.6 and A.2.7, for a digital parse:
///
///     task [ automatic ] name [ ( tf_port_list ) ] ; { tf_item } statement endtask
///     function [ automatic ] [ function_range_or_type ] name
///         [ ( tf_port_list ) ] ; { function_item } statement endfunction
///
/// A formal's direction sticks to the names after it until another one is
/// written, in the port list and in a body declaration alike.
pub fn parseSubroutine(self: *Parser, b: *parse_module.Body, is_function: bool) Error!void {
    const main_tok = self.pos;
    self.pos += 1; // `task` / `function`
    const automatic = parse_module.reservedIs(self, self.pos, "automatic");
    if (automatic) self.pos += 1;
    var result: Ast.VarDecl = if (is_function) tfType(self) else .{ .name = .none, .ty = .integer };
    if (is_function and result.storage == .reg and result.packed_range == null and self.peek() == .lbracket) result.packed_range = try parseDim(self);
    const name_tok = self.pos;
    const name = try self.expectIdent();
    result.name = name;
    result.main_tok = name_tok;
    var ports: std.ArrayList(Ast.TfPort) = .empty;
    if (self.eat(.lparen)) {
        var dir: Ast.Direction = .input;
        var ty: Ast.VarDecl = .{ .name = .none, .ty = .integer, .storage = .reg, .is_signed = false };
        while (self.peek() != .rparen and self.peek() != .eof) {
            if (parse_module.portDirection(self.peek())) |d| {
                dir = d;
                self.pos += 1;
                ty = try tfPortType(self);
            }
            var v = ty;
            v.main_tok = self.pos;
            v.name = try self.expectIdent();
            try ports.append(self.arena, .{ .direction = dir, .v = v });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    _ = try self.expect(.semicolon);
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    const end_word = if (is_function) "endfunction" else "endtask";
    while (true) {
        try self.skipAttributes();
        if (parse_module.portDirection(self.peek())) |d| {
            self.pos += 1;
            const ty = try tfPortType(self);
            while (true) {
                var v = ty;
                v.main_tok = self.pos;
                v.name = try self.expectIdent();
                try ports.append(self.arena, .{ .direction = d, .v = v });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
            continue;
        }
        switch (self.peek()) {
            .kw_reg, .kw_integer, .kw_time, .kw_real, .kw_realtime => {
                const ty = try tfPortType(self);
                while (true) {
                    var v = ty;
                    v.main_tok = self.pos;
                    v.name = try self.expectIdent();
                    v.dims = try parseDims(self);
                    if (self.eat(.assign_eq)) v.init = try parse_expr.parseExpr(self);
                    try vars.append(self.arena, v);
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            else => break, // else: the first token that declares nothing begins the body
        }
    }
    var body: std.ArrayList(Ast.StmtId) = .empty;
    while (!(self.peek() == .kw_endfunction or parse_module.reservedIs(self, self.pos, end_word)) and self.peek() != .eof) {
        try body.append(self.arena, try parse_stmt.parseStmt(self));
    }
    if (self.peek() == .kw_endfunction or parse_module.reservedIs(self, self.pos, end_word)) {
        self.pos += 1;
    } else return self.failAt(self.pos, .E0207, "found {s}: no `{s}` closes the declaration", .{ self.found(self.pos), end_word });
    const body_id: Ast.StmtId = if (body.items.len == 1)
        body.items[0]
    else
        try self.file.addStmt(self.arena, .{ .block = .{ .body = body.items } }, main_tok);
    try b.tasks.append(self.arena, .{
        .name = name,
        .is_function = is_function,
        .automatic = automatic,
        .result = result,
        .ports = ports.items,
        .vars = vars.items,
        .body = body_id,
        .main_tok = main_tok,
    });
}

/// A.2.7's formal and block-item types: `[ reg ] [ signed ] [ range ]`,
/// `integer`, `time`, `real` or `realtime`. A bare direction is a 1-bit
/// unsigned `reg` (IEEE 1364-2005 §10.2.1).
fn tfPortType(self: *Parser) Error!Ast.VarDecl {
    var v = tfType(self);
    if (v.storage == .reg and self.peek() == .lbracket) v.packed_range = try parseDim(self);
    return v;
}

/// The keyword half of `tfPortType`, which a function's result shares.
fn tfType(self: *Parser) Ast.VarDecl {
    switch (self.peek()) {
        .kw_integer => {
            self.pos += 1;
            return .{ .name = .none, .ty = .integer, .storage = .variable, .is_signed = true };
        },
        .kw_time => {
            self.pos += 1;
            return .{ .name = .none, .ty = .integer, .storage = .time, .is_signed = false };
        },
        .kw_real, .kw_realtime => {
            self.pos += 1;
            return .{ .name = .none, .ty = .real };
        },
        else => { // else: `[ reg ] [ signed ] [ range ]`, every keyword optional
            _ = self.eat(.kw_reg);
            return .{ .name = .none, .ty = .integer, .storage = .reg, .is_signed = self.eat(.kw_signed) };
        },
    }
}

/// The width of `[msb:lsb]` when both bounds are integer LITERALS.
///
/// ponytail: literals only. Folding `[W-1:0]` needs the constant evaluator,
/// which lives in lowering.
pub fn literalWidth(self: *const Parser, d: Ast.Dim) ?u64 {
    const ex = &self.file.exprs;
    if (ex.tag(d.msb) != .int_literal or ex.tag(d.lsb) != .int_literal) return null;
    return @abs(ex.intValue(d.msb) - ex.intValue(d.lsb)) + 1;
}

/// A.2.2.1 `variable_type ::= identifier { dimension } …` and A.2.1.1's
/// `parameter_identifier { dimension }` — the braces are the LRM's, so the
/// list is a LOOP. §3.2 prints both shapes it admits:
///
///     integer flag_array[0:8][0:3];         // a multidimensional array
///     real vtable[0:16][0:7][0:64];         // three dimensions
///
/// One dimension used to be the whole of it, which made the second `[` an
/// E0207 "expected `;`" — a syntax verdict on a declaration A.2.2.1 spells
/// out. Lowering scalarizes whatever arrives here (see `dimsBounds`).
pub fn parseDims(self: *Parser) Error![]const Ast.Dim {
    if (self.peek() != .lbracket) return &.{};
    var dims: std.ArrayList(Ast.Dim) = .empty;
    while (self.peek() == .lbracket)
        try dims.append(self.arena, try parseDim(self));
    return dims.items;
}

/// A.2.5 `dimension ::= [ expr : expr ]` (§3.2.2, §3.4.4).
pub fn parseDim(self: *Parser) Error!Ast.Dim {
    _ = try self.expect(.lbracket);
    const msb = try parse_expr.parseExpr(self);
    _ = try self.expect(.colon);
    const lsb = try parse_expr.parseExpr(self);
    _ = try self.expect(.rbracket);
    return .{ .msb = msb, .lsb = lsb };
}

// -----------------------------------------------------------------------
// A.2.6 analog_function_declaration — LRM §4.7.1 · A.6.2 analog_construct
// -----------------------------------------------------------------------

pub fn parseAnalog(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    self.pos += 1; // 'analog'
    if (self.peek() == .kw_function) return parseFuncDecl(self, b, main_tok, true);
    // §5.2.1 `analog initial analog_function_statement`
    const is_initial = self.eat(.kw_initial);
    const body = try parse_stmt.parseStmtNoNull(self); // A.6.2 takes one analog_statement
    try b.analog.append(self.arena, .{
        .is_initial = is_initial,
        .body = body,
        .main_tok = main_tok,
    });
}

/// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`.
/// Argument types come either from the declaration itself (`input real x;`)
/// or from a matching variable declaration (`input x; real x;`, A.2.6).
pub fn parseFuncDecl(self: *Parser, b: *parse_module.Body, main_tok: u32, is_analog: bool) Error!void {
    self.pos += 1; // 'function'
    const ret_ty: Ast.Type = switch (self.peek()) {
        .kw_integer => .integer,
        .kw_real => .real,
        .kw_string => .string,
        else => .real, // else: no type keyword, so §4.7.1's `real` default
    };
    if (self.peek() == .kw_integer or self.peek() == .kw_real or self.peek() == .kw_string) {
        self.pos += 1;
    }
    const name = try self.expectIdent();

    var args: std.ArrayList(Ast.FuncArg) = .empty;
    // A.2.6's ANSI spelling, `function_identifier ( tf_port_list ) ;`,
    // alongside the non-ANSI one where the ports are `function_item_
    // declaration`s in the body. §4.7.1's own examples are all non-ANSI,
    // which is why only that arm existed; 1364's `function real f(input
    // real x);` is the same declaration with the list moved, and a digital
    // function is written that way far more often than not.
    //
    // The two are not mixable — a paren list means the body declares no
    // more ports — but nothing here enforces that, because the body loop
    // below reads a stray `input` as one more argument and the LRM gives
    // no diagnostic for the combination.
    if (self.eat(.lparen)) {
        while (self.peek() != .rparen and self.peek() != .eof) {
            const dir = switch (self.peek()) {
                .kw_input, .kw_output, .kw_inout => blk: {
                    const d = parse_module.portDirection(self.peek()).?;
                    self.pos += 1;
                    break :blk d;
                },
                else => Ast.Direction.input, // else: no direction keyword, so A.2.7's `input` default
            };
            const ty = varType(self.peek()) orelse .unspecified;
            if (ty != .unspecified) self.pos += 1 else _ = try parse_module.optDiscipline(self);
            const dims = try parseDims(self);
            const at = self.pos;
            try args.append(self.arena, .{
                .name = try self.expectIdent(),
                .ty = ty,
                .direction = dir,
                .dims = dims,
                .main_tok = at,
            });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    _ = try self.expect(.semicolon);

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var body: std.ArrayList(Ast.StmtId) = .empty;

    // §4.7.1's two body restrictions are checked at the syntax that
    // violates them (`begin :` and `return ;`), not by a walk afterwards,
    // so the diagnostic lands on the offending token. Analog functions do
    // not nest — A.2.6 has no analog_function_declaration inside a function
    // body — so a plain save/restore is the whole scope discipline.
    const saved_in_fn = self.in_analog_fn;
    self.in_analog_fn = is_analog;
    defer self.in_analog_fn = saved_in_fn;

    while (true) {
        try self.skipAttributes();
        switch (self.peek()) {
            .eof, .kw_endfunction => break,
            .kw_input, .kw_output, .kw_inout => {
                const dir = parse_module.portDirection(self.peek()).?;
                self.pos += 1;
                // `input real x;` (A.2.7 task_port_type) or bare `input x;`
                const ty = varType(self.peek()) orelse .unspecified;
                if (ty != .unspecified) self.pos += 1 else _ = try parse_module.optDiscipline(self);
                // A.2.6 `input_declaration ::= input [ range ] list_of_ports`
                // — one range, BEFORE the names, shared by all of them.
                // §4.7.2.3's own example is `output [0:1] out;` and §4.7.1's
                // Example 3 is `inout [0:1]a;`.
                const dims = try parseDims(self);
                while (true) {
                    const at = self.pos;
                    try args.append(self.arena, .{
                        .name = try self.expectIdent(),
                        .ty = ty,
                        .direction = dir,
                        .dims = dims,
                        .main_tok = at,
                    });
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            .kw_parameter, .kw_localparam => {
                try parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
                // A variable that re-declares an argument only types it —
                // and, per §4.7.1 Example 3 (`inout [0:1]a; real a[0:1];`),
                // may be where the SHAPE is written instead of on the
                // direction. Whichever carries it wins; they agree in every
                // example the LRM prints.
                var i = vars.items.len;
                while (i > first) {
                    i -= 1;
                    for (args.items) |*a| {
                        if (a.name != vars.items[i].name) continue;
                        if (a.ty == .unspecified) a.ty = vars.items[i].ty;
                        if (a.dims.len == 0) a.dims = vars.items[i].dims;
                        _ = vars.orderedRemove(i);
                        break;
                    }
                }
            },
            else => { // else: not a declaration, so the function body's statement
                const before = self.pos;
                const s = parse_stmt.parseStmt(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    self.recoverStatement(before);
                    continue;
                };
                try body.append(self.arena, s);
            },
        }
    }
    _ = try self.expect(.kw_endfunction);

    // §4.7.1 bullet list: "shall have at least one input argument declared".
    if (args.items.len == 0) {
        try self.report(main_tok, .E0224, "`{s}` has an empty formal list", .{self.file.str(name)});
    }
    // §4.7.1 bullet list: "all formal arguments shall have an associated
    // block item declaration specifying the data type of the argument".
    // A formal still `.unspecified` here got neither `input real x;` nor a
    // matching `real x;` above, so there is nothing left to type it —
    // defaulting it to `.real` (which this used to do) is exactly the
    // papering-over the bullet exists to forbid. The type is set anyway,
    // after the diagnostic, so the rest of the pipeline stays well-typed
    // while the compile is already doomed.
    for (args.items) |*a| if (a.ty == .unspecified) {
        var d = self.failWith(a.main_tok, .E0225);
        d.msg("formal `{s}` of `{s}` has no data type declaration", .{
            self.file.str(a.name), self.file.str(name),
        });
        d.help("add `real {s};` to the function body, or write the type on the direction: `input real {s};`", .{
            self.file.str(a.name), self.file.str(a.name),
        });
        try d.emit();
        a.ty = .real;
    };
    const body_id: Ast.StmtId = if (body.items.len == 1)
        body.items[0]
    else
        try self.file.addStmt(self.arena, .{ .block = .{ .body = body.items } }, main_tok);

    try b.functions.append(self.arena, .{
        .is_analog = is_analog,
        .name = name,
        .ret_ty = ret_ty,
        .args = args.items,
        .params = params.items,
        .vars = vars.items,
        .body = body_id,
        .main_tok = main_tok,
    });
}

// -----------------------------------------------------------------------
// A.1.6 nature_declaration / A.1.7 discipline_declaration — LRM §3.6
// -----------------------------------------------------------------------

/// LRM §3.6.1 (A.1.6). Base natures must declare `abstol` and `access`;
/// that check is lowering's, not the grammar's.
pub fn parseNature(self: *Parser) Error!Ast.NatureDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'nature'
    const name = try self.expectIdent();
    var parent: Ast.StrId = .none;
    var parent_access: ?Ast.PotentialOrFlow = null;
    if (self.eat(.colon)) {
        parent = try self.expectIdent();
        // A.1.6 `discipline_identifier . potential_or_flow`
        if (self.eat(.dot)) {
            parent_access = switch (self.peek()) {
                .kw_potential => .potential,
                .kw_flow => .flow,
                else => return self.failAt(self.pos, .E0211, "found {s}", .{self.found(self.pos)}), // else: A.1.6 names `potential` or `flow` and nothing else: E0211
            };
            self.pos += 1;
        }
    }
    _ = self.eat(.semicolon);

    var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
    while (self.peek() != .kw_endnature and self.peek() != .eof) {
        const attr = try parseNatureAttr(self);
        // §3.6.1.4: this is where the branch-probe names come from.
        if (self.file.strings.eql(attr.name, "access") and
            self.file.exprs.tag(attr.value) == .ident)
        {
            const access = self.file.str(self.file.exprs.strOf(attr.value));
            try self.access_names.put(self.arena, access, {});
        }
        try attrs.append(self.arena, attr);
    }
    _ = try self.expect(.kw_endnature);
    return .{
        .name = name,
        .parent = parent,
        .parent_access = parent_access,
        .attrs = attrs.items,
        .main_tok = main_tok,
    };
}

/// A.1.6 `nature_attribute ::= identifier = nature_attribute_expression ;`.
/// The LRM-defined attribute names (§3.6.1.2 abstol, §3.6.1.3 units,
/// §3.6.1.4 access, §3.6.1.5/6 idt_nature/ddt_nature) are keywords.
pub fn parseNatureAttr(self: *Parser) Error!Ast.NatureAttr {
    const tok = self.pos;
    const name: Ast.StrId = switch (self.peek()) {
        .identifier, .escaped_identifier => try self.expectIdent(),
        .kw_abstol, .kw_access, .kw_units, .kw_ddt_nature, .kw_idt_nature => blk: {
            const s = try self.file.intern(self.arena, parse_expr.tokenText(self, self.pos));
            self.pos += 1;
            break :blk s;
        },
        else => return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)}), // else: not a nature attribute name: E0208
    };
    _ = try self.expect(.assign_eq);
    const value = try parse_expr.parseExpr(self);
    _ = try self.expect(.semicolon);
    return .{ .name = name, .value = value, .main_tok = tok };
}

/// LRM §3.6.2 (A.1.7).
pub fn parseDiscipline(self: *Parser) Error!Ast.DisciplineDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'discipline'
    const name = try self.expectIdent();
    _ = self.eat(.semicolon);

    var d: Ast.DisciplineDecl = .{ .name = name, .main_tok = main_tok };
    var overrides: std.ArrayList(Ast.DisciplineDecl.Override) = .empty;
    var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
    while (self.peek() != .kw_enddiscipline and self.peek() != .eof) {
        switch (self.peek()) {
            // §3.6.2.1 nature_binding / §3.6.2.3 nature_attribute_override
            .kw_potential, .kw_flow => {
                const which: Ast.PotentialOrFlow =
                    if (self.peek() == .kw_potential) .potential else .flow;
                self.pos += 1;
                if (self.eat(.dot)) {
                    try overrides.append(self.arena, .{
                        .which = which,
                        .attr = try parseNatureAttr(self),
                    });
                } else {
                    const nature = try self.expectIdent();
                    _ = try self.expect(.semicolon);
                    if (which == .potential) d.potential = nature else d.flow = nature;
                }
            },
            // §3.6.2.2 domain binding
            .kw_domain => {
                self.pos += 1;
                d.domain = switch (self.peek()) {
                    .kw_continuous => .continuous,
                    .kw_discrete => .discrete,
                    else => return self.failAt(self.pos, .E0212, "found {s}", .{self.found(self.pos)}), // else: A.1.7 names `continuous` or `discrete` and nothing else: E0212
                };
                self.pos += 1;
                _ = try self.expect(.semicolon);
            },
            // §3.6.2.7 "Like natures, a discipline can specify user-defined
            // attributes." A.1.7's discipline_item omits the production —
            // the grammar and the prose contradict — and VerA reads the
            // explicit prose as governing and the annex as a non-exhaustive
            // erratum: real designs and tools attach attributes to
            // disciplines, and the sentence exists for them. Same shape as
            // a nature's user attribute (A.1.6 nature_attribute), gated on
            // the `=` so a stray identifier still gets E0213's "expected a
            // discipline item" rather than a mid-production "expected '='".
            .identifier, .escaped_identifier => {
                if (self.peekAt(1) != .assign_eq)
                    return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)});
                try attrs.append(self.arena, try parseNatureAttr(self));
            },
            else => return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)}), // else: not a discipline_item: E0213
        }
    }
    _ = try self.expect(.kw_enddiscipline);
    d.overrides = overrides.items;
    d.attrs = attrs.items;
    return d;
}
