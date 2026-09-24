//! Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations, A.5 UDPs.
//!
//! In: the token stream at file scope. Out: the top-level `Ast` items: module, nature,
//! discipline, connectrules, paramset, library, config and primitive declarations.
//!
//! LRM clauses this file's code cites: §1, §1.1, §2.2, §6.2, §6.4, §7.6, §7.7, §8.5.3.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_source.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_module = @import("module.zig");
const parse_specify = @import("specify.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;
const found = Parser.found;

// -----------------------------------------------------------------------
// A.1.2 source_text
// -----------------------------------------------------------------------

/// Top of grammar. LRM annex A source_text.
pub fn parseSourceFile(self: *Parser) Error!Ast.SourceFile {
    try self.access_names.put(self.arena, "V", {});
    try self.access_names.put(self.arena, "I", {});

    // Seeded (`initSeeded`) these already hold the prefix's declarations, in
    // source order; unseeded all six are empty and this is six no-ops.
    var modules: std.ArrayList(Ast.ModuleDecl) = .empty;
    var disciplines: std.ArrayList(Ast.DisciplineDecl) = .empty;
    var natures: std.ArrayList(Ast.NatureDecl) = .empty;
    var paramsets: std.ArrayList(Ast.ParamsetDecl) = .empty;
    var connectrules: std.ArrayList(Ast.ConnectRulesDecl) = .empty;
    var udps: std.ArrayList(Ast.UdpDecl) = .empty;
    var config_cells: std.ArrayList(Ast.StrId) = .empty;
    try modules.appendSlice(self.arena, self.file.modules);
    try disciplines.appendSlice(self.arena, self.file.disciplines);
    try natures.appendSlice(self.arena, self.file.natures);
    try paramsets.appendSlice(self.arena, self.file.paramsets);
    try connectrules.appendSlice(self.arena, self.file.connectrules);
    try udps.appendSlice(self.arena, self.file.udps);
    try config_cells.appendSlice(self.arena, self.file.config_cells);

    while (true) {
        try self.skipAttributes();
        const before = self.pos;
        switch (self.peek()) {
            .eof => break,
            // §10.6: legal ONLY here — "outside of a design element".
            .dir_begin_keywords, .dir_end_keywords => keywordsDirective(self) catch |e| {
                if (e == error.OutOfMemory) return e;
                recoverTopLevel(self, before);
            },
            // IEEE 1364 §19.6: between design elements is where `resetall
            // belongs; the preprocessor has already applied it.
            .dir_resetall => self.pos += 1,
            // A.1.2 `module_keyword ::= module | macromodule`. §6.2: "The
            // keyword macromodule can be used interchangeably with the
            // keyword module TO DEFINE A MODULE. An implementation may
            // choose to treat module definitions beginning with the
            // macromodule keyword differently." The second sentence is a
            // licence to optimize, not to refuse — the first has already
            // made the keyword a way of defining a module. VerA takes the
            // "no differently" option, so the two spellings are one arm and
            // nothing downstream can tell them apart.
            // …and `connectmodule`, the third alternative of the same
            // production (§7.6, Syntax 7-4). It is a module_declaration in
            // every respect the grammar states — same header, same items,
            // same `endmodule` — so it is the same arm, and the ONE thing
            // that distinguishes it is recorded on the decl rather than
            // here: see `Ast.ModuleDecl.is_connect`.
            .kw_module, .kw_macromodule, .kw_connectmodule => {
                const m = parse_module.parseModule(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                    continue;
                };
                try modules.append(self.arena, m);
            },
            .kw_discipline => {
                const d = parse_decl.parseDiscipline(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                    continue;
                };
                try disciplines.append(self.arena, d);
            },
            .kw_nature => {
                const n = parse_decl.parseNature(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                    continue;
                };
                try natures.append(self.arena, n);
            },
            // §6.4 / Syntax 6-4 `paramset`, A.1.9 paramset_declaration.
            // Parsed for real now: §6.4 makes a paramset instantiable
            // "exactly like a module", so its parameters and its
            // `.name = expr;` statements are what an instance that names it
            // elaborates to (`ir/elaborate.zig`).
            .kw_paramset => {
                const ps = parse_module.parseParamset(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                    continue;
                };
                try paramsets.append(self.arena, ps);
            },
            // §7.7 / A.1.8 connectrules_declaration, the last A.1.2
            // description alternative VerA parses. Its content is consumed
            // by annex F.2 discipline resolution (`ir/elaborate.zig`);
            // refusing it here was refusing the one design element step
            // 4.b's third bullet reads.
            .kw_connectrules => {
                const cr = parse_module.parseConnectRules(self) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                    continue;
                };
                try connectrules.append(self.arena, cr);
            },
            // A.1.2's `description` has three more alternatives, and they
            // share one token tag: annex B reserves `primitive`, `config`,
            // `library` and `include` and this compiler gives none of them
            // a tag of its own, so the spelling is the dispatch. All four
            // used to be one E0201, which said "not in the supported
            // subset" about two productions A.1.2 lists (and, for
            // `library`, about a production no version of the subset can
            // ever admit — see E0232).
            .kw_reserved => {
                const w = parse_expr.tokenText(self, self.pos);
                const r: Error!void = if (std.mem.eql(u8, w, "primitive")) udp: {
                    const u = parseUdpDecl(self) catch |e| break :udp e;
                    break :udp udps.append(self.arena, u);
                } else if (std.mem.eql(u8, w, "config"))
                    parseConfigDecl(self, &config_cells)
                else if (std.mem.eql(u8, w, "library") or std.mem.eql(u8, w, "include"))
                    parseLibraryDecl(self)
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
    // directive, EVEN ACROSS SOURCE CODE FILE BOUNDARIES, until the
    // matching `end_keywords directive is encountered" — so an open stack
    // at end of file is the case that sentence exists to describe, not an
    // error. Chapter 10 states no diagnostic for it, and this used to raise
    // E0137, which inverted the clause. `end_keywords with nothing open
    // stays E0136: that one has no reading in which it means anything.
    // Pinned by tests/fixtures/ch10_directives/31_begin_keywords_unterminated.va.

    self.file.modules = modules.items;
    self.file.disciplines = disciplines.items;
    self.file.natures = natures.items;
    self.file.paramsets = paramsets.items;
    self.file.connectrules = connectrules.items;
    self.file.udps = udps.items;
    self.file.config_cells = config_cells.items;
    if (self.failed) return error.ParseError;
    return self.file;
}

/// LRM §10.6 `begin_keywords "<version_specifier>" … `end_keywords.
/// Selects which annex B words are reserved for the design elements that
/// follow (see `identLike`). The directives nest, so the previous set is
/// stacked rather than reset.
pub fn keywordsDirective(self: *Parser) Error!void {
    const tok = self.pos;
    self.pos += 1;
    if (self.tags[tok] == .dir_end_keywords) {
        self.kw_set = self.kw_stack.pop() orelse
            return self.failAt(tok, .E0136, "", .{});
        return;
    }
    const str = try self.expect(.string_literal);
    const raw = parse_expr.tokenText(self, str);
    const spec = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
    const set = token.KeywordSet.fromSpecifier(spec) orelse return self.failAt(
        str,
        .E0135,
        "`{s}`",
        .{spec},
    );
    try self.kw_stack.append(self.arena, self.kw_set);
    self.kw_set = set;
}

/// §10.6's placement rule, on the design elements `parseModuleItem` does not
/// cover: "The `begin_keywords and `end_keywords directives can only be
/// specified outside of a design element (module, primitive, configuration,
/// paramset, connectrules or connectmodule)."
///
/// Both were already refused inside a `paramset` and a `connectrules` — by
/// E0205 ("unsupported module item") and E0207 ("unexpected token"), which
/// describe a grammar that has no such production rather than the clause
/// that forbids it. One `peek` moves them onto E0202, which is the rule.
pub fn outsideDesignElement(self: *Parser, what: []const u8) Error!void {
    const t = self.peek();
    if (t != .dir_begin_keywords and t != .dir_end_keywords) return;
    return self.failAt(self.pos, .E0202, "{s} inside a {s}", .{ token.Tag.lexeme(t).?, what });
}

/// Skip to the next thing that can start a top-level description (A.1.2),
/// past any `end*` keyword that closes the construct we bailed out of.
pub fn recoverTopLevel(self: *Parser, before: u32) void {
    if (self.pos == before) self.pos += 1;
    while (true) : (self.pos += 1) switch (self.peek()) {
        .eof => return,
        // Everything `parseSource` dispatches a description on. A.1.2's
        // `macromodule`/`connectmodule` are module_keyword alternatives,
        // `paramset` starts A.1.9's declaration and `connectrules`
        // A.1.8's; leaving any of them out meant one bad description
        // swallowed every following one of that kind. (`connectmodule`
        // closes with `endmodule`, so the consume set below already
        // covers it.)
        .kw_module, .kw_macromodule, .kw_connectmodule, .kw_discipline, .kw_nature, .kw_paramset, .kw_connectrules => return,
        .kw_endmodule, .kw_enddiscipline, .kw_endnature, .kw_endparamset, .kw_endconnectrules => {
            self.pos += 1;
            return;
        },
        // A.1.2's other two descriptions close with reserved spellings this
        // compiler gives no tag to. Without them a bad `primitive` swallowed
        // the module after it.
        .kw_reserved => if (parse_module.reservedIs(self, self.pos, "endprimitive") or
            parse_module.reservedIs(self, self.pos, "endconfig"))
        {
            self.pos += 1;
            return;
        } else if (parse_module.reservedIs(self, self.pos, "primitive") or
            parse_module.reservedIs(self, self.pos, "config"))
        {
            if (self.pos != before) return;
        },
        else => {}, // else: any other token belongs to the description being skipped
    };
}

// -----------------------------------------------------------------------
// A.1.1 library source text · A.1.5 configuration — LRM §1.1
// -----------------------------------------------------------------------

/// A.1.1's two library-map-only descriptions:
///
///     library_declaration ::=
///             library library_identifier file_path_spec [ { , file_path_spec } ]
///             [ -incdir file_path_spec { , file_path_spec } ] ;
///     include_statement ::= include file_path_spec ;
///
/// READ AND THEN REFUSED (E0232), which is the point of reading them. Annex
/// A's preamble names the starting symbol each file kind derives from — "The
/// syntax of Verilog-AMS HDL source is derived from the starting symbol
/// source_text. The syntax of a library map file is derived from the
/// starting symbol library_text" — and `library_description` hangs off
/// `library_text` alone. A.1.2's `description` list does not contain either
/// of these, so this text is not derivable from what a `.va` IS.
///
/// That makes E0201 ("not in the supported subset") the wrong verdict: it
/// says a subset that could grow, and no growth of the analog subset makes
/// a library declaration legal in a source file. E0232 names the starting
/// symbol instead. The production is still walked first, so the diagnostic
/// lands on the keyword of a construct that was UNDERSTOOD.
///
/// `file_path_spec ::= file_path` is taken as a string literal only.
// ponytail: an unquoted `file_path` — `./lib/*.v`, which is how real map
// files write one — is not a token sequence this lexer can produce, and it
// should not be asked to: §2.2's token set is `source_text`'s. A library map
// file needs its own reader, which is the same work E0232 says is absent.
pub fn parseLibraryDecl(self: *Parser) Error!void {
    const kw = self.pos;
    const is_library = parse_module.reservedIs(self, kw, "library");
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
        if (!parse_module.reservedIs(self, self.pos, "incdir")) return self.failAt(self.pos, .E0207, "found {s}, and `-` begins only A.1.1's `-incdir`", .{self.found(self.pos)});
        self.pos += 1;
        while (true) {
            _ = try self.expect(.string_literal);
            if (!self.eat(.comma)) break;
        }
    }
    _ = try self.expect(.semicolon);
    return self.failAt(kw, .E0232, "`{s}` is a library_description, and this file is source_text", .{parse_expr.tokenText(self, kw)});
}

/// A.1.5 `config_declaration`, which A.1.2 lists as a `description` — so
/// unlike A.1.1's two, a configuration in a `.va` is derivable from
/// `source_text` and is accepted:
///
///     config_declaration ::=
///             config config_identifier ;
///                 design_statement
///                 {config_rule_statement}
///             endconfig
///     design_statement ::= design { [library_identifier.]cell_identifier } ;
///     config_rule_statement ::=
///             default_clause liblist_clause ;
///             | inst_clause liblist_clause ; | inst_clause use_clause ;
///             | cell_clause liblist_clause ; | cell_clause use_clause ;
///
/// ACCEPTED AND BINDING NOTHING, out loud (W0253). A configuration selects
/// which CELL of which LIBRARY an instance resolves to; VerA has no library
/// map, so every instance resolves to a module declared in the source it was
/// given, by name, and the elaborated design is what it would have been with
/// the configuration deleted.
// ponytail: nothing is recorded, for `parseSpecifyBlock`'s reason — there
// is no library table for a rule to select from, so a stored clause would
// have no consumer. The upgrade is a map reader, which E0232 also wants.
///
/// The `design` statement's cells are recorded (`SourceFile.config_cells`),
/// and a digital run takes them as its tops (§13.3.1.1); the rules still bind
/// nothing, which W0253 keeps saying whenever there are any — and always in
/// an analog compile, which reads no cell list at all.
pub fn parseConfigDecl(self: *Parser, cells: *std.ArrayList(Ast.StrId)) Error!void {
    const kw = self.pos;
    self.pos += 1;
    _ = try self.expectIdent();
    _ = try self.expect(.semicolon);
    // `design_statement` is mandatory and first — the production puts it
    // above the repetition, not inside it.
    if (!parse_module.reservedIs(self, self.pos, "design")) return self.failAt(self.pos, .E0207, "found {s}: a config_declaration begins with its `design` statement", .{self.found(self.pos)});
    self.pos += 1;
    while (self.peek() != .semicolon) {
        const cell = self.file.str(try parse_generate.parseDottedName(self, false));
        const last = if (std.mem.lastIndexOfScalar(u8, cell, '.')) |dot| cell[dot + 1 ..] else cell;
        try cells.append(self.arena, try self.file.intern(self.arena, last));
    }
    self.pos += 1;
    var rules = false;
    while (!parse_module.reservedIs(self, self.pos, "endconfig")) {
        if (self.peek() == .eof) return self.failAt(self.pos, .E0207, "found {s}: no `endconfig` closes the configuration", .{self.found(self.pos)});
        try parseConfigRule(self);
        rules = true;
    }
    self.pos += 1;
    if (!self.digital or rules) try self.bag.add(.parse, .W0253, lexer.tokenSpan(self.src, self.starts, kw), "", .{});
}

/// A.1.5 `config_rule_statement`. The five alternatives are three left
/// clauses over two right ones, and `default` is the one that pairs with
/// `liblist` alone:
///
///     default_clause ::= default
///     inst_clause ::= instance inst_name
///     inst_name ::= topmodule_identifier { . instance_identifier }
///     cell_clause ::= cell [ library_identifier . ] cell_identifier
///     liblist_clause ::= liblist { library_identifier }
///     use_clause ::= use [ library_identifier . ] cell_identifier [ : config ]
pub fn parseConfigRule(self: *Parser) Error!void {
    const tok = self.pos;
    // `default` is the one word of A.1.5 that this compiler has a tag for:
    // A.6.7's `case` default takes the same spelling, and annex B reserves
    // it once.
    const is_default = self.peek() == .kw_default;
    if (!is_default and !parse_module.reservedIs(self, tok, "instance") and !parse_module.reservedIs(self, tok, "cell"))
        return self.failAt(tok, .E0207, "found {s}, which begins no A.1.5 config_rule_statement", .{self.found(tok)});
    self.pos += 1;
    if (!is_default) _ = try parse_generate.parseDottedName(self, false);
    if (parse_module.reservedIs(self, self.pos, "liblist")) {
        self.pos += 1;
        // `liblist { library_identifier }` — a repetition with no commas,
        // and the empty one is legal (it is what clears an inherited list).
        while (self.peek() != .semicolon) _ = try self.expectIdent();
    } else if (!is_default and parse_module.reservedIs(self, self.pos, "use")) {
        self.pos += 1;
        _ = try parse_generate.parseDottedName(self, false);
        // `[ : config ]` — the literal keyword, not a name.
        if (self.eat(.colon) and !parse_module.reservedIs(self, self.pos, "config"))
            return self.failAt(self.pos, .E0207, "found {s}: a use_clause's `:` is followed by the word `config`", .{self.found(self.pos)})
        else if (parse_module.reservedIs(self, self.pos, "config")) self.pos += 1;
    } else return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a {s} pairs with `liblist`{s}",
        .{ self.found(self.pos), parse_expr.tokenText(self, tok), if (is_default) "" else " or `use`" },
    );
    _ = try self.expect(.semicolon);
}

// -----------------------------------------------------------------------
// A.5 user-defined primitives — LRM §1.1, §8.5.3
// -----------------------------------------------------------------------

/// A.5.1 `udp_declaration`, both arms:
///
///     { attribute_instance } primitive udp_identifier ( udp_port_list ) ;
///         udp_port_declaration { udp_port_declaration }
///         udp_body
///     endprimitive
///     | { attribute_instance } primitive udp_identifier
///         ( udp_declaration_port_list ) ; udp_body endprimitive
///
/// A.1.2 lists `udp_declaration` as a `description`, so a `.va` holding one
/// is derivable from `source_text` and the old E0201 was refusing text the
/// standard admits.
///
/// The two arms differ only in whether the header's parenthesis holds bare
/// names (A.5.2 `udp_port_list`) or full declarations
/// (`udp_declaration_port_list`), and both then reach the same body, so one
/// routine reads both: the port list takes a declaration keyword where it
/// finds one, and the `udp_port_declaration` run after the `;` is a
/// repetition that may be empty.
///
/// RECORDED, AND EVALUATED BY NOTHING. The declaration lands on
/// `Ast.SourceFile.udps`; there is still no discrete engine that matches a
/// table against its inputs, and `parseUdpInst`'s W0252 is what says so at
/// the site that would have used it.
///
/// It used to be dropped, on the ground that rows nothing reads are dead
/// weight in an arena. That was true while the evaluator was unreachable
/// for a different reason — a `primitive` was E0201 — and it stopped being
/// true when this routine landed: the table is A.5.3's alphabets, its
/// combinational/sequential agreement and its column count already
/// checked, and an evaluator that had to re-derive all of that from tokens
/// would be a second implementation of this clause.
pub fn parseUdpDecl(self: *Parser) Error!Ast.UdpDecl {
    const main_tok = self.pos;
    self.pos += 1; // `primitive`
    const name = try self.expectIdent();
    _ = try self.expect(.lparen);
    // A.5.2 puts the output port first in both header arms, so declaration
    // order IS `ports[0] = output, ports[1..] = inputs` with no lookup.
    var ports: std.ArrayList(Ast.StrId) = .empty;
    while (true) {
        // A.5.2's `udp_output_declaration` / `udp_input_declaration`, which
        // only the second A.5.1 arm puts inside the parentheses.
        if (self.eat(.kw_output) or self.eat(.kw_input)) {
            _ = try parse_module.optDiscipline(self);
            _ = self.eat(.kw_reg);
        }
        try ports.append(self.arena, try self.expectIdent());
        // `udp_output_declaration ::= … output [ discipline_identifier ]
        // reg port_identifier [ = constant_expression ]`
        if (self.eat(.assign_eq)) _ = try parse_expr.parseExpr(self);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    // A.5.2's separate declarations, the first arm's. A.5.1 writes the run
    // as `udp_port_declaration { udp_port_declaration }` — one or more —
    // but the second arm reaches the body with none, so the count is not
    // checked here: which arm the header took is what decides it, and a
    // primitive whose ports are never typed is A.5.2's problem and not the
    // parser's.
    while (self.peek() == .kw_output or self.peek() == .kw_input or self.peek() == .kw_reg) {
        self.pos += 1;
        _ = try parse_module.optDiscipline(self);
        _ = self.eat(.kw_reg);
        while (true) {
            _ = try self.expectIdent();
            if (self.eat(.assign_eq)) _ = try parse_expr.parseExpr(self);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }
    // A.5.3 `sequential_body ::= [ udp_initial_statement ] table …`, and
    // `udp_initial_statement ::= initial output_port_identifier = init_val ;`
    var init_val: Ast.ExprId = .none;
    if (self.eat(.kw_initial)) {
        _ = try self.expectIdent();
        _ = try self.expect(.assign_eq);
        init_val = try parse_expr.parseExpr(self);
        _ = try self.expect(.semicolon);
    }
    var rows: std.ArrayList(Ast.UdpRow) = .empty;
    const sequential = try parseUdpTable(self, &rows);
    if (!parse_module.reservedIs(self, self.pos, "endprimitive"))
        return self.failAt(self.pos, .E0207, "found {s}: no `endprimitive` closes the declaration", .{self.found(self.pos)});
    self.pos += 1;
    return .{
        .name = name,
        .ports = ports.items,
        .is_sequential = sequential,
        .init = init_val,
        .rows = rows.items,
        .main_tok = main_tok,
    };
}

/// A.5.3's `table … endtable`, and the whole of what a parser can judge in
/// one:
///
///     combinational_entry ::= level_input_list : output_symbol ;
///     sequential_entry ::= seq_input_list : current_state : next_state ;
///     level_symbol ::= 0 | 1 | x | X | ? | b | B
///     edge_symbol ::= r | R | f | F | p | P | n | N | *
///     output_symbol ::= 0 | 1 | x | X
///     next_state ::= output_symbol | -
///
/// THE SYMBOLS ARE CHARACTERS AND NOT TOKENS, which is the one thing about
/// this region that has to be got right. `(01)` is four symbols and reaches
/// the parser as three tokens; `0 0` is two symbols and two tokens; `b` is
/// a symbol and an identifier. So an entry is collected as the CHARACTERS
/// of its tokens, in order, and judged against the alphabets — the token
/// boundaries inside a table carry no meaning of their own, and a parser
/// that read them as if they did would reject half of A.5.3's own examples.
///
/// Returns which `udp_body` alternative the table was, for
/// `Ast.UdpDecl.is_sequential`. An EMPTY table reads combinational: A.5.3's
/// two alternatives both require at least one entry, so `table endtable`
/// derives from neither and the answer is arbitrary either way.
pub fn parseUdpTable(self: *Parser, rows: *std.ArrayList(Ast.UdpRow)) Error!bool {
    if (!parse_module.reservedIs(self, self.pos, "table"))
        return self.failAt(self.pos, .E0207, "found {s}: a udp_body is a `table … endtable`", .{self.found(self.pos)});
    self.pos += 1;
    // Which `udp_body` alternative this table is, decided by its FIRST
    // entry and then required of every other one (A.5.3 gives a table one
    // body and not a mixture).
    var sequential: ?bool = null;
    while (!parse_module.reservedIs(self, self.pos, "endtable")) {
        if (self.peek() == .eof)
            return self.failAt(self.pos, .E0207, "found {s}: no `endtable` closes the table", .{self.found(self.pos)});
        try parseUdpEntry(self, &sequential, rows);
    }
    self.pos += 1;
    return sequential orelse false;
}

/// One `combinational_entry` or `sequential_entry`, judged column by column
/// and then appended to `rows`.
pub fn parseUdpEntry(self: *Parser, sequential: *?bool, rows: *std.ArrayList(Ast.UdpRow)) Error!void {
    const tok = self.pos;
    // Column 0 is the input list; a colon opens each of the 1 or 2 that
    // follow, so the colon count IS the entry's `udp_body` alternative.
    var cols: [3]struct { text: [64]u8 = undefined, len: usize = 0, tok: u32 = 0 } = .{ .{}, .{}, .{} };
    var n: usize = 0;
    cols[0].tok = tok;
    while (!self.eat(.semicolon)) {
        if (self.peek() == .eof or parse_module.reservedIs(self, self.pos, "endtable"))
            return self.failAt(self.pos, .E0207, "found {s}: a UDP table entry ends with `;`", .{self.found(self.pos)});
        if (self.eat(.colon)) {
            n += 1;
            if (n > 2) return self.failAt(tok, .E0234, "a UDP table entry has one colon (combinational) or two (sequential), not {d}", .{n});
            cols[n].tok = self.pos;
            continue;
        }
        const t = parse_expr.tokenText(self, self.pos);
        if (cols[n].len + t.len > cols[n].text.len)
            return self.failAt(self.pos, .E0233, "a UDP table column of more than {d} symbols", .{cols[n].text.len});
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

    // `level_input_list` in a combinational body, `seq_input_list` — which
    // adds `edge_input_list` — in a sequential one.
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
        // A.5.3 `current_state ::= level_symbol` is one symbol, which the
        // loop above does not require and this does not either — a
        // longer column stores its first character and the row is as
        // usable as the table is legal.
        .state = if (is_seq and cols[1].len != 0) cols[1].text[0] else 0,
        .output = last[0],
    });
}

pub fn udpBodyName(sequential: bool) []const u8 {
    return if (sequential) "sequential" else "combinational";
}

/// A.5.4 `udp_instantiation`, at module scope:
///
///     udp_instantiation ::= udp_identifier [ drive_strength ] [ delay2 ]
///             udp_instance { , udp_instance } ;
///     udp_instance ::= [ name_of_udp_instance ]
///             ( output_terminal , input_terminal { , input_terminal } )
///
/// Told from A.4.1's `module_instantiation` by ONE token, with no
/// backtrack and no lookup of the name: `module_instance ::=
/// name_of_module_instance ( [ list_of_port_connections ] )` makes the
/// instance name MANDATORY, and A.5.4's is optional, so an identifier
/// followed directly by `(` derives from A.5.4 and from nothing else.
/// (A UDP instance WITH a name is indistinguishable from a module instance
/// at this point, and stays a module instantiation — elaboration resolves
/// the name, which is where the difference is knowable.)
///
/// W0252 for the same reason a gate gets one: a UDP's function is a table
/// (A.5.3) rather than a keyword, and the table computes a logic value for
/// an event queue a compiled analog device does not have.
pub fn parseUdpInst(self: *Parser, b: *parse_module.Body) Error!void {
    try parse_specify.gateNotModelled(self);
    const module = try self.internTok(self.pos);
    self.pos += 1; // the udp_identifier
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_generate.strengthWord(self, self.pos + 1) != null) try parse_generate.parseDriveStrength(self, &s0, &s1);
    // A.2.2.3 `delay2` — a `delay3` that stops at two values, which
    // `parseDelay3` already returns for a two-value list.
    const delay_tok = self.pos;
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_generate.parseDelay3(self) else .{};
    if (delay.off != .none) try self.report(delay_tok, .E0239, "`{s} #(…)`: 3 values", .{self.file.str(module)});
    while (true) {
        const tok = self.pos;
        var name: Ast.StrId = .none;
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            name = try self.internTok(self.pos);
            self.pos += 1;
            // `name_of_udp_instance ::= udp_instance_identifier [ range ]`
            if (self.peek() == .lbracket) range = try parse_decl.parseDim(self);
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
        // analog compile keeps nothing, as the W0252 above says.
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
