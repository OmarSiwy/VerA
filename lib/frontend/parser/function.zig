//! Subroutines: annex A.2.6 analog_function_declaration (§4.7.1) and IEEE
//! 1364-2005 A.2.6/A.2.7 digital function and task declarations (§10.2,
//! §10.4) -> `Ast.FuncDecl` rows of `Body.functions` and `Ast.Subroutine`
//! rows of `Body.tasks`. The body statements go through `stmt.zig`.
//!
//! LRM clauses cited: §4.7, §4.7.1, §4.7.2.3; IEEE 1364-2005 §10.2, §10.2.1,
//! §10.4.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_module = @import("module.zig");
const parse_net = @import("net.zig");
const parse_stmt = @import("stmt.zig");
const parse_expr = @import("expr.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.2.6 analog_function_declaration: LRM §4.7.1
// -----------------------------------------------------------------------

/// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`, cursor
/// on `function`. Argument types come from the direction declaration
/// (`input real x;`) or from a matching variable declaration (`input x; real
/// x;`, A.2.6). Reports E0224 for no formals and E0225 for an untyped one,
/// then carries on.
///
/// A function without `analog` (an analog parse's digital function, §4.7)
/// takes A.2.6's `function_declaration` header and A.2.7's `tf_*_declaration`
/// formals, as `parseSubroutine` reads them: `automatic`, `[ signed ]
/// [ range ]`, `realtime`, `time`, `reg` formals, and an untyped formal, which
/// A.2.7's `input [ reg ] [ signed ] [ range ]` makes a 1-bit `reg` (so no
/// E0225). Only the type's class is kept: the analog compile refuses a call
/// to it (E0436), and the mixed-signal kernel runs it from its own digital
/// parse.
pub fn parseFuncDecl(self: *Parser, b: *parse_module.Body, main_tok: u32, is_analog: bool) Error!void {
    self.pos += 1; // 'function'
    const ret_ty: Ast.Type = if (!is_analog) digital: {
        if (self.reservedIs(self.pos, "automatic")) self.pos += 1;
        if (self.peek() == .kw_string) {
            self.pos += 1;
            break :digital .string;
        }
        if (!tfTypeAhead(self)) break :digital .real;
        break :digital (try tfPortType(self)).ty;
    } else switch (self.peek()) {
        .kw_integer => .integer,
        .kw_real => .real,
        .kw_string => .string,
        else => .real, // else: no type keyword, so §4.7.1's `real` default
    };
    if (is_analog and (self.peek() == .kw_integer or self.peek() == .kw_real or self.peek() == .kw_string)) {
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
            try self.skipAttributes();
            const dir = switch (self.peek()) {
                .kw_input, .kw_output, .kw_inout => blk: {
                    const d = parse_net.portDirection(self.peek()).?;
                    self.pos += 1;
                    break :blk d;
                },
                else => Ast.Direction.input, // else: no direction keyword, so A.2.7's `input` default
            };
            try analogFormals(self, &args, dir, false, is_analog);
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
        // A.2.8 block_item_declaration's `reg_declaration`, a digital
        // function's local (A.2.6 `function_item_declaration`).
        if (!is_analog and self.peek() == .kw_reg) {
            try parse_decl.parseRegDecl(self, &vars);
            continue;
        }
        switch (self.peek()) {
            .eof, .kw_endfunction => break,
            .kw_input, .kw_output, .kw_inout => {
                const dir = parse_net.portDirection(self.peek()).?;
                self.pos += 1;
                try analogFormals(self, &args, dir, true, is_analog);
                _ = try self.expect(.semicolon);
            },
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parse_decl.parseVarDecl(self, &vars);
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
                const saved_expr = self.analog_expr;
                self.analog_expr = is_analog;
                defer self.analog_expr = saved_expr;
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
        if (!is_analog) {
            a.ty = .integer; // A.2.7 `input [ reg ] ...`: a 1-bit `reg`
            continue;
        }
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
///
/// After a discipline, A.2.1.2's `output [ discipline_identifier ] reg
/// [ signed ] [ range ]` and A.2.7's `tf_*_declaration` write `reg [ signed ]`:
/// read, and no data type for an analog function (§4.7.1 types a formal by a
/// block item declaration: E0225). A digital function's formal takes
/// `tfPortType`'s A.2.7 types, its range a packed width, not dimensions.
fn analogFormals(self: *Parser, args: *std.ArrayList(Ast.FuncArg), dir: Ast.Direction, list: bool, is_analog: bool) Error!void {
    var ty = parse_decl.varType(self.peek()) orelse .unspecified;
    if (ty != .unspecified) self.pos += 1 else _ = try parse_net.optDiscipline(self);
    var dims: []const Ast.Dim = &.{};
    if (ty == .unspecified and !is_analog) {
        if (tfTypeAhead(self)) ty = (try tfPortType(self)).ty;
    } else {
        if (ty == .unspecified and self.eat(.kw_reg)) _ = self.eat(.kw_signed);
        dims = try parse_decl.parseDims(self);
    }
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
// IEEE 1364-2005 A.2.6/A.2.7 function and task declarations, digital parse
// -----------------------------------------------------------------------

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
    if (is_function and result.storage == .reg and result.packed_range == null and self.peek() == .lbracket) result.packed_range = try parse_decl.parseDim(self);
    const name_tok = self.pos;
    const name = try self.expectIdent();
    result.name = name;
    result.main_tok = name_tok;
    var ports: std.ArrayList(Ast.TfPort) = .empty;
    if (self.eat(.lparen)) {
        var dir: Ast.Direction = .input;
        var ty: Ast.VarDecl = .{ .name = .none, .ty = .integer, .storage = .reg, .is_signed = false };
        var attr_tok: ?u32 = null;
        while (self.peek() != .rparen and self.peek() != .eof) {
            try self.skipAttributes();
            if (parse_net.portDirection(self.peek())) |d| {
                attr_tok = self.pos;
                dir = d;
                self.pos += 1;
                ty = try tfPortType(self);
            }
            const formal = try tfFormal(self, dir, ty);
            if (attr_tok) |decl| try self.copyAttributes(decl, formal.v.main_tok);
            try ports.append(self.arena, formal);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    _ = try self.expect(.semicolon);
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var events: std.ArrayList(Ast.EventDecl) = .empty;
    const end_word = if (is_function) "endfunction" else "endtask";
    while (true) {
        try self.skipAttributes();
        if (parse_net.portDirection(self.peek())) |d| {
            const decl_tok = self.pos;
            self.pos += 1;
            const ty = try tfPortType(self);
            while (true) {
                const formal = try tfFormal(self, d, ty);
                try self.copyAttributes(decl_tok, formal.v.main_tok);
                try ports.append(self.arena, formal);
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
            continue;
        }
        switch (self.peek()) {
            .kw_reg, .kw_integer, .kw_time, .kw_real, .kw_realtime => try parseBlockVars(self, &vars),
            // A.2.8 block_item_declaration's constant and event arms.
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_event => {
                const decl_tok = self.pos;
                self.pos += 1;
                while (true) {
                    const event = try parse_decl.parseEventDecl(self);
                    try self.copyAttributes(decl_tok, event.main_tok);
                    try events.append(self.arena, event);
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
        .params = params.items,
        .events = events.items,
        .body = body_id,
        .main_tok = main_tok,
    });
}

/// One A.2.8 `block_item_declaration` of variables (`reg`, `integer`,
/// `time`, `real`, `realtime`), cursor on the keyword, through its `;`.
pub fn parseBlockVars(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
    const decl_tok = self.pos;
    const ty = try tfPortType(self);
    while (true) {
        var v = ty;
        v.main_tok = self.pos;
        v.name = try self.expectIdent();
        try self.copyAttributes(decl_tok, v.main_tok);
        v.dims = try parse_decl.parseDims(self);
        if (self.eat(.assign_eq)) v.init = try parse_expr.parseExpr(self);
        try out.append(self.arena, v);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
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
    if (v.storage == .reg and self.peek() == .lbracket) v.packed_range = try parse_decl.parseDim(self);
    return v;
}

/// Whether an A.2.7 `[ reg ] [ signed ] [ range ]` or `task_port_type`
/// begins at the cursor, so `tfPortType` reads a written type and not the
/// bare-direction default.
fn tfTypeAhead(self: *const Parser) bool {
    return switch (self.peek()) {
        .kw_reg, .kw_signed, .lbracket, .kw_integer, .kw_time, .kw_real, .kw_realtime => true,
        else => false, // else: no type is written here
    };
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
