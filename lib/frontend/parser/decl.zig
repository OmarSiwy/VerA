//! Declarations: annex A.2.1.1 parameters (§3.4), A.2.6 analog functions
//! (§4.7.1), A.1.6/A.1.7 natures and disciplines (§3.6), A.2.1.3/A.2.2 port,
//! net and branch declarations (§3.6.3, §6.5.2) -> `Ast.ParamDecl`,
//! `Ast.FuncDecl`, `Ast.NatureDecl`, `Ast.DisciplineDecl`, and port, net and
//! branch rows of `parse_module.Body`. IEEE 1364-2005 §6.1.4, §7.14, §10.2
//! and §10.4 for the digital forms.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const Ast = @import("../ast.zig");
const token = @import("../token.zig");
const constfold = @import("../constfold.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.2.1.1 parameter declarations: LRM §3.4
// -----------------------------------------------------------------------

/// A.2.1.1 `aliasparam_declaration`, from the keyword through the `;`. Shared
/// by module items and A.1.9 paramset items.
pub fn parseAliasparam(self: *Parser) Error!Ast.AliasParam {
    self.pos += 1; // 'aliasparam'
    const alias = try self.expectIdent();
    _ = try self.expect(.assign_eq);
    // §3.4.7 prints `aliasparam m = $mfactor;`, though Syntax 3-2 puts a
    // parameter_identifier on the right, so a §9.18 system parameter is
    // admitted here too. Which ones have storage to alias is
    // `Lower.aliasSystemParam`'s question.
    const target = try self.expectIdentOrSys();
    _ = try self.expect(.semicolon);
    return .{ .alias = alias, .target = target };
}

/// Parses a `parameter`/`localparam` declaration, value ranges included
/// (§3.4, §3.4.1, §3.4.2, §3.4.5), up to but not including the `;`.
/// `parameter real a = 1, b = 2;` is one declaration but two `ParamDecl`s,
/// so each is appended to `out`.
pub fn parseParamDecl(self: *Parser, out: *std.ArrayList(Ast.ParamDecl)) Error!void {
    const is_local = self.peek() == .kw_localparam;
    self.pos += 1;
    _ = self.eat(.kw_signed);
    // §3.4.1: no type keyword is `.unspecified`, inferred from the default
    // by lowering.
    const ty = varType(self.peek()) orelse .unspecified;
    if (ty != .unspecified) self.pos += 1;
    // A.2.1.1's first arm, `parameter [ signed ] [ range ] list_of_param_assignments`.
    // The range is a width, not a §3.4.4 array dimension, so it goes in
    // `packed_range` as a `reg`'s does. The arms are exclusive, so a range is
    // read only when no `parameter_type` was written. The bracket does not
    // set the type: §3.4.1 derives an unspecified type from the final value.
    //
    // ponytail: the width is carried, not enforced. `parameter [3:0] p =
    // 8'hff;` reads 255 here and 15 in a tool that truncates. Enforcing it is
    // a fold and a mask in lowering, where the default is already folded.
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
        // A.1.3's `parameter_declaration { , parameter_declaration }` and
        // A.2.1.1's `list_of_param_assignments` share the comma, so a
        // `parameter` keyword after one ends this list. Only a
        // module_parameter_port_list reaches this; in a body it makes the
        // illegal `parameter real a = 1, parameter real b = 2;` E0207 at `;`.
        if (self.peek() != .comma) break;
        if (self.tags[self.pos + 1] == .kw_parameter or
            self.tags[self.pos + 1] == .kw_localparam) break;
        self.pos += 1;
    }
}

/// LRM §3.4.2 / A.2.5 value_range. The ranges are the only parameter bound
/// evidence `proof.zig` gets, so each must reach `ParamDecl.ranges`.
fn parseRange(self: *Parser) Error!Ast.ValueRange {
    const kind: Ast.ValueRange.Kind = if (self.peek() == .kw_from) .from else .exclude;
    self.pos += 1;

    // `from '{"a", "b"}`: a string-set range (§3.4.2).
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

    // `exclude constant_expression`: A.2.5 gives the bare form to `exclude`
    // only. `from 5` is user input, so it is a diagnostic, not an assert.
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
    // `exclude ( expr )`: a parenthesized single value, not a range.
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
fn parseValueRangeExpr(self: *Parser) Error!Ast.ExprId {
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
/// function's return type is narrower (A.2.6), so `parseFuncDecl` has its own.
fn varType(tag: token.Tag) ?Ast.Type {
    return switch (tag) {
        .kw_integer, .kw_time => .integer,
        .kw_real, .kw_realtime => .real,
        .kw_string => .string,
        else => null, // else: not one of the five variable-type keywords
    };
}

/// Parses an A.2.1.3 integer/real/string/time declaration (§3.2, §3.3), cursor
/// on the type keyword, up to but not including the `;`. Appends one `VarDecl`
/// per name to `out`. Asserts the cursor is on a variable type keyword.
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
    const automatic = self.reservedIs(self.pos, "automatic");
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
            try ports.append(self.arena, try tfFormal(self, dir, ty));
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
                try ports.append(self.arena, try tfFormal(self, d, ty));
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
    while (!(self.peek() == .kw_endfunction or self.reservedIs(self.pos, end_word)) and self.peek() != .eof) {
        try body.append(self.arena, try parse_stmt.parseStmt(self));
    }
    if (self.peek() == .kw_endfunction or self.reservedIs(self.pos, end_word)) {
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

fn tfFormal(self: *Parser, dir: Ast.Direction, ty: Ast.VarDecl) Error!Ast.TfPort {
    var v = ty;
    v.main_tok = self.pos;
    v.name = try self.expectIdent();
    return .{ .direction = dir, .v = v };
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

/// The width of `[msb:lsb]` when both bounds are integer literals, else null.
///
/// ponytail: literals only. Folding `[W-1:0]` needs the constant evaluator,
/// which lives in lowering.
pub fn literalWidth(self: *const Parser, d: Ast.Dim) ?u64 {
    const ex = &self.file.exprs;
    if (ex.tag(d.msb) != .int_literal or ex.tag(d.lsb) != .int_literal) return null;
    return @abs(ex.intValue(d.msb) - ex.intValue(d.lsb)) + 1;
}

/// Parses zero or more A.2.5 dimensions after a declared name: A.2.2.1
/// `variable_type ::= identifier { dimension }` and A.2.1.1's
/// `parameter_identifier { dimension }`, as in §3.2's
/// `real vtable[0:16][0:7][0:64];`. Lowering scalarizes them (`dimsBounds`).
pub fn parseDims(self: *Parser) Error![]const Ast.Dim {
    if (self.peek() != .lbracket) return &.{};
    var dims: std.ArrayList(Ast.Dim) = .empty;
    while (self.peek() == .lbracket)
        try dims.append(self.arena, try parseDim(self));
    return dims.items;
}

/// An optional `[ range ]`: null unless the next token is `[`.
pub fn optDim(self: *Parser) Error!?Ast.Dim {
    return if (self.peek() == .lbracket) try parseDim(self) else null;
}

/// A.2.5 `dimension ::= [ expr : expr ]` (§3.2.2, §3.4.4).
fn parseDim(self: *Parser) Error!Ast.Dim {
    _ = try self.expect(.lbracket);
    const msb = try parse_expr.parseExpr(self);
    _ = try self.expect(.colon);
    const lsb = try parse_expr.parseExpr(self);
    _ = try self.expect(.rbracket);
    return .{ .msb = msb, .lsb = lsb };
}

// -----------------------------------------------------------------------
// A.2.6 analog_function_declaration (LRM §4.7.1), A.6.2 analog_construct
// -----------------------------------------------------------------------

/// Parses an A.6.2 `analog [initial]` construct into `b.analog`, or an
/// `analog function` declaration into `b.functions`. Cursor on `analog`.
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

/// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`, cursor
/// on `function`. Argument types come from the direction declaration
/// (`input real x;`) or from a matching variable declaration (`input x; real
/// x;`, A.2.6). Reports E0224 for no formals and E0225 for an untyped one,
/// then carries on.
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
    // A.2.6's ANSI spelling, `function_identifier ( tf_port_list ) ;`, beside
    // the non-ANSI one where the ports are declared in the body. The two are
    // not meant to be mixed, but nothing enforces it: the body loop reads a
    // stray `input` as one more argument, and the LRM names no diagnostic.
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
            try analogFormals(self, &args, dir, false);
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
    // not nest (A.2.6 has no analog_function_declaration inside a function
    // body), so a plain save/restore is the whole scope discipline.
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
                try analogFormals(self, &args, dir, true);
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
                // A variable that re-declares an argument only types it, and
                // per §4.7.1 Example 3 (`inout [0:1]a; real a[0:1];`) may carry
                // the shape instead of the direction. Whichever has it wins.
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
    // A formal still `.unspecified` got neither, so it is E0225. It is typed
    // `.real` after the diagnostic only to keep the rest of the parse
    // well-typed; the compile has already failed.
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

/// A function formal after its direction: `input real x` (A.2.7
/// task_port_type) or bare `input x`, then A.2.6 `input [ range ]
/// list_of_ports`: one range, before the names, shared by all of them
/// (§4.7.2.3 `output [0:1] out;`, §4.7.1 Example 3 `inout [0:1]a;`).
/// `list` reads `, name` onward, as a body declaration does; a port-list
/// entry names one formal.
fn analogFormals(self: *Parser, args: *std.ArrayList(Ast.FuncArg), dir: Ast.Direction, list: bool) Error!void {
    const ty = varType(self.peek()) orelse .unspecified;
    if (ty != .unspecified) self.pos += 1 else _ = try parse_module.optDiscipline(self);
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
        if (!list or !self.eat(.comma)) break;
    }
}

// -----------------------------------------------------------------------
// A.1.6 nature_declaration / A.1.7 discipline_declaration: LRM §3.6
// -----------------------------------------------------------------------

/// Parses a §3.6.1 nature declaration (A.1.6), cursor on `nature`. Each
/// `access = X;` attribute adds `X` to `access_names`, so later `X(...)` parse
/// as branch probes. Whether a base nature declares `abstol` and `access` is
/// lowering's check.
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
            const s = try self.file.intern(self.arena, self.tokenText(self.pos));
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

/// Parses a §3.6.2 discipline declaration (A.1.7), cursor on `discipline`.
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
            // §3.6.2.7: "Like natures, a discipline can specify user-defined
            // attributes." A.1.7's discipline_item omits the production; VerA
            // follows the prose. Gated on the `=` so a stray identifier still
            // gets E0213 rather than a mid-production "expected '='".
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

// -----------------------------------------------------------------------
// A.2.1.3/A.2.2 port, net and branch declarations: LRM §3.6.3, §6.5.2
// -----------------------------------------------------------------------

/// Parses a §6.5.2 body port declaration, cursor on the direction keyword. It
/// sets the direction and discipline of existing header ports; it does not
/// introduce a terminal. Reports E0206 for a name that is not a header port
/// and E0218 for a port that already has a direction.
pub fn parsePortDecl(self: *Parser, b: *parse_module.Body) Error!void {
    const dir = parse_module.portDirection(self.peek()).?;
    self.pos += 1;
    // A.2.1.2's `[ net_type | wreal ]`, §7.9's resolution input (`Ast.Port.kind`).
    var kind: Ast.NetKind = .wire;
    var signed = false;
    const disc = try parse_module.optPortType(self, &kind, &signed);
    // A.2.1.2's two variable arms, which only `output` has:
    //
    //     output_declaration ::=
    //         output [ discipline_identifier ] [ net_type | wreal ] [ signed ]
    //             [ range ] list_of_port_identifiers
    //       | output [ discipline_identifier ] reg [ signed ] [ range ]
    //             list_of_variable_port_identifiers
    //       | output output_variable_type list_of_variable_port_identifiers
    //     output_variable_type ::= integer | time
    //
    // `optPortType` has already read the first arm's `[ net_type ]`, so this
    // keyword is what tells the arms apart. A variable port gets a `VarDecl`
    // as well as the direction, and only it may carry A.2.3's
    // `[ = constant_expression ]`.
    const var_storage = try optVarStorage(self, dir);
    if (var_storage != null) signed = self.eat(.kw_signed);
    // §6.5.2.2's "port direction declaration" range. Lowering compares it
    // with the port type declaration's, so it lands in its own field.
    const range: ?Ast.Dim = try optDim(self);
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        if (var_storage) |storage| try varPort(self, b, storage, name, range, signed, tok);
        if (findPort(b, name)) |p| {
            if (signed) p.is_signed = true;
            // §6.2 "Ports declared in the list of port declarations shall
            // not be redeclared within the body of the module." Only an ANSI
            // header or an earlier body declaration (§6.8) gives a direction,
            // so a port that has one is already declared.
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
}

/// A.2.1.2's variable arms of `output_declaration`, cursor after the
/// direction and any net type: consumes `integer`, `time` or `reg` and
/// returns the storage it names, or null when none is there. Another
/// direction with one is E0207.
pub fn optVarStorage(self: *Parser, dir: Ast.Direction) Error!?@FieldType(Ast.VarDecl, "storage") {
    const storage: @FieldType(Ast.VarDecl, "storage") = switch (self.peek()) {
        .kw_integer => .variable, // A.2.2.1 output_variable_type
        .kw_time => .time, // …its other alternative
        .kw_reg => .reg, // A.2.1.2's second arm
        else => return null, // else: not a variable-storage keyword
    };
    if (dir != .output) return self.failAt(
        self.pos,
        .E0207,
        "found {s}: A.2.1.2 gives a variable type to `output` only",
        .{self.found(self.pos)},
    );
    self.pos += 1;
    return storage;
}

/// The `VarDecl` of one variable port `name`, cursor after the name: A.2.3
/// `list_of_variable_port_identifiers ::= port_identifier
/// [ = constant_expression ] { , ... }`.
pub fn varPort(self: *Parser, b: *parse_module.Body, storage: @FieldType(Ast.VarDecl, "storage"), name: Ast.StrId, range: ?Ast.Dim, signed: bool, tok: u32) Error!void {
    const init_expr: Ast.ExprId = if (self.eat(.assign_eq)) try parse_expr.parseExpr(self) else .none;
    try b.vars.append(self.arena, .{
        .name = name,
        // Both arms are integral: A.2.2.1's `output_variable_type` is
        // `integer | time`, and §3.4.1 folds `time` to the same
        // representation VerA gives an `integer`; Table 7-1 does the same
        // for a `reg`'s bits.
        .ty = .integer,
        .init = init_expr,
        .storage = storage,
        .packed_range = range,
        .is_signed = signed,
        .main_tok = tok,
    });
}

/// Returns the header port named `name`, or null. The pointer is invalidated
/// by the next append to `b.ports`.
pub fn findPort(b: *parse_module.Body, name: Ast.StrId) ?*Ast.Port {
    for (b.ports.items) |*p| if (p.name == name) return p;
    return null;
}

/// Parses a §6.7 hierarchical name in a declaration position and interns it as
/// one string with `.` between the parts. `Elaborate.sep` is the same period,
/// so the string a `defparam` path or an Annex F.2.1 out-of-context
/// declaration writes is the flat name elaboration gives the entity. Each part
/// went through `internTok`, so none carries a period of its own.
///
/// `allow_index` admits A.9.3's per-segment `[ constant_expression ]`, which
/// selects one element of a §6.2.2 instance array on any segment but the
/// last. The index is folded here and spelled `[{d}]`, the spelling
/// elaboration gives array elements (`Flatten.walkInstances`); an index that
/// does not fold is E0231. Net declarations pass `false`, because there a `[`
/// after the name is A.2.1.3's vector range.
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
            // A.9.3: an indexed segment is always followed by `.`; the final
            // identifier of a path carries no index.
            _ = try self.expect(.dot);
        } else if (!self.eat(.dot)) break;
        const part = try self.expectIdent();
        try joined.append(self.arena, '.');
        try joined.appendSlice(self.arena, self.file.str(part));
    }
    return self.file.intern(self.arena, joined.items);
}

/// Folds A.9.3's `[ constant_expression ]` over literals only, with §4.2's
/// integer typing: the same kernel elaboration applies to the instance-array
/// range. Parameters are elaboration's, so a read of one does not fold, and
/// neither does a real-valued index.
fn constIndex(self: *Parser, e: Ast.ExprId) ?i64 {
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
        else => null, // else: not a net_type keyword
    };
}

/// One A.2.2.2 strength keyword: its IEEE 1364-2005 clause 7 level and the
/// side it may occupy. `side` is 0 for `strength0` and `highz0`, 1 for their
/// `1` spellings, and 2 for a `charge_strength` (`small`/`medium`/`large`),
/// which only A.2.1.3's `trireg` alternatives take. The charge words are
/// listed so they can be recognised and refused elsewhere.
pub const StrengthWord = struct { level: Ast.Strength, side: u8 };
const strength_words = std.StaticStringMap(StrengthWord).initComptime(.{
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

/// Returns the strength keyword at token `i`, or null. Every strength spelling
/// lexes as `.kw_reserved` except `supply0`/`supply1`, which are also A.2.2.1
/// net types with their own tags, so both are looked up by spelling.
pub fn strengthWord(self: *const Parser, i: u32) ?StrengthWord {
    return switch (self.tags[i]) {
        .kw_reserved, .kw_supply0, .kw_supply1 => strength_words.get(self.tokenText(i)),
        else => null, // else: no other tag can spell a strength
    };
}

/// Parses an A.2.2.2 `drive_strength` into `s0`/`s1`: one 0-side and one
/// 1-side strength, in either order, not both `highz`. Precondition: the
/// cursor is on a `(` the caller has decided opens a strength.
pub fn parseDriveStrength(self: *Parser, s0: *Ast.Strength, s1: *Ast.Strength) Error!void {
    _ = try self.expect(.lparen);
    const first_tok = self.pos;
    const a = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.comma);
    const b = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.rparen);
    // `(strong0, pull0)` derives from no alternative of A.2.2.2.
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

/// Parses A.2.1.3's `charge_strength ::= ( small ) | ( medium ) | ( large )`,
/// which only `trireg` takes. Reports E0207 for a charge strength on any other
/// net type, so `wire (small) w;` is refused. Cursor on the `(`.
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

/// A.2.2.3 `delay3 ::= # delay_value | # ( mintypmax_expression [ ,
/// mintypmax_expression [ , mintypmax_expression ] ] )`. Cursor on the `#`.
/// Each value is parsed as a plain expression; the `min:typ:max` form is not.
///
/// One value is all three transitions (IEEE 1364-2005 §7.14). Two leave
/// `off` unset, because the clause derives it as the smaller of the two and
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
    // After the third value the production admits only `)`. E0210 names the
    // missing parenthesis; E0207 would send the reader to the previous
    // statement.
    if (self.peek() != .rparen) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
    self.pos += 1;
    return out;
}

/// One delay value, parsed as an expression. A `min:typ:max` value is not
/// admitted here, though A.2.2.3's parenthesized arm allows one.
fn parseDelayValue(self: *Parser) Error!Ast.ExprId {
    return parse_expr.parseExpr(self);
}

/// Parses an A.2.1.3 `list_of_net_identifiers ;` (§3.6.3) after the discipline
/// or net type: an optional range and `delay3`, then the names. A name that is
/// a header port binds the discipline to that port instead of declaring a new
/// net, so lowering sees one object per terminal. The range and delay apply to
/// every name. A §3.6.3.2 `= expression` nodeset is read unless `is_ground`.
pub fn parseNetNames(self: *Parser, b: *parse_module.Body, disc: Ast.StrId, kind: Ast.NetKind, is_ground: bool, st: Ast.NetStrength, signed: bool) Error!void {
    const range: ?Ast.Dim = try optDim(self);
    // A.2.1.3 puts `[ delay3 ]` between the range and the name list, and it
    // belongs to the net, not to the optional assignment: `wire #3 y = ~a;`
    // delays y's own transition. Not gated on `digital`: §1.1 includes all of
    // IEEE 1364, and A.2.1.3 grants the bracket to every alternative. Analog
    // lowering does not read it.
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parseDelay3(self) else .{};
    while (true) {
        const tok = self.pos;
        // Annex F.2.1 step 3 / §3.10 order 1: an out-of-context declaration,
        // `electrical top.middle.bottom.sig;`, "overrides any discipline which
        // may be declared for sig in the module where sig was declared". The
        // dotted name never matches `findPort`, so it lands as a net
        // declaration under its path and elaboration reads it as one.
        const name = try parseDottedName(self, false);
        // §3.6.3.2 `net_decl_assignment`: "the initializer shall be a
        // constant_expression and will be used as a nodeset value for the
        // potential of the net by the analog solver". It is an initial guess
        // for the host's solver, not an assignment. `ground` has no such form
        // (Syntax 3-7), so its `=` stays E0207. Lowering judges both rules:
        // non-constant is E0365, a non-continuous discipline is E0366.
        const nodeset: Ast.ExprId = if (!is_ground and self.eat(.assign_eq))
            try parse_expr.parseExpr(self)
        else
            .none;
        // Only the first declaration binds. A port that already has a
        // discipline gets a net entry instead, so lowering sees both and can
        // apply §7.4.4 (E0902). The entry adds no node: `internNode` finds the
        // port's slot by name.
        const port = if (is_ground) null else findPort(b, name);
        if (port != null and signed) port.?.is_signed = true;
        if (port != null and port.?.discipline == .none) {
            port.?.discipline = disc;
            // §6.5.2.2: this is the port type declaration. Recorded beside the
            // direction declaration's range, not over it (`Ast.Port.type_range`).
            port.?.type_range = range;
            // The net type too: §7.9 resolves by it, so `tri0 p;` on a port
            // must not stay a `wire`. A discipline-only declaration passes
            // `.wire`, A.2.1.3's default.
            port.?.kind = kind;
            // A Port has no initializer slot, so `electrical p = 5.0;` on a
            // header port gets a net entry with no discipline for the
            // nodeset. The empty discipline keeps it out of §7.4.4 (E0902),
            // and `internNode` finds the port's slot without overwriting it.
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

/// Parses both arms of a §3.12 / A.2.1.3 `branch_declaration`, cursor on
/// `branch`:
///
///     branch ( a [, b] )  list_of_branch_identifiers ;
///     branch ( < p > )    list_of_branch_identifiers ;   // Syntax 3-9
///
/// The second is a §3.12.1 port branch, the quantity `I(<p>)` reads, given a
/// name. A.2.3's optional `[ range ]` per name declares a branch array over
/// one terminal pair; lowering expands it, where the bounds can be folded.
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
            .range = try optDim(self),
            .main_tok = name_tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
