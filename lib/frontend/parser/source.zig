//! Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations, A.5 UDPs.
//!
//! In: the token stream at file scope. Out: the top-level `Ast` items: module, nature,
//! discipline, connectrules, paramset, library, config and primitive declarations.
//!
//! LRM clauses cited: §1, §1.1, §2.2, §6.2, §6.4, §7.6, §7.7, §8.5.3, §10.6.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_inst = @import("inst.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.1.2 source_text
// -----------------------------------------------------------------------

/// Parses the whole token stream as annex A `source_text` and returns
/// `self.file` with every description appended after any seeded ones.
/// Returns `error.ParseError` if any diagnostic was an error; the
/// diagnostics are in `self.bag`.
pub fn parseSourceFile(self: *Parser) Error!Ast.SourceFile {
    try self.access_names.put(self.arena, "V", {});
    try self.access_names.put(self.arena, "I", {});

    // Seeded (`initSeeded`), these already hold the prefix's declarations in
    // source order; unseeded, they are empty.
    var modules: std.ArrayList(Ast.ModuleDecl) = .empty;
    var disciplines: std.ArrayList(Ast.DisciplineDecl) = .empty;
    var natures: std.ArrayList(Ast.NatureDecl) = .empty;
    var paramsets: std.ArrayList(Ast.ParamsetDecl) = .empty;
    var connectrules: std.ArrayList(Ast.ConnectRulesDecl) = .empty;
    var udps: std.ArrayList(Ast.UdpDecl) = .empty;
    var configs: std.ArrayList(Ast.ConfigDecl) = .empty;
    try modules.appendSlice(self.arena, self.file.modules);
    try disciplines.appendSlice(self.arena, self.file.disciplines);
    try natures.appendSlice(self.arena, self.file.natures);
    try paramsets.appendSlice(self.arena, self.file.paramsets);
    try connectrules.appendSlice(self.arena, self.file.connectrules);
    try udps.appendSlice(self.arena, self.file.udps);
    try configs.appendSlice(self.arena, self.file.configs);

    while (true) {
        const attr_at = self.pos;
        try self.skipAttributes();
        const before = self.pos;
        try self.refuseAms();
        switch (self.peek()) {
            // §3.8: an attribute instance is "a prefix attached to" what follows it.
            .eof => {
                if (before != attr_at) try self.report(attr_at, .E0207, "found end of file: an attribute instance prefixes nothing", .{});
                break;
            },
            // §10.6: legal only here, "outside of a design element".
            .dir_begin_keywords, .dir_end_keywords => keywordsDirective(self) catch |e| {
                if (e == error.OutOfMemory) return e;
                recoverTopLevel(self, before);
            },
            // IEEE 1364 §19.6: between design elements is where `resetall
            // belongs; the preprocessor has already applied it.
            .dir_resetall, .dir_outside_module => self.pos += 1,
            // A.1.2 `module_keyword ::= module | macromodule`. §6.2: "The
            // keyword macromodule can be used interchangeably with the
            // keyword module to define a module. An implementation may
            // choose to treat module definitions beginning with the
            // macromodule keyword differently." VerA treats them the same.
            // `connectmodule` (§7.6, Syntax 7-4) has the same header, items
            // and `endmodule`; `Ast.ModuleDecl.is_connect` records it.
            .kw_module, .kw_macromodule, .kw_connectmodule => try element(self, before, &modules, parse_module.parseModule(self)),
            .kw_discipline => try element(self, before, &disciplines, parse_decl.parseDiscipline(self)),
            .kw_nature => try element(self, before, &natures, parse_decl.parseNature(self)),
            // §6.4 / A.1.9 paramset_declaration. §6.4 makes a paramset
            // instantiable "exactly like a module"; `ir/elaborate.zig`
            // applies it.
            .kw_paramset => try element(self, before, &paramsets, parse_module.parseParamset(self)),
            // §7.7 / A.1.8 connectrules_declaration, read by annex F.2
            // discipline resolution (`ir/elaborate.zig`).
            .kw_connectrules => try element(self, before, &connectrules, parse_module.parseConnectRules(self)),
            // Annex B reserves `primitive`, `config`, `library` and
            // `include` without a tag of their own, so the spelling is the
            // dispatch.
            .kw_reserved => {
                const w = self.tokenText(self.pos);
                const r: Error!void = if (std.mem.eql(u8, w, "primitive")) udp: {
                    const u = parseUdpDecl(self) catch |e| break :udp e;
                    break :udp udps.append(self.arena, u);
                } else if (std.mem.eql(u8, w, "config"))
                    parseConfigDecl(self, &configs)
                else if (std.mem.eql(u8, w, "library") or std.mem.eql(u8, w, "include"))
                    parseLibraryDecl(self)
                else if (std.mem.eql(u8, w, "specify"))
                    // IEEE 1364-2005 §14.1: "it shall appear inside a module declaration".
                    self.failAt(self.pos, .E0245, "a specify block outside a module (§14.1)", .{})
                else
                    self.failAt(self.pos, .E0201, "`{s}`", .{self.found(self.pos)});
                r catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                };
            },
            else => { // else: not a description: E0201
                try self.report(self.pos, .E0201, "`{s}`", .{self.found(self.pos)});
                recoverTopLevel(self, before);
            },
        }
    }

    // §10.6: `begin_keywords "affects all source code that follows the
    // directive, even across source code file boundaries, until the
    // matching `end_keywords directive is encountered", so a stack still
    // open at end of file is not an error
    // (ch10_directives/31_begin_keywords_unterminated.va).

    self.file.modules = modules.items;
    self.file.disciplines = disciplines.items;
    self.file.natures = natures.items;
    self.file.paramsets = paramsets.items;
    self.file.connectrules = connectrules.items;
    self.file.udps = udps.items;
    self.file.configs = configs.items;
    if (self.failed) return error.ParseError;
    return self.file;
}

/// Applies one LRM §10.6 `begin_keywords "<version_specifier>" or
/// `end_keywords at the cursor, selecting which annex B words are reserved
/// for the design elements that follow (see `identLike`). The directives
/// nest, so the previous set is stacked. An unmatched `end_keywords is
/// E0136; an unknown specifier, or one newer than `self.language`, is E0135.
pub fn keywordsDirective(self: *Parser) Error!void {
    const tok = self.pos;
    self.pos += 1;
    if (self.tags[tok] == .dir_end_keywords) {
        self.kw_set = self.kw_stack.pop() orelse
            return self.failAt(tok, .E0136, "", .{});
        return;
    }
    const str = try self.expect(.string_literal);
    const raw = self.tokenText(str);
    const spec = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
    const known = token.KeywordSet.fromSpecifier(spec);
    // A 1364 language has no Verilog-AMS specifier to name.
    const set = if (known != null and @intFromEnum(known.?) <= @intFromEnum(self.language)) known.? else return self.failAt(
        str,
        .E0135,
        "`{s}`",
        .{spec},
    );
    try self.kw_stack.append(self.arena, self.kw_set);
    self.kw_set = set;
}

/// Reports E0202 if the cursor is a `begin_keywords or `end_keywords inside
/// the design element `what`. §10.6: "The `begin_keywords and `end_keywords
/// directives can only be specified outside of a design element (module,
/// primitive, configuration, paramset, connectrules or connectmodule)."
/// `parseModuleItem` covers modules itself.
pub fn outsideDesignElement(self: *Parser, what: []const u8) Error!void {
    const t = self.peek();
    if (t != .dir_begin_keywords and t != .dir_end_keywords) return;
    return self.failAt(self.pos, .E0202, "{s} inside a {s}", .{ token.Tag.lexeme(t).?, what });
}

/// Appends one parsed design element to `list`, or on a syntax error
/// recovers to the next element and appends nothing.
fn element(self: *Parser, before: u32, list: anytype, parsed: anytype) error{OutOfMemory}!void {
    const x = parsed catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        recoverTopLevel(self, before);
        return;
    };
    try list.append(self.arena, x);
}

/// Skips to the next token that can start a top-level description (A.1.2),
/// past any `end*` keyword that closes the construct being abandoned.
/// Always advances at least one token.
fn recoverTopLevel(self: *Parser, before: u32) void {
    if (self.pos == before) self.pos += 1;
    while (true) : (self.pos += 1) switch (self.peek()) {
        .eof => return,
        // Every keyword `parseSourceFile` dispatches a description on; a
        // missing one lets one bad description swallow the next.
        // `connectmodule` closes with `endmodule`, covered below.
        .kw_module, .kw_macromodule, .kw_connectmodule, .kw_discipline, .kw_nature, .kw_paramset, .kw_connectrules => return,
        .kw_endmodule, .kw_enddiscipline, .kw_endnature, .kw_endparamset, .kw_endconnectrules => {
            self.pos += 1;
            return;
        },
        // A.1.2's `primitive` and `config` open and close with reserved
        // spellings that have no tag.
        .kw_reserved => if (self.reservedIs(self.pos, "endprimitive") or
            self.reservedIs(self.pos, "endconfig"))
        {
            self.pos += 1;
            return;
        } else if (self.reservedIs(self.pos, "primitive") or
            self.reservedIs(self.pos, "config"))
        {
            if (self.pos != before) return;
        },
        else => {}, // else: any other token belongs to the description being skipped
    };
}

// -----------------------------------------------------------------------
// A.1.1 library source text, A.1.5 configuration: LRM §1.1
// -----------------------------------------------------------------------

/// Parses one of A.1.1's two library-map-only descriptions, then always
/// fails with E0232:
///
///     library_declaration ::=
///             library library_identifier file_path_spec [ { , file_path_spec } ]
///             [ -incdir file_path_spec { , file_path_spec } ] ;
///     include_statement ::= include file_path_spec ;
///
/// Annex A: "The syntax of Verilog-AMS HDL source is derived from the
/// starting symbol source_text. The syntax of a library map file is derived
/// from the starting symbol library_text", and these hang off
/// `library_text` alone. The production is walked first so the diagnostic
/// lands on the keyword of a construct that parsed. `file_path_spec` is
/// taken as a string literal only.
fn parseLibraryDecl(self: *Parser) Error!void {
    // ponytail: an unquoted `file_path` (`./lib/*.v`, as real map files
    // write it) is not a §2.2 token sequence. A library map file needs its
    // own reader, which is the work E0232 says is absent.
    const kw = self.pos;
    const is_library = self.reservedIs(kw, "library");
    self.pos += 1;
    if (is_library) _ = try self.expectIdent();
    while (true) {
        _ = try self.expect(.string_literal);
        if (!self.eat(.comma)) break;
    }
    // `-incdir file_path_spec { , file_path_spec }`, the one option the
    // production has. The `-` and the keyword are two tokens; §2.2 has no
    // production that joins them, so they are matched as two.
    if (is_library and self.eat(.minus)) {
        if (!self.reservedIs(self.pos, "incdir")) return self.failAt(self.pos, .E0207, "found {s}, and `-` begins only A.1.1's `-incdir`", .{self.found(self.pos)});
        self.pos += 1;
        while (true) {
            _ = try self.expect(.string_literal);
            if (!self.eat(.comma)) break;
        }
    }
    _ = try self.expect(.semicolon);
    return self.failAt(kw, .E0232, "`{s}` is a library_description, and this file is source_text", .{self.tokenText(kw)});
}

/// Parses one A.1.5 `config_declaration`, which A.1.2 lists as a
/// `description`, and appends it to `configs`:
///
///     config_declaration ::=
///             config config_identifier ;
///                 design_statement
///                 {config_rule_statement}
///             endconfig
///     design_statement ::= design { [library_identifier.]cell_identifier } ;
///
/// A digital run binds through it (`sim/digital`); an analog compile binds
/// nothing and warns W0253.
fn parseConfigDecl(self: *Parser, configs: *std.ArrayList(Ast.ConfigDecl)) Error!void {
    const kw = self.pos;
    self.pos += 1;
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);
    // `design_statement` is mandatory and comes first.
    if (!self.reservedIs(self.pos, "design")) return self.failAt(self.pos, .E0207, "found {s}: a config_declaration begins with its `design` statement", .{self.found(self.pos)});
    self.pos += 1;
    var design: std.ArrayList(Ast.LibCell) = .empty;
    while (self.peek() != .semicolon) try design.append(self.arena, try parseLibCell(self));
    self.pos += 1;
    var rules: std.ArrayList(Ast.ConfigRule) = .empty;
    while (!self.reservedIs(self.pos, "endconfig")) {
        if (self.peek() == .eof) return self.failAt(self.pos, .E0207, "found {s}: no `endconfig` closes the configuration", .{self.found(self.pos)});
        const rule = try parseConfigRule(self);
        // IEEE 1364-2005 §13.3.1.2: "there cannot be more than one default
        // clause that specifies the expansion clause", and liblist is the one
        // a default takes.
        if (rule.select == .default) for (rules.items) |r| if (r.select == .default)
            return self.failAt(rule.main_tok, .E0243, "more than one default clause specifies a liblist (IEEE 1364-2005 §13.3.1.2)", .{});
        try rules.append(self.arena, rule);
    }
    self.pos += 1;
    if (!self.digital) try self.bag.add(.parse, .W0253, lexer.tokenSpan(self.src, self.starts, kw), "", .{});
    try configs.append(self.arena, .{ .name = name, .design = design.items, .rules = rules.items, .main_tok = kw });
}

/// Syntax 13-1 `[library_identifier.]cell_identifier`, without the suffix.
fn parseLibCell(self: *Parser) Error!Ast.LibCell {
    const first = try self.expectIdent();
    if (!self.eat(.dot)) return .{ .cell = first };
    return .{ .lib = first, .cell = try self.expectIdent() };
}

/// Parses one A.1.5 `config_rule_statement`. The five alternatives are
/// three left clauses over two right ones; `default` pairs with `liblist`
/// alone:
///
///     default_clause ::= default
///     inst_clause ::= instance inst_name
///     inst_name ::= topmodule_identifier { . instance_identifier }
///     cell_clause ::= cell [ library_identifier . ] cell_identifier
///     liblist_clause ::= liblist { library_identifier }
///     use_clause ::= use [ library_identifier . ] cell_identifier [ : config ]
fn parseConfigRule(self: *Parser) Error!Ast.ConfigRule {
    const tok = self.pos;
    // `default` is the one A.1.5 word with a tag, shared with A.6.7's
    // `case` default.
    const is_default = self.peek() == .kw_default;
    const is_instance = self.reservedIs(tok, "instance");
    if (!is_default and !is_instance and !self.reservedIs(tok, "cell"))
        return self.failAt(tok, .E0207, "found {s}, which begins no A.1.5 config_rule_statement", .{self.found(tok)});
    self.pos += 1;
    var rule: Ast.ConfigRule = .{ .select = .default, .expand = .{ .liblist = &.{} }, .main_tok = tok };
    if (is_instance) rule.select = .{ .instance = try parse_decl.parseDottedName(self, false) } else if (!is_default) rule.select = .{ .cell = try parseLibCell(self) };
    if (self.reservedIs(self.pos, "liblist")) {
        // IEEE 1364-2005 §13.3.1.4: "It is an error if a library name is
        // included in a cell selection clause and the corresponding expansion
        // clause is a library list expansion clause."
        if (rule.select == .cell and rule.select.cell.lib != .none)
            return self.failAt(tok, .E0243, "a cell clause with a library name takes `use`, not `liblist` (IEEE 1364-2005 §13.3.1.4)", .{});
        self.pos += 1;
        // `liblist { library_identifier }`: no commas, and the empty list
        // is legal (it clears an inherited list).
        var libs: std.ArrayList(Ast.StrId) = .empty;
        while (self.peek() != .semicolon) try libs.append(self.arena, try self.expectIdent());
        rule.expand = .{ .liblist = libs.items };
    } else if (!is_default and self.reservedIs(self.pos, "use")) {
        self.pos += 1;
        var target = try parseLibCell(self);
        // `[ : config ]`: the literal keyword, not a name.
        if (self.eat(.colon)) {
            if (!self.reservedIs(self.pos, "config"))
                return self.failAt(self.pos, .E0207, "found {s}: a use_clause's `:` is followed by the word `config`", .{self.found(self.pos)});
            self.pos += 1;
            target.config = true;
        }
        rule.expand = .{ .use = target };
    } else return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a {s} pairs with `liblist`{s}",
        .{ self.found(self.pos), self.tokenText(tok), if (is_default) "" else " or `use`" },
    );
    _ = try self.expect(.semicolon);
    return rule;
}

// -----------------------------------------------------------------------
// A.5 user-defined primitives: LRM §1.1, §8.5.3
// -----------------------------------------------------------------------

/// Parses one A.5.1 `udp_declaration`, either arm:
///
///     { attribute_instance } primitive udp_identifier ( udp_port_list ) ;
///         udp_port_declaration { udp_port_declaration }
///         udp_body
///     endprimitive
///     | { attribute_instance } primitive udp_identifier
///         ( udp_declaration_port_list ) ; udp_body endprimitive
///
/// The arms differ only in whether the header holds bare names (A.5.2
/// `udp_port_list`) or declarations (`udp_declaration_port_list`), so one
/// routine reads both: the port list takes a declaration keyword where it
/// finds one, and the `udp_port_declaration` run after the `;` may be empty.
///
/// The table comes back already checked against A.5.3's alphabets, body
/// kind and column count. The digital engine evaluates it; an analog
/// compile warns W0252 at each instance (`parseUdpInst`).
pub fn parseUdpDecl(self: *Parser) Error!Ast.UdpDecl {
    const main_tok = self.pos;
    self.pos += 1; // `primitive`
    const name = try self.expectIdent();
    _ = try self.expect(.lparen);
    // A.5.2 puts the output port first in both header arms, so
    // `ports[0]` is the output and `ports[1..]` the inputs.
    var ports: std.ArrayList(Ast.StrId) = .empty;
    var outputs: u8 = 0;
    var output: Ast.StrId = .none;
    var has_reg = false;
    var dir: ?token.Tag = null;
    // A.5.3 `udp_initial_statement ::= initial output_port_identifier =
    // init_val ;`, or A.5.2's `output reg port_identifier = constant_expression`.
    var init_val: Ast.ExprId = .none;
    var init_target: Ast.StrId = .none;
    while (true) {
        try self.skipAttributes();
        // A.5.2's `udp_output_declaration` / `udp_input_declaration`, which
        // only the second A.5.1 arm puts inside the parentheses.
        if (self.peek() == .kw_output or self.peek() == .kw_input) {
            dir = self.peek();
            self.pos += 1;
            _ = try parse_module.optDiscipline(self);
            if (self.eat(.kw_reg)) has_reg = true;
        }
        const port = try self.expectIdent();
        try ports.append(self.arena, port);
        if (dir == .kw_output) {
            outputs +|= 1;
            output = port;
        }
        // `udp_output_declaration ::= … output [ discipline_identifier ]
        // reg port_identifier [ = constant_expression ]`
        if (self.eat(.assign_eq)) {
            init_val = try parse_expr.parseExpr(self);
            init_target = port;
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    if (ports.items.len - 1 > max_udp_inputs)
        return self.failAt(main_tok, .E1017, "`{s}` has {d} inputs", .{ self.file.str(name), ports.items.len - 1 });
    // A.5.2's separate declarations, the first arm's. A.5.1 requires one or
    // more, but the second arm has none, so the count is not checked.
    while (true) {
        try self.skipAttributes();
        if (self.peek() != .kw_output and self.peek() != .kw_input and self.peek() != .kw_reg) break;
        const kw = self.peek();
        self.pos += 1;
        _ = try parse_module.optDiscipline(self);
        if (kw == .kw_reg or self.eat(.kw_reg)) has_reg = true;
        while (true) {
            const port = try self.expectIdent();
            if (kw == .kw_output) {
                outputs +|= 1;
                output = port;
            }
            if (self.eat(.assign_eq)) {
                init_val = try parse_expr.parseExpr(self);
                init_target = port;
            }
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }
    // A.5.3 `sequential_body ::= [ udp_initial_statement ] table …`.
    if (self.eat(.kw_initial)) {
        init_target = try self.expectIdent();
        _ = try self.expect(.assign_eq);
        init_val = try parse_expr.parseExpr(self);
        _ = try self.expect(.semicolon);
    }
    var rows: std.ArrayList(Ast.UdpRow) = .empty;
    const sequential = try parseUdpTable(self, &rows);
    if (!self.reservedIs(self.pos, "endprimitive"))
        return self.failAt(self.pos, .E0207, "found {s}: no `endprimitive` closes the declaration", .{self.found(self.pos)});
    self.pos += 1;
    return .{
        .name = name,
        .ports = ports.items,
        .is_sequential = sequential,
        .init = init_val,
        .init_target = init_target,
        .outputs = outputs,
        .output = output,
        .has_reg = has_reg,
        .rows = rows.items,
        .main_tok = main_tok,
    };
}

/// Parses A.5.3's `table … endtable`, appending each entry to `rows`, and
/// returns whether the table is sequential (`Ast.UdpDecl.is_sequential`):
///
///     combinational_entry ::= level_input_list : output_symbol ;
///     sequential_entry ::= seq_input_list : current_state : next_state ;
///     level_symbol ::= 0 | 1 | x | X | ? | b | B
///     edge_symbol ::= r | R | f | F | p | P | n | N | *
///     output_symbol ::= 0 | 1 | x | X
///     next_state ::= output_symbol | -
///
/// The symbols are characters, not tokens: `(01)` is four symbols in three
/// tokens, `0 0` two symbols in two tokens, `b` a symbol lexed as an
/// identifier. So an entry is collected as the characters of its tokens and
/// judged against the alphabets; token boundaries inside a table mean
/// nothing. An empty table reads combinational (A.5.3 requires an entry in
/// both alternatives, so either answer is arbitrary).
pub fn parseUdpTable(self: *Parser, rows: *std.ArrayList(Ast.UdpRow)) Error!bool {
    if (!self.reservedIs(self.pos, "table"))
        return self.failAt(self.pos, .E0207, "found {s}: a udp_body is a `table … endtable`", .{self.found(self.pos)});
    self.pos += 1;
    // The first entry decides the `udp_body` alternative and every other
    // entry must match (A.5.3 gives a table one body, not a mixture).
    var sequential: ?bool = null;
    while (!self.reservedIs(self.pos, "endtable")) {
        if (self.peek() == .eof)
            return self.failAt(self.pos, .E0207, "found {s}: no `endtable` closes the table", .{self.found(self.pos)});
        try parseUdpEntry(self, &sequential, rows);
    }
    self.pos += 1;
    return sequential orelse false;
}

/// E1017's bound: IEEE 1364-2005 §8.1.2 requires at least 9 sequential and
/// 10 combinational inputs and lets a tool cap the count.
pub const max_udp_inputs = 64;

/// Parses one `combinational_entry` or `sequential_entry`, checks it column
/// by column (E0233 bad symbol, E0234 wrong shape) and appends it to `rows`.
/// `sequential` is null before the table's first entry, which sets it; each
/// later entry must agree. A column holds `max_udp_inputs` symbols, one of
/// them at most an edge `(vw)` of four characters.
pub fn parseUdpEntry(self: *Parser, sequential: *?bool, rows: *std.ArrayList(Ast.UdpRow)) Error!void {
    const tok = self.pos;
    // Column 0 is the input list; a colon opens each of the 1 or 2 that
    // follow, so the colon count is the entry's `udp_body` alternative.
    var cols: [3]struct { text: [max_udp_inputs + 3]u8 = undefined, len: usize = 0, tok: u32 = 0 } = .{ .{}, .{}, .{} };
    var n: usize = 0;
    cols[0].tok = tok;
    while (!self.eat(.semicolon)) {
        if (self.peek() == .eof or self.reservedIs(self.pos, "endtable"))
            return self.failAt(self.pos, .E0207, "found {s}: a UDP table entry ends with `;`", .{self.found(self.pos)});
        if (self.eat(.colon)) {
            n += 1;
            if (n > 2) return self.failAt(tok, .E0234, "a UDP table entry has one colon (combinational) or two (sequential), not {d}", .{n});
            cols[n].tok = self.pos;
            continue;
        }
        const t = self.tokenText(self.pos);
        if (cols[n].len + t.len > cols[n].text.len)
            return self.failAt(self.pos, .E0234, "a UDP table entry of more than {d} input symbols", .{max_udp_inputs});
        @memcpy(cols[n].text[cols[n].len..][0..t.len], t);
        cols[n].len += t.len;
        self.pos += 1;
    }
    if (n == 0) return self.failAt(tok, .E0234, "a UDP table entry has one colon (combinational) or two (sequential), not 0", .{});
    const is_seq = n == 2;
    if (sequential.*) |was| {
        if (was != is_seq) return self.failAt(
            tok,
            .E0234,
            "this entry is {s} and the table's first entry is {s}; A.5.3 gives a table ONE udp_body",
            .{ udpBodyName(is_seq), udpBodyName(was) },
        );
    } else sequential.* = is_seq;

    // `level_input_list` in a combinational body; `seq_input_list`, which
    // adds `edge_input_list`, in a sequential one.
    const inputs = cols[0].text[0..cols[0].len];
    var edge_count: usize = 0;
    for (inputs) |c| {
        if (std.mem.indexOfScalar(u8, "01xX?bB", c) != null) continue;
        if (std.mem.indexOfScalar(u8, "rRfFpPnN*()", c) != null) {
            if (is_seq) {
                // IEEE 1364-2005 8.1.4/8.4: at most one input
                // transition per row. A parenthesized pair counts once,
                // at its opening; its two level symbols are not edges.
                if (c != ')') edge_count += 1;
                if (edge_count > 1)
                    return self.failAt(cols[0].tok, .E0234, "a sequential UDP table entry permits at most one input transition descriptor", .{});
                continue;
            }
            return self.failAt(cols[0].tok, .E0234, "an edge indicator `{c}` in a combinational UDP table entry: A.5.3 reaches `edge_input_list` only from a sequential_entry", .{c});
        }
        return self.failAt(cols[0].tok, .E0233, "`{c}` is not a UDP input symbol", .{c});
    }
    // `output_symbol ::= 0 | 1 | x | X` closes a combinational entry;
    // `current_state ::= level_symbol` and `next_state ::= output_symbol
    // | -` close a sequential one.
    if (is_seq) for (cols[1].text[0..cols[1].len]) |c| {
        if (std.mem.indexOfScalar(u8, "01xX?bB", c) == null)
            return self.failAt(cols[1].tok, .E0233, "`{c}` is not a UDP current_state symbol", .{c});
    };
    const last = cols[n].text[0..cols[n].len];
    if (last.len != 1) return self.failAt(cols[n].tok, .E0233, "a UDP output symbol is one character, not {d}", .{last.len});
    const ok = std.mem.indexOfScalar(u8, "01xX", last[0]) != null or (is_seq and last[0] == '-');
    if (!ok) return self.failAt(cols[n].tok, .E0233, "`{c}` is not a UDP output symbol", .{last[0]});

    // The columns live in a stack buffer, so `inputs` is copied out. Only
    // the input list needs it: the other two columns are one character.
    try rows.append(self.arena, .{
        .inputs = try self.arena.dupe(u8, inputs),
        // A.5.3 `current_state ::= level_symbol` is one symbol, which
        // nothing above enforces; a longer column stores its first
        // character.
        .state = if (is_seq and cols[1].len != 0) cols[1].text[0] else 0,
        .output = last[0],
    });
}

fn udpBodyName(sequential: bool) []const u8 {
    return if (sequential) "sequential" else "combinational";
}

/// Parses one A.5.4 `udp_instantiation` at module scope, appending its
/// instances to `b.instances` in a digital parse only:
///
///     udp_instantiation ::= udp_identifier [ drive_strength ] [ delay2 ]
///             udp_instance { , udp_instance } ;
///     udp_instance ::= [ name_of_udp_instance ]
///             ( output_terminal , input_terminal { , input_terminal } )
///
/// The caller dispatches here on an identifier followed by `(`, or by a
/// `#` delay that is not `#(`: A.4.1 makes a module instance's name
/// mandatory, so no module instantiation looks like that. A named UDP
/// instance parses as a module instantiation and elaboration resolves the
/// name.
///
/// An analog compile warns W0252, as for a gate: the table computes a logic
/// value for an event queue a compiled analog device does not have.
pub fn parseUdpInst(self: *Parser, b: *parse_module.Body) Error!void {
    try parse_inst.gateNotModelled(self);
    const module = try self.internTok(self.pos);
    self.pos += 1; // the udp_identifier
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_decl.strengthWord(self, self.pos + 1) != null) try parse_decl.parseDriveStrength(self, &s0, &s1);
    // A.2.2.3 `delay2` is a `delay3` that stops at two values.
    const delay_tok = self.pos;
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_decl.parseDelay3(self) else .{};
    // `parseDelay3` copies a lone value into `off`; only a written third one differs.
    if (delay.off != .none and delay.off != delay.rise) try self.report(delay_tok, .E0239, "`{s} #(…)`: 3 values", .{self.file.str(module)});
    while (true) {
        const tok = self.pos;
        var name: Ast.StrId = .none;
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            name = try self.internTok(self.pos);
            self.pos += 1;
            // `name_of_udp_instance ::= udp_instance_identifier [ range ]`
            range = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        var ports: std.ArrayList(Ast.PortConn) = .empty;
        const out_tok = self.pos;
        try ports.append(self.arena, .{ .expr = try parse_expr.parseNetRef(self), .main_tok = out_tok }); // A.3.3 output_terminal ::= net_lvalue
        while (self.eat(.comma)) {
            const in_tok = self.pos;
            try ports.append(self.arena, .{ .expr = try parse_expr.parseExpr(self), .main_tok = in_tok }); // input_terminal ::= expression
        }
        _ = try self.expect(.rparen);
        // The digital engine runs a UDP instance (IEEE 1364-2005 §8); an
        // analog compile keeps nothing (W0252 above).
        if (self.digital) try b.instances.append(self.arena, .{
            .module = module,
            .name = name,
            .range = range,
            .ports = ports.items,
            .delay = delay,
            .strength0 = s0,
            .strength1 = s1,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
