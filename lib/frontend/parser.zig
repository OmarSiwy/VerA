//! Class 2 — Parsing. LRM annex A (normative grammar), ch3 declaration syntax,
//! §4.2.2 operator precedence, §6.8 scope rules.
//!
//! Transformation: token stream → ast.SourceFile (SoA stores).
//!
//! DOD: append nodes into the SoA ExprStore / statement pool and return u32
//! handles (ExprId/StmtId). Recursive-descent + precedence climbing for exprs.
//! No pointer tree is ever built.
//!
//! Ownership: everything (AST stores, decl slices) is allocated from `arena`
//! and freed by `arena.deinit()`. `src`, `tags` and `starts` are BORROWED and
//! must outlive the produced `Ast.SourceFile` — every interned name is a
//! substring of `src`.
//!
//! Diagnostics: errors are COLLECTED into the shared `diag.Bag`, not thrown.
//! `error.ParseError` is the internal unwind signal to the nearest recovery
//! point (module item / statement / top-level declaration); each recovery point
//! resynchronizes on `;` or a closing keyword and keeps parsing.
//! `parseSourceFile` returns `error.ParseError` at the end iff anything was
//! reported — the AST is then partial and MUST NOT be lowered.
//!
//! Token text: `token.Stored` carries only {tag,start} (end is recomputed, not
//! stored), so this file re-scans identifier/number/string lexemes from `start`.
//! It has to anyway: literal *values* (§2.6 bases, SI scale factors) are the
//! parser's job.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const diag = @import("diag");

pub const Error = error{ OutOfMemory, ParseError };

pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tags: []const token.Tag,
    starts: []const u32,
    pos: u32 = 0,
    file: Ast.SourceFile = .empty,
    /// Shared collector. The cap, the dedupe and the rendering all live there.
    bag: *diag.Bag,
    /// Did THIS parse report anything? The bag is shared across stages and
    /// drops entries to the cap and the dedupe set, so its length cannot answer.
    failed: bool = false,
    /// §3.6.1.4 nature `access` names. `name(...)` is a branch probe (§4.4.1)
    /// iff the name is in here, otherwise it is a user function call (§4.7).
    /// Seeded with V/I (disciplines.vams, annex D) and grown by every
    /// `access = X;` nature attribute parsed ahead of the module.
    access_names: std.StringHashMapUnmanaged(void) = .empty,
    /// §10.6 reserved-keyword set in effect, and the open `begin_keywords
    /// directives it was pushed by. See `keywordsDirective` / `identLike`.
    kw_set: token.KeywordSet = token.default_keyword_set,
    kw_stack: std.ArrayList(token.KeywordSet) = .empty,
    /// Inside an `analog function` body (§4.7.1). Two of that clause's bullets
    /// are restrictions on statements the ordinary statement parser also parses
    /// for module scope, so the position is the only thing that tells them
    /// apart. See `parseFuncDecl`, E0226 and E0227.
    in_analog_fn: bool = false,
    /// Opt-in shared grammar for the digital source executor.
    digital: bool = false,
    /// Inside a §7.6 `connectmodule` body. Two things read it: `parseDiscrete`,
    /// because a connect module is the one design element whose body has the
    /// discrete context LEGALLY (§7.2.2), so E0205 must not fire there; and
    /// `parseEventTerm`, because A.6.5's `driver_update` is a digital event and
    /// §9.22 paragraph 3 puts the whole driver family inside a connect module.
    in_connect_module: bool = false,
    /// §6.6 nesting depth of generate REGIONS and generate CONSTRUCT bodies,
    /// counted together because the two grammar gates it feeds care about the
    /// same thing — being anywhere below a `generate`. Syntax 6-8's
    /// `module_or_generate_item` has neither `generate_region` (§6.6: "Generate
    /// regions do not nest, and they may only occur directly within a module")
    /// nor `parameter_declaration` (§6.6: a generate block "may not contain
    /// port declarations, parameter declarations, specify blocks, or specparam
    /// declarations"), so `> 0` refuses both: E0228 and E0229.
    gen_depth: u32 = 0,
    /// How many generate CONSTRUCTS (loop/if/case, not regions) enclose the
    /// cursor, and an identity for the outermost one. Together they are the
    /// §6.6.2 name space key — see `checkGenBlockNames`.
    gen_construct_depth: u32 = 0,
    gen_construct: u32 = 0,
    /// §2.9 every `attr_spec` of the module being parsed, flattened. Moved into
    /// the `ModuleDecl` at `endmodule` and cleared — see `parseAttributes`.
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,
    /// Are we inside an attribute VALUE? §2.9's nesting ban is the only rule
    /// that needs to know.
    attr_depth: u32 = 0,

    pub fn init(
        arena: std.mem.Allocator,
        src: []const u8,
        tags: []const token.Tag,
        starts: []const u32,
        bag: *diag.Bag,
    ) Parser {
        std.debug.assert(tags.len == starts.len);
        std.debug.assert(tags.len > 0 and tags[tags.len - 1] == .eof);
        return .{
            .arena = arena,
            .src = src,
            .tags = tags,
            .starts = starts,
            .bag = bag,
        };
    }

    /// Everything a parse of a leading run of tokens leaves behind, so a later
    /// parse of a longer token stream that BEGINS WITH THAT RUN can resume from
    /// it instead of redoing it. Built once per process for the annex D/E
    /// prelude — see `Preprocessor.preludeAst`, which owns the snapshot, states
    /// why the prelude is always that leading run, and asserts that the fields
    /// NOT listed here are all still at their `init` values when the prefix
    /// parse ends (`kw_set`, `kw_stack`, `attrs`, the three flags and the two
    /// depths: a design element that opened one has closed it by `endmodule`).
    ///
    /// A field added to `Parser` that a prefix parse can leave dirty is a field
    /// that must be added here too; the equivalence test at the bottom of
    /// `preprocessor.zig` is what catches the omission.
    pub const Seed = struct {
        /// Stores and decl lists. See `Ast.SourceFile.seedFrom` for which half
        /// is copied and which is borrowed, and why the borrow is sound.
        file: Ast.SourceFile,
        /// §3.6.1.4 access names in effect at the seam. A list rather than the
        /// map itself: the set is 16 names, and re-`put`ting 16 keys is cheaper
        /// than cloning a hash map (MEASURED: cloning the 154-entry interner
        /// map is 3.4 µs, i.e. ~22 ns/entry, ReleaseFast, min of 500).
        access_names: []const []const u8,
        /// Token index the prefix parse stopped on — its `.eof`, which is the
        /// first token of the resumed parse.
        pos: u32,
        /// §6.6.2 outermost-construct identity, monotonic over the whole file.
        gen_construct: u32,
    };

    /// `init`, then resume from `seed` instead of from nothing. `null` seed is
    /// exactly `init` (the `--no-std-defs` path, and every direct caller in the
    /// tests).
    pub fn initSeeded(
        arena: std.mem.Allocator,
        src: []const u8,
        tags: []const token.Tag,
        starts: []const u32,
        bag: *diag.Bag,
        seed: ?*const Seed,
    ) std.mem.Allocator.Error!Parser {
        var p = init(arena, src, tags, starts, bag);
        const s = seed orelse return p;
        // The caller promises `tags` begins with the run `s` was parsed from —
        // `root.zig` gets that from the same `Prelude` that seeded the lexer.
        std.debug.assert(s.pos < tags.len);
        p.pos = s.pos;
        p.gen_construct = s.gen_construct;
        try p.file.seedFrom(arena, &s.file);
        for (s.access_names) |n| try p.access_names.put(arena, n, {});
        return p;
    }

    // -----------------------------------------------------------------------
    // A.1.2 source_text
    // -----------------------------------------------------------------------

    /// Top of grammar. LRM annex A source_text.
    pub fn parseSourceFile(self: *Parser) Error!Ast.SourceFile {
        try self.access_names.put(self.arena, "V", {});
        try self.access_names.put(self.arena, "I", {});

        // Seeded (`initSeeded`) these already hold the prefix's declarations, in
        // source order; unseeded all five are empty and this is five no-ops.
        var modules: std.ArrayList(Ast.ModuleDecl) = .empty;
        var disciplines: std.ArrayList(Ast.DisciplineDecl) = .empty;
        var natures: std.ArrayList(Ast.NatureDecl) = .empty;
        var paramsets: std.ArrayList(Ast.ParamsetDecl) = .empty;
        var connectrules: std.ArrayList(Ast.ConnectRulesDecl) = .empty;
        try modules.appendSlice(self.arena, self.file.modules);
        try disciplines.appendSlice(self.arena, self.file.disciplines);
        try natures.appendSlice(self.arena, self.file.natures);
        try paramsets.appendSlice(self.arena, self.file.paramsets);
        try connectrules.appendSlice(self.arena, self.file.connectrules);

        while (true) {
            try self.skipAttributes();
            const before = self.pos;
            switch (self.peek()) {
                .eof => break,
                // §10.6: legal ONLY here — "outside of a design element".
                .dir_begin_keywords, .dir_end_keywords => self.keywordsDirective() catch |e| {
                    if (e == error.OutOfMemory) return e;
                    self.recoverTopLevel(before);
                },
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
                    const m = self.parseModule() catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
                        continue;
                    };
                    try modules.append(self.arena, m);
                },
                .kw_discipline => {
                    const d = self.parseDiscipline() catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
                        continue;
                    };
                    try disciplines.append(self.arena, d);
                },
                .kw_nature => {
                    const n = self.parseNature() catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
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
                    const ps = self.parseParamset() catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
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
                    const cr = self.parseConnectRules() catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
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
                    const w = self.tokenText(self.pos);
                    const r: Error!void = if (std.mem.eql(u8, w, "primitive"))
                        self.parseUdpDecl()
                    else if (std.mem.eql(u8, w, "config"))
                        self.parseConfigDecl()
                    else if (std.mem.eql(u8, w, "library") or std.mem.eql(u8, w, "include"))
                        self.parseLibraryDecl()
                    else
                        self.failAt(self.pos, .E0201, "`{s}`", .{self.found(self.pos)});
                    r catch |e| {
                        if (e == error.OutOfMemory) return e;
                        self.recoverTopLevel(before);
                    };
                },
                else => {
                    _ = self.failAt(self.pos, .E0201, "`{s}`", .{self.found(self.pos)}) catch {};
                    self.recoverTopLevel(before);
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
        if (self.failed) return error.ParseError;
        return self.file;
    }

    /// LRM §10.6 `begin_keywords "<version_specifier>" … `end_keywords.
    /// Selects which annex B words are reserved for the design elements that
    /// follow (see `identLike`). The directives nest, so the previous set is
    /// stacked rather than reset.
    fn keywordsDirective(self: *Parser) Error!void {
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
    fn outsideDesignElement(self: *Parser, what: []const u8) Error!void {
        const t = self.peek();
        if (t != .dir_begin_keywords and t != .dir_end_keywords) return;
        return self.failAt(self.pos, .E0202, "{s} inside a {s}", .{ token.Tag.lexeme(t).?, what });
    }

    /// Skip to the next thing that can start a top-level description (A.1.2),
    /// past any `end*` keyword that closes the construct we bailed out of.
    fn recoverTopLevel(self: *Parser, before: u32) void {
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
            else => {},
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
    fn parseLibraryDecl(self: *Parser) Error!void {
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
    fn parseConfigDecl(self: *Parser) Error!void {
        const kw = self.pos;
        self.pos += 1;
        _ = try self.expectIdent();
        _ = try self.expect(.semicolon);
        // `design_statement` is mandatory and first — the production puts it
        // above the repetition, not inside it.
        if (!self.reservedIs(self.pos, "design")) return self.failAt(self.pos, .E0207, "found {s}: a config_declaration begins with its `design` statement", .{self.found(self.pos)});
        self.pos += 1;
        while (self.peek() != .semicolon) _ = try self.parseDottedName(false);
        self.pos += 1;
        while (!self.reservedIs(self.pos, "endconfig")) {
            if (self.peek() == .eof) return self.failAt(self.pos, .E0207, "found {s}: no `endconfig` closes the configuration", .{self.found(self.pos)});
            try self.parseConfigRule();
        }
        self.pos += 1;
        try self.bag.add(.parse, .W0253, lexer.tokenSpan(self.src, self.starts, kw), "", .{});
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
    fn parseConfigRule(self: *Parser) Error!void {
        const tok = self.pos;
        // `default` is the one word of A.1.5 that this compiler has a tag for:
        // A.6.7's `case` default takes the same spelling, and annex B reserves
        // it once.
        const is_default = self.peek() == .kw_default;
        if (!is_default and !self.reservedIs(tok, "instance") and !self.reservedIs(tok, "cell"))
            return self.failAt(tok, .E0207, "found {s}, which begins no A.1.5 config_rule_statement", .{self.found(tok)});
        self.pos += 1;
        if (!is_default) _ = try self.parseDottedName(false);
        if (self.reservedIs(self.pos, "liblist")) {
            self.pos += 1;
            // `liblist { library_identifier }` — a repetition with no commas,
            // and the empty one is legal (it is what clears an inherited list).
            while (self.peek() != .semicolon) _ = try self.expectIdent();
        } else if (!is_default and self.reservedIs(self.pos, "use")) {
            self.pos += 1;
            _ = try self.parseDottedName(false);
            // `[ : config ]` — the literal keyword, not a name.
            if (self.eat(.colon) and !self.reservedIs(self.pos, "config"))
                return self.failAt(self.pos, .E0207, "found {s}: a use_clause's `:` is followed by the word `config`", .{self.found(self.pos)})
            else if (self.reservedIs(self.pos, "config")) self.pos += 1;
        } else return self.failAt(
            self.pos,
            .E0207,
            "found {s}: a {s} pairs with `liblist`{s}",
            .{ self.found(self.pos), self.tokenText(tok), if (is_default) "" else " or `use`" },
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
    /// NOTHING IS RECORDED. The table is validated against A.5.3 and dropped —
    /// there is no discrete engine here to evaluate it, and `parseUdpInst`'s
    /// W0252 is what says so at the site that would have used it.
    // ponytail: the upgrade is a `UdpDecl` on `Ast.SourceFile` plus a matcher
    // in `src/sim/digital.zig`, which is another agent's column. Storing the
    // rows before that exists is dead weight in an arena.
    fn parseUdpDecl(self: *Parser) Error!void {
        self.pos += 1; // `primitive`
        _ = try self.expectIdent();
        _ = try self.expect(.lparen);
        while (true) {
            // A.5.2's `udp_output_declaration` / `udp_input_declaration`, which
            // only the second A.5.1 arm puts inside the parentheses.
            if (self.eat(.kw_output) or self.eat(.kw_input)) {
                _ = try self.optDiscipline();
                _ = self.eat(.kw_reg);
            }
            _ = try self.expectIdent();
            // `udp_output_declaration ::= … output [ discipline_identifier ]
            // reg port_identifier [ = constant_expression ]`
            if (self.eat(.assign_eq)) _ = try self.parseExpr();
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
            _ = try self.optDiscipline();
            _ = self.eat(.kw_reg);
            while (true) {
                _ = try self.expectIdent();
                if (self.eat(.assign_eq)) _ = try self.parseExpr();
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        }
        // A.5.3 `sequential_body ::= [ udp_initial_statement ] table …`, and
        // `udp_initial_statement ::= initial output_port_identifier = init_val ;`
        if (self.eat(.kw_initial)) {
            _ = try self.expectIdent();
            _ = try self.expect(.assign_eq);
            _ = try self.parseExpr();
            _ = try self.expect(.semicolon);
        }
        try self.parseUdpTable();
        if (!self.reservedIs(self.pos, "endprimitive"))
            return self.failAt(self.pos, .E0207, "found {s}: no `endprimitive` closes the declaration", .{self.found(self.pos)});
        self.pos += 1;
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
    fn parseUdpTable(self: *Parser) Error!void {
        if (!self.reservedIs(self.pos, "table"))
            return self.failAt(self.pos, .E0207, "found {s}: a udp_body is a `table … endtable`", .{self.found(self.pos)});
        self.pos += 1;
        // Which `udp_body` alternative this table is, decided by its FIRST
        // entry and then required of every other one (A.5.3 gives a table one
        // body and not a mixture).
        var sequential: ?bool = null;
        while (!self.reservedIs(self.pos, "endtable")) {
            if (self.peek() == .eof)
                return self.failAt(self.pos, .E0207, "found {s}: no `endtable` closes the table", .{self.found(self.pos)});
            try self.parseUdpEntry(&sequential);
        }
        self.pos += 1;
    }

    /// One `combinational_entry` or `sequential_entry`, judged column by column.
    fn parseUdpEntry(self: *Parser, sequential: *?bool) Error!void {
        const tok = self.pos;
        // Column 0 is the input list; a colon opens each of the 1 or 2 that
        // follow, so the colon count IS the entry's `udp_body` alternative.
        var cols: [3]struct { text: [64]u8 = undefined, len: usize = 0, tok: u32 = 0 } = .{ .{}, .{}, .{} };
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
        for (inputs) |c| {
            if (std.mem.indexOfScalar(u8, "01xX?bB", c) != null) continue;
            if (std.mem.indexOfScalar(u8, "rRfFpPnN*()", c) != null) {
                if (is_seq) continue;
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
    }

    fn udpBodyName(sequential: bool) []const u8 {
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
    fn parseUdpInst(self: *Parser) Error!void {
        try self.gateNotModelled();
        self.pos += 1; // the udp_identifier
        var s0: Ast.Strength = .strong;
        var s1: Ast.Strength = .strong;
        if (self.peek() == .lparen and self.strengthWord(self.pos + 1) != null) try self.parseDriveStrength(&s0, &s1);
        // A.2.2.3 `delay2` — a `delay3` that stops at two values, which
        // `parseDelay3` already returns for a two-value list.
        if (self.peek() == .hash) _ = try self.parseDelay3();
        while (true) {
            if (self.identLike(self.pos)) {
                self.pos += 1;
                // `name_of_udp_instance ::= udp_instance_identifier [ range ]`
                if (self.peek() == .lbracket) _ = try self.parseDim();
            }
            _ = try self.expect(.lparen);
            _ = try self.parseNetRef(); // A.3.3 output_terminal ::= net_lvalue
            while (self.eat(.comma)) _ = try self.parseExpr(); // input_terminal ::= expression
            _ = try self.expect(.rparen);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    // -----------------------------------------------------------------------
    // A.1.2 module_declaration — LRM §6.2
    // -----------------------------------------------------------------------

    /// LRM §6.2: header (name + optional parameter port list + ports §6.5),
    /// then module items.
    pub fn parseModule(self: *Parser) Error!Ast.ModuleDecl {
        const main_tok = self.pos;
        const is_connect = self.peek() == .kw_connectmodule;
        self.pos += 1; // 'module' | 'macromodule' | 'connectmodule'
        const name = try self.expectIdent();

        const saved_connect = self.in_connect_module;
        self.in_connect_module = is_connect;
        defer self.in_connect_module = saved_connect;

        var b: Body = .{};
        // A.1.2 `module_identifier [ module_parameter_port_list ] list_of_ports`
        // — A.1.3 `module_parameter_port_list ::= # ( parameter_declaration
        // { , parameter_declaration } )`. §6.2: "The optional list of parameter
        // definitions shall specify an ordered list of the parameters for the
        // module." Ordered, and `b.params` is append-only, so declaration order
        // IS that order and header parameters land in the same list as body
        // ones — a header parameter is an ordinary §3.4 parameter with the same
        // default and the same §9.19 status, which is the whole claim.
        //
        // `parseParamDecl` already loops over the commas INSIDE one declaration
        // (`parameter real a = 1, b = 2`), and A.1.3's separator is the same
        // comma, so the two levels are indistinguishable here and there is
        // nothing to nest: keep eating declarations while a `parameter` or
        // `localparam` keyword follows the comma the inner loop stopped at.
        if (self.peek() == .hash) {
            self.pos += 1;
            _ = try self.expect(.lparen);
            while (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
                try self.parseParamDecl(&b.params);
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
        if (self.peek() == .lparen) try self.parsePortList(&b);
        _ = try self.expect(.semicolon);
        try self.parseModuleItems(&b, .kw_endmodule);
        _ = try self.expect(.kw_endmodule);
        self.checkGenBlockNames(&b);
        const attrs = try self.arena.dupe(Ast.NatureAttr, self.attrs.items);
        self.attrs.clearRetainingCapacity();

        return .{
            .name = name,
            .main_tok = main_tok,
            .ports = b.ports.items,
            .params = b.params.items,
            .aliasparams = b.aliasparams.items,
            .vars = b.vars.items,
            .nets = b.nets.items,
            .branches = b.branches.items,
            .instances = b.instances.items,
            .defparams = b.defparams.items,
            .genvars = b.genvars.items,
            .events = b.events.items,
            .functions = b.functions.items,
            .analog = b.analog.items,
            .discrete = b.discrete.items,
            .assigns = b.assigns.items,
            .gates = b.gates.items,
            // §2.9 — every attr_spec seen since the last module. Attributes
            // BEFORE the `module` keyword (Syntax 2-7 puts a slot there) were
            // collected by `parseSource` and belong to this module too, which is
            // why the list is cleared at the end and not at the start.
            .attrs = attrs,
            .is_connect = is_connect,
        };
    }

    /// LRM §6.4 / A.1.9 paramset_declaration.
    ///
    ///     paramset paramset_identifier module_or_paramset_identifier ;
    ///         { paramset_item_declaration } { paramset_statement }
    ///     endparamset
    ///
    /// §6.4: "The paramset itself contains no behavioral code; all of the
    /// behavior is determined by the associated module" — so a paramset is a
    /// named bundle of parameter values for that module, and everything here is
    /// either a declaration of its OWN parameters or one `.name = expr;`
    /// assignment to the module's.
    ///
    /// ponytail: A.1.9's OTHER two statement forms are read and dropped —
    /// `paramset_local_identifier = expr ;` (§6.4.3's output variables, whose
    /// value a host REPORTS for the instance and which §6.4.3 gives no way to
    /// read back inside the module) and `analog_function_statement`. Nothing
    /// downstream has an operating-point reporting path to put them in, and a
    /// dropped statement is visible in the fixture that asks for one
    /// (ch06_hierarchy/paramset_output_unsupported.va says so in its header).
    /// The upgrade is an output-variable table on the emitted device, and this
    /// loop is where the parse of it goes.
    fn parseParamset(self: *Parser) Error!Ast.ParamsetDecl {
        const main_tok = self.pos;
        self.pos += 1; // 'paramset'
        const name = try self.expectIdent();
        const target = try self.expectIdent();
        _ = try self.expect(.semicolon);

        var params: std.ArrayList(Ast.ParamDecl) = .empty;
        var aliasparams: std.ArrayList(Ast.AliasParam) = .empty;
        var vars: std.ArrayList(Ast.VarDecl) = .empty;
        var overrides: std.ArrayList(Ast.ParamsetOverride) = .empty;

        while (true) {
            try self.skipAttributes();
            try self.outsideDesignElement("paramset");
            switch (self.peek()) {
                .eof, .kw_endparamset => break,
                .kw_parameter, .kw_localparam => {
                    try self.parseParamDecl(&params);
                    _ = try self.expect(.semicolon);
                },
                .kw_aliasparam => {
                    self.pos += 1;
                    const alias = try self.expectIdent();
                    _ = try self.expect(.assign_eq);
                    const t = try self.expectIdent();
                    _ = try self.expect(.semicolon);
                    try aliasparams.append(self.arena, .{ .alias = alias, .target = t });
                },
                .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                    try self.parseVarDecl(&vars);
                    _ = try self.expect(.semicolon);
                },
                // A.1.9 `paramset_statement ::= . module_parameter_identifier =
                // paramset_constant_expression ;` and its `. system_parameter_-
                // identifier` sibling (§9.18's `$mfactor` and friends), told
                // apart by the one token that spells a system name.
                .dot => {
                    const tok = self.pos;
                    self.pos += 1;
                    const is_sys = self.peek() == .system_identifier;
                    const pname = if (is_sys) blk: {
                        const s = try self.internTok(self.pos);
                        self.pos += 1;
                        break :blk s;
                    } else try self.expectIdent();
                    _ = try self.expect(.assign_eq);
                    const value = try self.parseExpr();
                    _ = try self.expect(.semicolon);
                    try overrides.append(self.arena, .{
                        .kind = if (is_sys) .system_param else .module_param,
                        .name = pname,
                        .value = value,
                        .main_tok = tok,
                    });
                },
                // The two dropped statement forms (see the doc comment), and
                // ONLY those. Skipped by tokens rather than parsed: the
                // right-hand side of an output assignment may contain §6.4.3's
                // `.module_output_variable` spelling, which is not an
                // expression anywhere else in the language, and nothing reads
                // the result. What the silent skip is restricted to is what
                // A.1.9 actually admits here — a variable assignment
                // (`ft = 3.0 * .gm;`, an identifier followed by `=` or an
                // array element's `[`) or a §6.4.1 analog_function_statement
                // conditional wrapping such assignments — because the skip used
                // to take EVERYTHING, so a misspelled `paramter real rr;`
                // compiled clean and the paramset silently lacked a parameter.
                else => {
                    const legal = (self.identLike(self.pos) and
                        (self.peekAt(1) == .assign_eq or self.peekAt(1) == .lbracket)) or
                        switch (self.peek()) {
                            .kw_if, .kw_case, .kw_for, .kw_while, .kw_repeat, .kw_begin => true,
                            else => false,
                        };
                    // (`failAt` always errors, so its result is a bare error
                    // set — widened to a union so ParseError can be dropped
                    // for recovery while OOM still aborts.)
                    if (!legal) @as(Error!void, self.failAt(
                        self.pos,
                        .E0205,
                        "found {s} in a paramset body",
                        .{self.found(self.pos)},
                    )) catch |e| if (e == error.OutOfMemory) return e;
                    self.skipParamsetStatement();
                },
            }
        }
        _ = try self.expect(.kw_endparamset);
        // §2.9 attributes inside a paramset decorate its declarations, and
        // `NatureAttr` collection is per design element — drop them with the
        // element, exactly as the module path keeps its own.
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

    /// LRM §7.7 / A.1.8 connectrules_declaration.
    ///
    ///     connectrules connectrules_identifier ;
    ///         { connectrules_item }
    ///     endconnectrules
    ///     connectrules_item ::= connect_insertion | connect_resolution
    ///
    /// Both item forms open with `connect identifier`, and the token AFTER the
    /// identifier decides which production the grammar is in: a `,` or
    /// `resolveto` can only continue A.1.8's connect_resolution (an insertion
    /// puts a mode keyword, a `#`, a direction, a second identifier or the `;`
    /// there), and nothing in an insertion ever spells `resolveto`. One token
    /// of lookahead, no backtracking — same budget as every other fork here.
    ///
    /// Names are not resolved: the connect module of a §7.7.1 insertion and
    /// the disciplines of a §7.7.2 resolution may be declared after the block
    /// (A.1.2 puts no order on descriptions), so both are elaboration's to
    /// judge (`Elaborate.checkConnectRules`).
    fn parseConnectRules(self: *Parser) Error!Ast.ConnectRulesDecl {
        const main_tok = self.pos;
        self.pos += 1; // 'connectrules'
        const name = try self.expectIdent();
        _ = try self.expect(.semicolon);

        var insertions: std.ArrayList(Ast.ConnectInsertion) = .empty;
        var resolutions: std.ArrayList(Ast.ConnectResolution) = .empty;
        while (!self.eat(.kw_endconnectrules)) {
            try self.outsideDesignElement("connectrules");
            const item_tok = try self.expect(.kw_connect);
            const first = try self.expectIdent();
            if (self.peek() == .comma or self.peek() == .kw_resolveto) {
                // A.1.8 connect_resolution — §7.7.2.
                var discs: std.ArrayList(Ast.StrId) = .empty;
                try discs.append(self.arena, first);
                while (self.eat(.comma)) try discs.append(self.arena, try self.expectIdent());
                _ = try self.expect(.kw_resolveto);
                var res: Ast.ConnectResolution = .{ .disciplines = discs.items, .main_tok = item_tok };
                // A.1.8 discipline_identifier_or_exclude. `exclude` is the
                // §3.4.2 value-range keyword spent again (annex B reserves it
                // once), so the tag already exists.
                if (self.eat(.kw_exclude)) res.exclude = true else res.resolved = try self.expectIdent();
                _ = try self.expect(.semicolon);
                try resolutions.append(self.arena, res);
            } else {
                // A.1.8 connect_insertion — §7.7.1, with §7.7.4's mode and
                // §7.7.3's parameter list in their grammar slots.
                var ins: Ast.ConnectInsertion = .{ .module = first, .main_tok = item_tok };
                if (self.eat(.kw_merged)) {
                    ins.mode = .merged;
                } else if (self.eat(.kw_split)) {
                    ins.mode = .split;
                }
                ins.params = try self.parseParamValueAssignment();
                if (self.peek() != .semicolon) {
                    // A.1.8 connect_port_overrides. The grammar admits exactly
                    // four direction shapes — none/none, input/output,
                    // output/input, inout/inout — so the FIRST direction fixes
                    // what the second must be, and `expect` states it.
                    const a_dir: Ast.Direction = switch (self.peek()) {
                        .kw_input => .input,
                        .kw_output => .output,
                        .kw_inout => .inout,
                        else => .unspecified,
                    };
                    if (a_dir != .unspecified) self.pos += 1;
                    const a = try self.expectIdent();
                    _ = try self.expect(.comma);
                    const b_dir: Ast.Direction = switch (a_dir) {
                        .unspecified => .unspecified,
                        .input => blk: {
                            _ = try self.expect(.kw_output);
                            break :blk .output;
                        },
                        .output => blk: {
                            _ = try self.expect(.kw_input);
                            break :blk .input;
                        },
                        .inout => blk: {
                            _ = try self.expect(.kw_inout);
                            break :blk .inout;
                        },
                    };
                    const second = try self.expectIdent();
                    ins.overrides = .{ .a_dir = a_dir, .a = a, .b_dir = b_dir, .b = second };
                }
                _ = try self.expect(.semicolon);
                try insertions.append(self.arena, ins);
            }
        }
        return .{
            .name = name,
            .insertions = insertions.items,
            .resolutions = resolutions.items,
            .main_tok = main_tok,
        };
    }

    /// Skip ONE A.1.9 paramset statement by tokens: to the `;` that ends it,
    /// balancing `(...)` (a `for` header holds two semicolons), `begin`/`end`
    /// and `case`/`endcase`, and continuing over `else` — so a dropped
    /// `if (c) begin ft = 1.0; end else ft = 2.0;` is ONE silent skip rather
    /// than a diagnostic per fragment. A statement that IS a block ends at its
    /// `end`/`endcase`, which carries no `;` of its own.
    fn skipParamsetStatement(self: *Parser) void {
        var depth: u32 = 0;
        while (true) : (self.pos += 1) switch (self.peek()) {
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
            else => {},
        };
    }

    /// Accumulators for one module body. Arena-owned; `.items` becomes the
    /// ModuleDecl's slices (append-only ⇒ source order is preserved).
    const Body = struct {
        ports: std.ArrayList(Ast.Port) = .empty,
        params: std.ArrayList(Ast.ParamDecl) = .empty,
        aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
        vars: std.ArrayList(Ast.VarDecl) = .empty,
        nets: std.ArrayList(Ast.NetDecl) = .empty,
        branches: std.ArrayList(Ast.BranchDecl) = .empty,
        instances: std.ArrayList(Ast.Instance) = .empty, // §6.2.2
        defparams: std.ArrayList(Ast.Defparam) = .empty, // §6.3.1
        genvars: std.ArrayList(Ast.StrId) = .empty,
        events: std.ArrayList(Ast.StrId) = .empty, // §5.10.4
        functions: std.ArrayList(Ast.FuncDecl) = .empty,
        analog: std.ArrayList(Ast.AnalogBlock) = .empty,
        discrete: std.ArrayList(Ast.DiscreteBlock) = .empty, // A.6.2, §7.2.2
        assigns: std.ArrayList(Ast.ContAssign) = .empty, // A.6.1
        gates: std.ArrayList(Ast.GateInst) = .empty, // A.3.1
        /// §6.6.1/§6.6.2 every named generate block of the module, with the
        /// generate construct it belongs to. NOT part of `ModuleDecl`: the name
        /// is a declaration of a scope nothing downstream can reach yet
        /// (§6.6.3 hierarchical names are unimplemented), so its only consumer
        /// is `checkGenBlockNames`.
        gen_blocks: std.ArrayList(GenBlock) = .empty,
    };

    /// One `begin : name` produced by the `generate_block` production — which
    /// is the only production whose name is a DECLARATION rather than a §5.3.2
    /// statement label, and the reason this is collected in the parser: no later
    /// stage can tell the two `begin`s apart.
    const GenBlock = struct {
        name: Ast.StrId,
        tok: u32,
        /// `Parser.gen_construct` at the time — the OUTERMOST enclosing
        /// construct, so two arms of one `if`/`case` share it.
        construct: u32,
    };

    /// A.1.3 `port_expression ::= port_reference | { port_reference
    /// { , port_reference } }` (§6.5.1: a port may be "a simple net
    /// identifier" or "a vector net formed as a result of the concatenation
    /// operator"). Appends one `Ast.Port` per port_reference.
    ///
    /// ponytail: a concatenated port becomes N terminals, not one N-bit
    /// terminal. That is the same model §3.6.3 vector ports already get here —
    /// `electrical [1:0] p` scalarises to two nodes and two terminals.
    /// The external port's width and member order live in these consecutive
    /// entries, in source order.
    ///
    /// A.1.3 list_of_ports / list_of_port_declarations (§6.5). Both styles fall
    /// out of one loop: a direction keyword starts a new declaration and its
    /// direction+discipline stick to the following comma-separated names.
    fn parsePortList(self: *Parser, b: *Body) Error!void {
        _ = try self.expect(.lparen);
        if (self.eat(.rparen)) return;
        var dir: Ast.Direction = .unspecified;
        var disc: Ast.StrId = .none;
        var range: ?Ast.Dim = null;
        while (true) {
            try self.skipAttributes();
            if (token.isPortDirection(self.peek())) {
                dir = portDirection(self.peek());
                self.pos += 1;
                disc = try self.optDiscipline();
                // A.1.3 `inout [ range ] port_identifier {, port_identifier}` —
                // the range belongs to the declaration, so it sticks to every
                // name in the list exactly as the direction and the discipline
                // do (§6.5.2 "electrical [3:0] a, b" declares two 4-bit ports).
                range = if (self.peek() == .lbracket) try self.parseDim() else null;
            }
            // A.1.3 `port ::= [ port_expression ] | . port_identifier (
            // [ port_expression ] )`. The second alternative gives the port an
            // EXTERNAL name distinct from the internal net(s) it connects to.
            var external: Ast.StrId = .none;
            var close_named = false;
            if (self.eat(.dot)) {
                external = try self.expectIdent();
                _ = try self.expect(.lparen);
                close_named = true;
            }
            const concat = self.eat(.lbrace);
            while (true) {
                const tok = self.pos;
                const name = try self.expectIdent();
                try b.ports.append(self.arena, .{
                    .name = name,
                    .direction = dir,
                    .discipline = disc,
                    .range = range,
                    .external_name = external,
                    .main_tok = tok,
                });
                if (!concat or !self.eat(.comma)) break;
            }
            if (concat) _ = try self.expect(.rbrace);
            if (close_named) _ = try self.expect(.rparen);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }

    fn portDirection(tag: token.Tag) Ast.Direction {
        return switch (tag) {
            .kw_input => .input,
            .kw_output => .output,
            else => .inout,
        };
    }

    /// A.2.1.2 `[ discipline_identifier ] [ net_type ] [ signed ]` prefix of a
    /// port declaration. A discipline is an identifier followed by another
    /// identifier (the first port name), so one token of lookahead decides.
    fn optDiscipline(self: *Parser) Error!Ast.StrId {
        var disc: Ast.StrId = .none;
        if (self.peek() == .identifier and self.identLike(self.pos + 1)) {
            disc = try self.internTok(self.pos);
            self.pos += 1;
        }
        if (token.isNetType(self.peek())) self.pos += 1;
        _ = self.eat(.kw_signed);
        return disc;
    }

    // -----------------------------------------------------------------------
    // A.1.4 module_item — LRM §6.2, ch3
    // -----------------------------------------------------------------------

    fn parseModuleItems(self: *Parser, b: *Body, end: token.Tag) Error!void {
        while (true) {
            try self.skipAttributes();
            const t = self.peek();
            if (t == end or t == .eof or t == .kw_endmodule) return;
            const before = self.pos;
            self.parseModuleItem(b) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.recoverStatement(before);
            };
        }
    }

    fn parseModuleItem(self: *Parser, b: *Body) Error!void {
        switch (self.peek()) {
            // §10.6: "can only be specified outside of a design element".
            .dir_begin_keywords, .dir_end_keywords => return self.failAt(
                self.pos,
                .E0202,
                "{s} inside a module",
                .{token.Tag.lexeme(self.peek()).?},
            ),
            // A.4.2 loop_generate_construct / conditional_generate_construct.
            // §6.6: "Use of generate regions is optional. There is no semantic
            // difference in the module when a generate region is used", and the
            // clause's own rcline2 example writes a bare `for` at module scope —
            // so these are NOT gated on having seen `generate`.
            //
            // Syntax 6-8 makes the body a `generate_block`, a run of MODULE
            // items, which is why they cannot go through `parseStmt`: the only
            // route A.1.4 offers from a module_or_generate_item to a
            // contribution is `analog_construct ::= analog analog_statement`,
            // and `analog` is not the start of any analog statement.
            .kw_for => try self.parseGenerate(b, .kw_for),
            .kw_if => try self.parseGenerate(b, .kw_if),
            // Syntax 6-8 case_generate_construct. Gated on being inside a
            // generate region or block because `case` is ALSO A.6.7's statement
            // keyword, and at module scope with no generate above it there is no
            // production for either — that stays E0205, which a dozen fixtures
            // pin together with the word `case`.
            .kw_case => if (self.gen_depth > 0)
                try self.parseGenerate(b, .kw_case)
            else
                return self.unsupportedItem(),
            // Not an item: a generate_block is only ever the body of the two
            // above (E0221). Kept as its own arm so the diagnostic can cite
            // Syntax 6-8 rather than blaming the analog subset.
            .kw_begin => return self.failAt(self.pos, .E0221, "", .{}),
            // §3.4 parameter / localparam (A.2.1.1)
            .kw_parameter, .kw_localparam => {
                // §6.6: a generate block "MAY NOT CONTAIN port declarations,
                // PARAMETER DECLARATIONS, specify blocks, or specparam
                // declarations", and Syntax 6-8 says it again by omission —
                // `module_or_generate_item` admits `local_parameter_declaration`
                // and no `parameter_declaration`. `localparam` is therefore
                // deliberately NOT gated: it is the form the grammar keeps,
                // because it carries no override for the elaborator to need
                // before it exists (§6.3).
                if (self.gen_depth > 0 and self.peek() == .kw_parameter)
                    return self.failAt(self.pos, .E0229, "", .{});
                try self.parseParamDecl(&b.params);
                _ = try self.expect(.semicolon);
            },
            // §6.3.1 parameter_override (A.1.4). `defparam
            // list_of_defparam_assignments ;`, each assignment a hierarchical
            // parameter identifier and a constant expression.
            //
            // Nothing is resolved here — the path names a parameter of an
            // INSTANCE, which does not exist until elaboration, and §6.3.1's
            // "shall be a constant expression" is over the DECLARING module's
            // parameters. Both are `ir/elaborate.zig`'s questions, and so is the
            // path that names nothing (E0907).
            .kw_defparam => {
                self.pos += 1;
                while (true) {
                    const tok = self.pos;
                    // `true`: A.9.3 admits `u[0].g` — the parameter of ONE
                    // element of an instance array, which is a flat name
                    // elaboration really mints.
                    const path = try self.parseDottedName(true);
                    _ = try self.expect(.assign_eq);
                    const value = try self.parseExpr();
                    try b.defparams.append(self.arena, .{
                        .path = path,
                        .value = value,
                        .main_tok = tok,
                    });
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // §3.4.6 aliasparam (A.2.1.1)
            .kw_aliasparam => {
                self.pos += 1;
                const alias = try self.expectIdent();
                _ = try self.expect(.assign_eq);
                // §3.4.7 prints `aliasparam m = $mfactor;` beside `aliasparam
                // trise = dtemp;`. Syntax 3-2 puts a parameter_identifier on the
                // right, so a §9.18 hierarchical system parameter is a form the
                // clause states in prose only — one token tag here, not a second
                // production. WHICH system parameters have storage to alias is
                // `Lower.aliasSystemParam`'s question, not the grammar's.
                const target = if (self.peek() == .system_identifier) blk: {
                    const s = try self.internTok(self.pos);
                    self.pos += 1;
                    break :blk s;
                } else try self.expectIdent();
                _ = try self.expect(.semicolon);
                try b.aliasparams.append(self.arena, .{ .alias = alias, .target = target });
            },
            // §3.2/§3.3 variable declarations (A.2.1.3)
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                try self.parseVarDecl(&b.vars);
                _ = try self.expect(.semicolon);
            },
            // §3.5 genvar (A.4.2)
            .kw_genvar => {
                self.pos += 1;
                while (true) {
                    try b.genvars.append(self.arena, try self.expectIdent());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // A.2.1.3 `event_declaration ::= event list_of_event_identifiers ;`
            // (§5.10.4). Named events ARE part of the Verilog-A subset — §5.10
            // lists them as one of the three kinds of ANALOG event and §5.10.4's
            // own example triggers and detects one entirely inside an `analog`
            // block; annex C.7 excludes only DIGITAL behavior and events.
            .kw_event => {
                self.pos += 1;
                while (true) {
                    try b.events.append(self.arena, try self.expectIdent());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // §3.12 branch declaration (A.2.1.3)
            .kw_branch => try self.parseBranchDecl(b),
            // §3.6.4 ground declaration (A.2.1.3 net_declaration)
            .kw_ground => {
                self.pos += 1;
                const disc = try self.optDiscipline();
                try self.parseNetNames(b, disc, .wire, true, .{});
            },
            // §6.5.2 non-ANSI port declarations
            .kw_input, .kw_output, .kw_inout => try self.parsePortDecl(b),
            // A.2.1.3 net_declaration with an explicit net type
            .kw_wire,
            .kw_tri,
            .kw_tri0,
            .kw_tri1,
            .kw_triand,
            .kw_trior,
            .kw_trireg,
            .kw_wand,
            .kw_wor,
            .kw_uwire,
            .kw_supply0,
            .kw_supply1,
            => {
                const kind = netKind(self.peek());
                self.pos += 1;
                // A.2.1.3: `charge_strength` sits right after the net type, and
                // only `trireg`'s alternatives have one. §3.8's default for a
                // `trireg` that names none is `medium`.
                //
                // …and so does `drive_strength`, on the `list_of_net_decl_assignments`
                // arms of the SAME production — four of A.2.1.3's twelve
                // `net_declaration` alternatives carry one:
                //
                //     net_type [ discipline_identifier ] [ drive_strength ] [ signed ]
                //         [ delay3 ] list_of_net_decl_assignments ;
                //
                // One token tells the two brackets apart without a backtrack.
                // A.2.2.2's six `drive_strength` alternatives are all PAIRS, so
                // a comma after the first strength word is the discriminator;
                // A.2.2.1's `charge_strength ::= ( small ) | ( medium ) |
                // ( large )` is always the single word. Anything else stays
                // with `parseChargeStrength`, whose two diagnostics ("not a
                // charge strength", "only legal on a trireg") are the ones
                // that say what went wrong.
                // The default pair is IEEE 1364-2005 §7.10's: "the strengths
                // default to strong1 and strong0", so a declaration with no
                // bracket is indistinguishable from `(strong1, strong0)` and
                // needs no flag to say the bracket was absent.
                var st: Ast.NetStrength = .{};
                if (self.peek() == .lparen) {
                    if (self.strengthWord(self.pos + 1) != null and self.peekAt(2) == .comma)
                        try self.parseDriveStrength(&st.strength0, &st.strength1)
                    else
                        st.charge = try self.parseChargeStrength(kind);
                }
                const disc = try self.optDiscipline();
                try self.parseNetNames(b, disc, kind, false, st);
            },
            // A.6.1 `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
            // list_of_net_assignments ;`. Only the digital executor has nets
            // with drivers to resolve; annex C.7 has no digital behavior, so
            // outside a digital run this is the E0205 it has always been.
            .kw_assign => {
                if (!self.digital) return self.unsupportedItem();
                self.pos += 1;
                // A.8.5 `net_lvalue` begins with an identifier or a `{`, never a
                // `(`, so the parenthesis is unambiguously A.2.2.2's.
                var s0: Ast.Strength = .strong;
                var s1: Ast.Strength = .strong;
                if (self.peek() == .lparen) try self.parseDriveStrength(&s0, &s1);
                const delay: Ast.Delay3 = if (self.peek() == .hash) try self.parseDelay3() else .{};
                while (true) {
                    const tok = self.pos;
                    const target = try self.parseExpr();
                    _ = try self.expect(.assign_eq);
                    const value = try self.parseExpr();
                    try b.assigns.append(self.arena, .{ .target = target, .value = value, .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // Analog reads retain Table 7-1's integer mapping and its width
            // gate. Digital execution preserves packed width/signedness here;
            // its state starts at X and is driven by the source scheduler.
            .kw_reg => {
                const tok = self.pos;
                self.pos += 1;
                const signed = self.digital and self.eat(.kw_signed);
                const range: ?Ast.Dim = if (self.peek() == .lbracket) try self.parseDim() else null;
                if (!self.digital) if (range) |d| if (self.literalWidth(d)) |w| {
                    if (w > 31) _ = self.failAt(tok, .E0222, "{d} bits", .{w}) catch {};
                };
                while (true) {
                    const name_tok = self.pos;
                    const name = try self.expectIdent();
                    // A.2.1.3 `reg_declaration ::= reg [ discipline_identifier ]
                    // [ signed ] [ range ] list_of_variable_identifiers ;` and
                    // A.2.3 `list_of_variable_identifiers ::= variable_type
                    // { , variable_type }`, so both of these belong to A.2.2.1's
                    //
                    //     variable_type ::=
                    //         variable_identifier { dimension } [ = constant_assignment_pattern ]
                    //         | variable_identifier = constant_expression
                    //
                    // which is the same production `integer`/`time` reach
                    // through `parseVarDecl`, where neither is gated. Gating
                    // them on `digital` here made `reg [7:0] rbus = 8'h5a;` an
                    // E0207 in a `.va` while `integer iv = 7;` beside it was
                    // fine — one production, two answers, and the annex draws
                    // no such line.
                    const dims = try self.parseDims();
                    const value = if (self.eat(.assign_eq)) try self.parseExpr() else Ast.ExprId.none;
                    try b.vars.append(self.arena, .{
                        .name = name,
                        .ty = .integer,
                        .main_tok = name_tok,
                        .storage = .reg,
                        .packed_range = range,
                        .is_signed = signed,
                        .dims = dims,
                        .init = value,
                    });
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.semicolon);
            },
            // A.4.1 `gate_instantiation ::= … | pass_switchtype
            // pass_switch_instance { , pass_switch_instance } ;`
            .kw_tran, .kw_rtran => try self.parsePassSwitch(),
            // A.3.1 `gate_instantiation` — the twelve A.3.4 gate types that
            // compute a logic value.
            .kw_and, .kw_nand, .kw_or, .kw_nor, .kw_xor, .kw_xnor, .kw_buf, .kw_not, .kw_bufif0, .kw_bufif1, .kw_notif0, .kw_notif1 => try self.parseGates(b),
            // A.6.2 `initial_construct` / `always_construct` — §7.2.2's discrete
            // context.
            .kw_initial, .kw_always => try self.parseDiscrete(b),
            // §5.2 analog construct / §4.7.1 analog function
            .kw_analog => try self.parseAnalog(b),
            // A.4.2 generate_region — transparent, per §6.6's "there is no
            // semantic difference": the items inside are plain module items and
            // the region introduces no scope. What it is NOT is re-enterable:
            // §6.6 "Generate regions do not nest, and they may only occur
            // directly within a module", and A.4.2 backs both halves by making
            // `generate_region` a `module_item` that `module_or_generate_item`
            // does not list. `gen_depth` is that sentence — it counts construct
            // bodies too, so a `generate` inside an if-generate's block is
            // refused by the same test as a `generate` inside a `generate`.
            .kw_generate => {
                // Reported and then parsed ANYWAY, transparently: §6.6 gives a
                // region no scope and "no semantic difference", so reading the
                // inner one as if the keywords were absent is exact recovery —
                // bailing here instead left the stray `endgenerate` to arrive as
                // a second, meaningless E0205.
                if (self.gen_depth > 0) _ = self.failAt(self.pos, .E0228, "", .{}) catch {};
                self.pos += 1;
                self.gen_depth += 1;
                defer self.gen_depth -= 1;
                try self.parseModuleItems(b, .kw_endgenerate);
                _ = try self.expect(.kw_endgenerate);
            },
            // A.2.1.3 `discipline_identifier list_of_net_identifiers ;`
            // vs A.4.1 module_instantiation — both start with an identifier.
            .identifier, .escaped_identifier => {
                // A `#` can only be a parameter_value_assignment, and
                // `identifier identifier` followed by `(` or `[` can only be a
                // module_instance: A.2.1.3's net declaration puts its optional
                // range BEFORE the name list (`electrical [0:3] bus;`, which is
                // the `lbracket` case one line below), never after it, so no net
                // declaration reaches a `[` in that position.
                if (self.peekAt(1) == .hash or
                    (self.identLike(self.pos + 1) and
                        (self.peekAt(2) == .lparen or self.peekAt(2) == .lbracket)))
                    return self.parseInstantiation(b);
                // A.5.4 `udp_instantiation`, whose `udp_instance` makes
                // `name_of_udp_instance` OPTIONAL where A.4.1's `module_instance
                // ::= name_of_module_instance ( … )` does not. So an identifier
                // followed directly by `(` derives from A.5.4 and from nothing
                // else at module scope, and one token settles it.
                if (self.peekAt(1) == .lparen) return self.parseUdpInst();
                // `discipline [range] names ;` — a vector net's range is
                // rejected by the name list ("expected identifier"), which is
                // the wording the fixtures pin.
                if (!self.identLike(self.pos + 1) and self.peekAt(1) != .lbracket) {
                    return self.unsupportedItem();
                }
                const disc = try self.internTok(self.pos);
                self.pos += 1;
                try self.parseNetNames(b, disc, .wire, false, .{});
            },
            // Annex B reserves a family of 1364 spellings that this compiler
            // has no tag for — `specify`, `specparam`, `primitive`, `pulldown`
            // and the rest all lex to one `.kw_reserved`, which is what keeps
            // them unusable as identifiers. The spelling is therefore the
            // dispatch, and the two below are the ones with a production here.
            .kw_reserved => {
                const w = self.tokenText(self.pos);
                if (std.mem.eql(u8, w, "specify")) return self.parseSpecifyBlock();
                // A.2.1.1 `specparam_declaration ::= specparam [ range ]
                // list_of_specparam_assignments ;`, reached BOTH as a module
                // item (Syntax 6-1's `non_port_module_item`) and as an A.7.1
                // `specify_item`. This is the module-item half.
                if (std.mem.eql(u8, w, "specparam")) return self.parseSpecparamDecl(&b.params);
                // A.3.1's last two arms. They have no tags of their own because
                // A.3.2 gives them a strength set no other gate takes.
                if (std.mem.eql(u8, w, "pulldown") or std.mem.eql(u8, w, "pullup"))
                    return self.parsePullGate();
                return self.unsupportedItem();
            },
            else => return self.unsupportedItem(),
        }
    }

    /// Is the token at `i` the reserved spelling `w`? Annex B's out-of-subset
    /// keywords share one tag, so every grammar that needs one of them by name
    /// asks here.
    fn reservedIs(self: *const Parser, i: u32, w: []const u8) bool {
        return self.tags[i] == .kw_reserved and std.mem.eql(u8, self.tokenText(i), w);
    }

    /// `=>`, `*>` and `&&&` — A.7's three operators, which the lexer already
    /// recognises as single tokens and tags `.invalid`, because outside a
    /// specify block none of them is an operator at all (`lexer.zig` spells
    /// exactly that at each of the three). So the spelling is the test, and
    /// the tag is what keeps them from meaning anything anywhere else.
    fn eatSymbol(self: *Parser, w: []const u8) bool {
        if (self.peek() != .invalid or !std.mem.eql(u8, self.tokenText(self.pos), w)) return false;
        self.pos += 1;
        return true;
    }

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
    fn parseSpecifyBlock(self: *Parser) Error!void {
        const open = self.pos;
        self.pos += 1; // `specify`
        while (!self.reservedIs(self.pos, "endspecify")) {
            if (self.peek() == .eof or self.peek() == .kw_endmodule)
                return self.failAt(self.pos, .E0207, "found {s}: no `endspecify` closes the specify block", .{self.found(self.pos)});
            try self.parseSpecifyItem();
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
    fn parseSpecifyItem(self: *Parser) Error!void {
        switch (self.peek()) {
            .kw_reserved => {
                const w = self.tokenText(self.pos);
                // A.2.1.1's declaration, here as a specify_item. The list is
                // DISCARDED rather than appended to the module's parameters:
                // a specparam declared inside the block is scoped to it, and
                // the block is not elaborated.
                if (std.mem.eql(u8, w, "specparam")) return self.parseSpecparamDecl(null);
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
                    try self.parseSpecifyTerminalList();
                    if (paren) _ = try self.expect(.rparen);
                    _ = try self.expect(.semicolon);
                    return;
                }
                // A.7.2 `state_dependent_path_declaration ::= … | ifnone
                // simple_path_declaration`.
                if (std.mem.eql(u8, w, "ifnone")) {
                    self.pos += 1;
                    return self.parsePathDeclaration();
                }
                return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)});
            },
            // A.7.2 `state_dependent_path_declaration ::= if ( module_path_expression )`
            // followed by a simple or edge-sensitive path.
            .kw_if => {
                self.pos += 1;
                _ = try self.expect(.lparen);
                _ = try self.parseExpr();
                _ = try self.expect(.rparen);
                return self.parsePathDeclaration();
            },
            .lparen => return self.parsePathDeclaration(),
            .system_identifier => return self.parseTimingCheck(),
            else => return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)}),
        }
    }

    /// A.7.3 `specify_input_terminal_descriptor ::= input_identifier
    /// [ [ constant_range_expression ] ]` and its output twin, which differ
    /// only in which port directions the identifier may name — a rule about
    /// the NAME, judged where the ports are known, not here.
    fn parseSpecifyTerminal(self: *Parser) Error!void {
        _ = try self.expectIdent();
        if (!self.eat(.lbracket)) return;
        _ = try self.parseExpr();
        if (self.eat(.colon)) _ = try self.parseExpr();
        _ = try self.expect(.rbracket);
    }

    /// A.7.2 `list_of_path_inputs` / `list_of_path_outputs` — the same
    /// comma-separated run of A.7.3 descriptors under two names.
    fn parseSpecifyTerminalList(self: *Parser) Error!void {
        while (true) {
            try self.parseSpecifyTerminal();
            if (!self.eat(.comma)) return;
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
    fn parsePathDeclaration(self: *Parser) Error!void {
        _ = try self.expect(.lparen);
        // A.7.4 `edge_identifier ::= posedge | negedge`, present only on the
        // two edge-sensitive descriptions.
        _ = self.eat(.kw_posedge) or self.eat(.kw_negedge);
        try self.parseSpecifyTerminalList();
        // A.7.4 `polarity_operator ::= + | -`.
        _ = self.eat(.plus) or self.eat(.minus);
        const parallel = self.eatSymbol("=>");
        if (!parallel and !self.eatSymbol("*>")) return self.failAt(
            self.pos,
            .E0207,
            "found {s}: a path description connects its terminals with `=>` or `*>`",
            .{self.found(self.pos)},
        );
        if (self.eat(.lparen)) {
            // The edge-sensitive arms: the outputs, a polarity and the
            // `data_source_expression` the path's value comes from.
            try self.parseSpecifyTerminalList();
            _ = self.eat(.plus) or self.eat(.minus);
            _ = try self.expect(.colon);
            _ = try self.parseExpr();
            _ = try self.expect(.rparen);
        } else try self.parseSpecifyTerminalList();
        _ = try self.expect(.rparen);
        _ = try self.expect(.assign_eq);
        // A.7.4 `path_delay_value ::= list_of_path_delay_expressions
        // | ( list_of_path_delay_expressions )`. The parenthesis is read HERE
        // and not by `parseExpr`, because `( tplh , tphl )` is a list of two
        // and a parenthesized expression is one.
        const bracketed = self.eat(.lparen);
        while (true) {
            _ = try self.parseExpr();
            if (!self.eat(.comma)) break;
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
    const timing_checks = std.StaticStringMap(struct { u8, u8 }).initComptime(.{
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

    /// A.7.5.1 `system_timing_check`. A `$name` inside a specify block is one
    /// of exactly twelve commands — A.7.1 admits no other system task there —
    /// so a name the table does not hold is an error rather than a call.
    fn parseTimingCheck(self: *Parser) Error!void {
        const tok = self.pos;
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
            // A.7.5.1 writes the optional arguments `[ , [ notifier ] ]` — the
            // comma outside the inner bracket, so the slot may be present and
            // EMPTY. That is why an argument is counted before it is read.
            n +|= 1;
            if (self.peek() != .comma and self.peek() != .rparen) try self.parseTimingCheckArg();
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
    /// One routine takes the union, which over-accepts: `$width`'s first
    /// argument is a `controlled_reference_event` whose event control is
    /// MANDATORY, and that is not checked here. What the union does buy is
    /// that every optional piece of A.7.5.3 is read rather than skipped.
    fn parseTimingCheckArg(self: *Parser) Error!void {
        if (!self.eat(.kw_posedge) and !self.eat(.kw_negedge) and self.reservedIs(self.pos, "edge")) {
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
        _ = try self.parseExpr();
        // A.7.5.3's `&&&`, which is three tokens' worth of `&` in a stream that
        // has no tag for it.
        if (self.eatSymbol("&&&")) _ = try self.parseExpr();
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
    fn parseSpecparamDecl(self: *Parser, out: ?*std.ArrayList(Ast.ParamDecl)) Error!void {
        self.pos += 1; // `specparam`
        const packed_range: ?Ast.Dim = if (self.peek() == .lbracket) try self.parseDim() else null;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            _ = try self.expect(.assign_eq);
            const default = try self.parseExpr();
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
    fn parseInstantiation(self: *Parser, b: *Body) Error!void {
        const module = try self.internTok(self.pos);
        self.pos += 1;
        const params = try self.parseParamValueAssignment();

        while (true) {
            const name_tok = self.pos;
            const name = try self.expectIdent();
            const range: ?Ast.Dim = if (self.peek() == .lbracket) try self.parseDim() else null;
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
                        const e = if (self.peek() == .rparen) Ast.ExprId.none else try self.parseExpr();
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
                            try self.parseExpr();
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
    fn parseParamValueAssignment(self: *Parser) Error![]const Ast.ParamOverride {
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
                        const v = if (self.peek() == .rparen) Ast.ExprId.none else try self.parseExpr();
                        _ = try self.expect(.rparen);
                        try params.append(self.arena, .{ .name = pname, .value = v, .main_tok = tok });
                    } else {
                        try params.append(self.arena, .{ .value = try self.parseExpr(), .main_tok = tok });
                    }
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.rparen);
            }
        }
        return params.items;
    }

    /// One shared diagnostic for everything VerA leaves out at module scope:
    /// gate and UDP instantiations, `task`, `specify`, generate-case …
    fn unsupportedItem(self: *Parser) Error {
        return self.failAt(self.pos, .E0205, "found {s}", .{self.found(self.pos)});
    }

    /// The SAME E0205, reported without setting `failed` — so the file is still
    /// refused (the bag holds an error, and `root.zig` reads `bag.failed()`) but
    /// `parseSourceFile` does not raise `ParseError`, and stage 4 therefore still
    /// runs over the recorded AST.
    ///
    /// That distinction is the whole of why `always` is parsed at all (`reg` and
    /// `initial` are now accepted outright — see `parseDiscrete`). A construct
    /// VerA cannot execute is still a construct the LRM
    /// states rules ABOUT — §4.5.15 bars an analog operator from an `initial`
    /// block, §4.7.3 bars an analog function call from outside the analog
    /// context, §5.2.1 bars a digital value from an `analog initial` block,
    /// §7.2.2 bars a variable from being assigned in both contexts — and while
    /// the keyword was a hard syntax error not one of those four could ever
    /// fire. A modeller writing `initial x = ddt(V(p,n));` was told the block was
    /// unsupported and never told the expression was illegal in it.
    fn reportItem(self: *Parser, tok: u32) Error!void {
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        try self.bag.add(.parse, .E0205, span, "found {s}", .{self.found(tok)});
    }

    /// A.4.1 `pass_switchtype pass_switch_instance { , pass_switch_instance } ;`
    /// with `pass_switchtype ::= tran | rtran` and `pass_switch_instance ::=
    /// [ name_of_gate_instance ] ( inout_terminal , inout_terminal )` — no
    /// strength and no delay, which is why this is the one gate family with a
    /// production here and not E0205.
    ///
    /// ACCEPTED AND NOT MODELLED, OUT LOUD (W0250). §8.5.3.5 puts switch
    /// processing in the discrete simulation cycle: a pass switch propagates
    /// LOGIC values and strengths between its terminals, so there is no equation
    /// for a compiled analog device to stamp, and inventing one — a zero-volt
    /// source between the terminals, say — would pin a convention the LRM does
    /// not state instead of a requirement. Dropping it silently is the other
    /// wrong answer: a module whose two nets a switch was meant to tie stamps as
    /// if the switch were absent. So the instance is parsed, the terminals are
    /// checked to be net references, and the warning says the connection carries
    /// nothing. `--deny=W0250` turns it into a refusal for a model that cannot
    /// afford the omission.
    // ponytail: nothing is recorded, because nothing consumes it. The upgrade
    // path is the same one §7.6 insertion needs — a digital half in `Flatten` —
    // and until that exists an AST field would only be dead weight.
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
    fn parseGates(self: *Parser, b: *Body) Error!void {
        try self.gateNotModelled();
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
            else => unreachable, // the caller dispatched on exactly these
        };
        self.pos += 1;
        // Unlike `assign`, a `(` here is ambiguous: A.3.1 makes the instance
        // NAME optional, so `and (w, a, b);` opens a terminal list with the
        // same token A.2.2.2's drive strength opens. The word inside settles
        // it — A.2.2.2's alternatives all begin with a strength keyword, and no
        // terminal can, since those spellings are reserved words.
        var s0: Ast.Strength = .strong;
        var s1: Ast.Strength = .strong;
        if (self.peek() == .lparen and self.strengthWord(self.pos + 1) != null) try self.parseDriveStrength(&s0, &s1);
        const delay: Ast.Delay3 = if (self.peek() == .hash) try self.parseDelay3() else .{};
        while (true) {
            const tok = self.pos;
            // A.3.1 makes `name_of_gate_instance` optional; `(` after the name
            // tells the two apart, as in `parsePassSwitch`.
            if (self.identLike(self.pos)) self.pos += 1;
            _ = try self.expect(.lparen);
            var terms: std.ArrayList(Ast.ExprId) = .empty;
            while (true) {
                try terms.append(self.arena, try self.parseExpr());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
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
                        }, .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                },
                // A.3.1 `( output_terminal , input_terminal , enable_terminal )`
                .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
                    if (terms.items.len != 3) return self.failAt(tok, .E0209, "an enable gate takes an output, a data input and an enable", .{});
                    try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                },
                // A.3.1 `( output_terminal , input_terminal { , input_terminal } )`
                else => {
                    if (terms.items.len < 3) return self.failAt(tok, .E0209, "an n-input gate takes an output and at least two inputs", .{});
                    try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                },
            }
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
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
    fn gateNotModelled(self: *Parser) Error!void {
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
    /// modelled by nothing (W0252).
    fn parsePullGate(self: *Parser) Error!void {
        try self.gateNotModelled();
        // A.3.2's `strength0`/`strength1` name the side the gate pulls toward:
        // 0 for `pulldown`, 1 for `pullup`, which is also `StrengthWord.side`.
        const side: u8 = if (self.reservedIs(self.pos, "pulldown")) 0 else 1;
        self.pos += 1;
        if (self.peek() == .lparen and self.strengthWord(self.pos + 1) != null) {
            const tok = self.pos + 1;
            if (self.peekAt(2) == .comma) {
                var s0: Ast.Strength = .strong;
                var s1: Ast.Strength = .strong;
                try self.parseDriveStrength(&s0, &s1);
            } else {
                self.pos += 1;
                const w = self.strengthWord(self.pos).?;
                self.pos += 1;
                _ = try self.expect(.rparen);
                if (w.side != side) return self.failAt(
                    tok,
                    .E0207,
                    "a single-strength bracket on this gate is A.3.2's `( strength{d} )`",
                    .{side},
                );
            }
        }
        while (true) {
            // A.3.1 makes `name_of_gate_instance` optional here too; `(` after
            // the name tells the two apart, as in `parseGates`.
            if (self.identLike(self.pos)) self.pos += 1;
            _ = try self.expect(.lparen);
            _ = try self.parseNetRef(); // A.3.3 output_terminal ::= net_lvalue
            _ = try self.expect(.rparen);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    fn parsePassSwitch(self: *Parser) Error!void {
        if (self.digital) return self.failAt(self.pos, .E1100, "switch primitives are not implemented by digital execution", .{});
        const main_tok = self.pos;
        self.pos += 1;
        try self.bag.add(
            .parse,
            .W0250,
            lexer.tokenSpan(self.src, self.starts, main_tok),
            "{s} switch primitive",
            .{self.found(main_tok)},
        );
        while (true) {
            // A.4.1 makes the instance name optional, and the fixture's `tran
            // (a, b);` uses that arm. `(` after the name tells the two apart.
            if (self.identLike(self.pos)) self.pos += 1;
            _ = try self.expect(.lparen);
            _ = try self.parseNetRef();
            _ = try self.expect(.comma);
            _ = try self.parseNetRef();
            _ = try self.expect(.rparen);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    /// A.6.2 `initial_construct ::= initial statement` /
    /// `always_construct ::= always statement` — §7.2.2's DISCRETE context.
    ///
    /// Shared statements retain the analog device pipeline's restrictions by
    /// default. Digital mode adds delay/NBA syntax and leaves execution support
    /// checks to the source runner. This keeps unsupported source explicit while
    /// preserving analog context checks in Lower.checkDiscreteContext.
    fn parseDiscrete(self: *Parser, b: *Body) Error!void {
        const main_tok = self.pos;
        const is_always = self.peek() == .kw_always;
        self.pos += 1;
        if (is_always and !self.in_connect_module and !self.digital) try self.reportItem(main_tok);
        const body = try self.parseStmtNoNull();
        try b.discrete.append(self.arena, .{
            .is_always = is_always,
            .body = body,
            .main_tok = main_tok,
        });
    }

    // -----------------------------------------------------------------------
    // A.4.2 generate constructs — LRM §6.6
    //
    // A generate construct is turned into ONE `Ast.AnalogBlock` whose body is
    // the `for`/`if` statement, with the generated blocks spliced in as
    // statements. That is not a shortcut around elaboration, it is where
    // elaboration already lives: `Lower.tryUnrollFor` unrolls a genvar `for` at
    // compile time with the genvar bound as a constant for the duration of each
    // copy — §6.6.1's implicit localparam, "whose value is the genvar value at
    // the time the instance was elaborated" — and a constant `if` is folded the
    // same way. §6.9.1 is what makes the splice faithful rather than merely
    // convenient: every analog block in a module is concatenated in source
    // order anyway, and unrolling order is source order, so a generated block
    // occupies exactly the slot it would have occupied written out by hand.
    // -----------------------------------------------------------------------

    /// Enter/leave one generate CONSTRUCT. `gen_construct` is bumped only on the
    /// outermost one, and that is what makes §6.6.2's two naming rules one test:
    /// "it is permissible for more than one block within a single conditional
    /// generate construct to have the same name (since at most one is
    /// instantiated)" — those arms share the id — while "named generate blocks
    /// may not have the same name as blocks in any other generate construct in
    /// the same scope" gets a different one. §6.6.2's direct-nesting exception
    /// falls out too: an `else if` chain is an if_generate_construct nested in
    /// the outer construct's block, so it inherits the id rather than starting
    /// a new one.
    fn parseGenerate(self: *Parser, b: *Body, comptime kind: token.Tag) Error!void {
        if (self.gen_construct_depth == 0) self.gen_construct += 1;
        self.gen_construct_depth += 1;
        self.gen_depth += 1;
        defer {
            self.gen_construct_depth -= 1;
            self.gen_depth -= 1;
        }
        const tok = self.pos;
        const s = switch (kind) {
            .kw_for => try self.parseFor(b, tok),
            .kw_if => try self.parseIf(b, tok),
            .kw_case => try self.parseCase(.normal, b),
            else => unreachable,
        };
        try b.analog.append(self.arena, .{ .body = s, .main_tok = tok });
    }

    /// Syntax 6-8 `loop_generate_construct ::= for ( genvar_initialization ;
    /// genvar_expression ; genvar_iteration ) generate_block`.
    ///
    /// The three parts are the same shape as §5.9.2's `for`, and the same node
    /// carries them: lowering tells the two apart by looking the loop variable
    /// up in `ModuleDecl.genvars` (§3.5), not by which parser produced it. That
    /// is also why the non-constant scheme diagnostics (E0417 init, E0418
    /// condition, E0419 iteration, E0420 non-terminating) need nothing here —
    /// and why the §6.6 scheme rule the if/case forms carry (E0428) does not
    /// apply to this node: for a `for` it is those four codes instead.
    /// `gen` is either a module Body pointer or comptime null for a statement.
    /// Inline specialization shares the grammar without a runtime dispatch.
    inline fn parseFor(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
        self.pos += 1; // 'for'
        _ = try self.expect(.lparen);
        const init_s = try self.parseAssignNoSemi();
        _ = try self.expect(.semicolon);
        const cond = try self.parseExpr();
        _ = try self.expect(.semicolon);
        const step = try self.parseAssignNoSemi();
        _ = try self.expect(.rparen);
        const body = if (@TypeOf(gen) == @TypeOf(null)) try self.parseStmt() else try self.parseGenerateBlock(gen);
        return self.file.addStmt(self.arena, .{ .for_stmt = .{
            .init = init_s,
            .cond = cond,
            .step = step,
            .body = body,
        } }, tok);
    }

    /// Syntax 6-8 `if_generate_construct ::= if ( constant_expression )
    /// generate_block [ else generate_block ]`.
    ///
    /// `else if` needs no arm of its own: an if_generate_construct is itself a
    /// module_or_generate_item, so the chain is a one-item generate_block in
    /// the `else`, which `parseGenerateBlock` reaches through `parseModuleItem`.
    inline fn parseIf(self: *Parser, gen: anytype, tok: u32) Error!Ast.StmtId {
        self.pos += 1; // 'if'
        _ = try self.expect(.lparen);
        const cond = try self.parseExpr();
        _ = try self.expect(.rparen);
        const then_s = if (@TypeOf(gen) == @TypeOf(null)) try self.parseStmt() else try self.parseGenerateBlock(gen);
        const else_s: Ast.StmtId = if (self.eat(.kw_else))
            if (@TypeOf(gen) == @TypeOf(null)) try self.parseStmt() else try self.parseGenerateBlock(gen)
        else
            .none;
        return self.file.addStmt(
            self.arena,
            .{
                .if_stmt = .{
                    .cond = cond,
                    .then_s = then_s,
                    .else_s = else_s,
                    // §6.6's "all expressions in generate schemes shall be constant
                    // expressions" is judged in lowering (E0428), which is the only
                    // stage that can evaluate one.
                    .is_generate = @TypeOf(gen) != @TypeOf(null),
                },
            },
            tok,
        );
    }

    /// Syntax 6-8 `generate_block ::= module_or_generate_item | begin
    /// [ : generate_block_identifier ] { module_or_generate_item } end`.
    ///
    /// The items are collected into a scratch `Body` and then split by what
    /// scope they belong to. §6.6 gives the block its own scope, so its
    /// parameters and variables become the `SeqBlock`'s — which is also what
    /// the old statement-shaped parse produced, so nothing that already
    /// depended on them moves. Everything else (nets, branches, genvars,
    /// analog functions) is hoisted to the module.
    ///
    /// ponytail: hoisting is right for a conditional generate, which elaborates
    /// at most once, and short of the LRM for a loop generate, which should get
    /// one renamed copy of each declaration per iteration (§6.6.1 names them
    /// `blk[0].n`). No fixture declares a net inside a loop; the day one does,
    /// the copies have to be made in `Lower.tryUnrollFor` where the trip count
    /// is known, not here where it is not.
    fn parseGenerateBlock(self: *Parser, b: *Body) Error!Ast.StmtId {
        const tok = self.pos;
        // A.4.2 has no null generate_block, but `if (c) ;` is what a model
        // writes for a deliberately empty arm and refusing it would only move
        // the error off the rule the source actually breaks.
        if (self.eat(.semicolon)) return self.file.addStmt(self.arena, .empty, tok);

        var blk: Ast.SeqBlock = .{};
        var gb: Body = .{};
        if (self.eat(.kw_begin)) {
            if (self.eat(.colon)) {
                const name_tok = self.pos;
                blk.name = try self.expectIdent();
                // §6.6.1: "If the generate block is named, IT IS A DECLARATION
                // OF AN ARRAY of generate block instances"; §6.6.2: "its name
                // declares a generate block instance and is the name for the
                // scope it creates". Either way the identifier lands in the
                // ENCLOSING scope, and `checkGenBlockNames` is what enforces it.
                try b.gen_blocks.append(self.arena, .{
                    .name = blk.name,
                    .tok = name_tok,
                    .construct = self.gen_construct,
                });
            }
            while (self.peek() != .kw_end and self.peek() != .eof) {
                try self.skipAttributes();
                if (self.peek() == .kw_end) break;
                const before = self.pos;
                self.parseModuleItem(&gb) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    self.recoverStatement(before);
                };
            }
            _ = try self.expect(.kw_end);
        } else {
            try self.skipAttributes();
            try self.parseModuleItem(&gb);
        }

        var body: std.ArrayList(Ast.StmtId) = .empty;
        // ponytail: `analog initial` (§5.2.1) inside a generate block is
        // spliced onto the ordinary spine like any other analog construct, so
        // it loses its initialization-only scheduling. Give `Ast.SeqBlock` an
        // is_initial statement, or hand the block back to `b.analog`, when a
        // model needs one — neither is free, and nothing asks yet.
        for (gb.analog.items) |ab| try body.append(self.arena, ab.body);
        blk.params = gb.params.items;
        blk.vars = gb.vars.items;
        blk.body = body.items;

        try b.ports.appendSlice(self.arena, gb.ports.items);
        try b.aliasparams.appendSlice(self.arena, gb.aliasparams.items);
        try b.nets.appendSlice(self.arena, gb.nets.items);
        try b.branches.appendSlice(self.arena, gb.branches.items);
        // §6.6.1 an instance inside a generate construct is an instance of the
        // module: §6.6 gives the region no scope, and the unroll already named
        // the block. It rides up with the nets for the same reason they do.
        try b.instances.appendSlice(self.arena, gb.instances.items);
        // §6.3.1 the same reasoning: a defparam names its target by a path that
        // does not mention the generate block (VerA has no generate scope), so
        // it means the same thing at module level.
        try b.defparams.appendSlice(self.arena, gb.defparams.items);
        try b.genvars.appendSlice(self.arena, gb.genvars.items);
        try b.functions.appendSlice(self.arena, gb.functions.items);
        // §6.6 gives a generate block no scope, so an `initial`/`always` inside
        // one is in the module's discrete context (§7.2.2) and its body's rules
        // are the module's. It has already been refused at its own token.
        try b.discrete.appendSlice(self.arena, gb.discrete.items);
        // A nested generate construct's block names are declarations of the
        // scope they sit in and this one is not it — §6.6.2's rule is about "the
        // same scope", and VerA has no generate scope to hold them, so they ride
        // up to the module with the nets. That is what makes the §6.6.2
        // direct-nesting permission work: `construct` already says which
        // construct each came from.
        try b.gen_blocks.appendSlice(self.arena, gb.gen_blocks.items);
        return self.file.addStmt(self.arena, .{ .block = blk }, tok);
    }

    /// §6.6.1/§6.6.2/§6.8: a named generate block's name is a DECLARATION in
    /// the enclosing scope — "it shall be an error if the name of a generate
    /// block instance array conflicts with any other declaration, including any
    /// other generate block instance array" (§6.6.1), "named generate blocks may
    /// not have the same name as any other declaration in the same scope … or as
    /// blocks in any other generate construct in the same scope, EVEN IF NOT
    /// SELECTED FOR INSTANTIATION" (§6.6.2). §6.8 states the general rule and
    /// adds that it applies "regardless of whether the generate block is
    /// instantiated", which is why nothing here consults the scheme.
    ///
    /// Run once at the end of the module, not at the `begin : name` itself: a
    /// declaration may follow the generate construct in the text, and the clause
    /// is about one SCOPE, not about source order.
    ///
    /// Diagnosed and carried on (`catch {}`, like the E0222 width check) so that
    /// a second, unrelated mistake in the same module is still reported;
    /// `self.failed` is what refuses the file.
    ///
    /// ponytail: two named blocks collide only across different OUTERMOST
    /// constructs. §6.6.2 permits arms of one conditional construct to share a
    /// name and extends that through direct nesting, and `gen_construct` keys on
    /// the root of the nest — so a loop generate nested inside one arm is let off
    /// as well, which the clause does not license. Key on the construct itself
    /// rather than its root the day a fixture asks; that needs generate blocks to
    /// be real scope objects, which is also what §6.6.3 hierarchical names want.
    fn checkGenBlockNames(self: *Parser, b: *Body) void {
        for (b.gen_blocks.items, 0..) |g, i| {
            // Every ordinary declaration space of the module. A port is listed
            // as well as a net: §6.5's header names are declarations too.
            // ponytail: stdlib membership over interned IDs; index declarations
            // if large modules make these linear scans hot.
            const clash = nameIn(Ast.Port, b.ports.items, g.name) or
                nameIn(Ast.ParamDecl, b.params.items, g.name) or
                nameIn(Ast.VarDecl, b.vars.items, g.name) or
                nameIn(Ast.NetDecl, b.nets.items, g.name) or
                nameIn(Ast.BranchDecl, b.branches.items, g.name) or
                nameIn(Ast.FuncDecl, b.functions.items, g.name) or
                std.mem.indexOfScalar(Ast.StrId, b.genvars.items, g.name) != null or
                alias: {
                    // §3.4.6 an aliasparam's own identifier is a declaration.
                    for (b.aliasparams.items) |a| if (a.alias == g.name) break :alias true;
                    break :alias false;
                } or
                other: {
                    for (b.gen_blocks.items[0..i]) |h| {
                        if (h.name == g.name and h.construct != g.construct) break :other true;
                    }
                    break :other false;
                };
            if (clash) _ = self.failAt(g.tok, .E0230, "`{s}`", .{
                self.file.strings.get(g.name),
            }) catch {};
        }
    }

    /// Is `name` the name of one of `decls`? One helper for eight declaration
    /// slices, which all carry a `.name: StrId` — and a StrId comparison is a
    /// name comparison because §2.8 identifiers are interned.
    fn nameIn(comptime T: type, decls: []const T, name: Ast.StrId) bool {
        for (decls) |d| if (d.name == name) return true;
        return false;
    }

    /// §6.5.2 body port declaration: it re-declares a header port's direction
    /// and discipline, it does not introduce a new terminal.
    fn parsePortDecl(self: *Parser, b: *Body) Error!void {
        const dir = portDirection(self.peek());
        self.pos += 1;
        const disc = try self.optDiscipline();
        // A.2.1.2's two VARIABLE arms, which only `output` has:
        //
        //     output_declaration ::=
        //         output [ discipline_identifier ] [ net_type | wreal ] [ signed ]
        //             [ range ] list_of_port_identifiers
        //       | output [ discipline_identifier ] reg [ signed ] [ range ]
        //             list_of_variable_port_identifiers
        //       | output output_variable_type list_of_variable_port_identifiers
        //     output_variable_type ::= integer | time
        //
        // `optDiscipline` above has already eaten the `[ net_type ]` of the
        // first arm and the `[ signed ]` all three share, so the only thing
        // left to tell the arms apart is this keyword. The port is then a
        // VARIABLE and not a net — §6.5.2 calls it a port type declaration —
        // which is why the name list gets a `VarDecl` below as well as the
        // direction, and why the `[ = constant_expression ]` of
        // `list_of_variable_port_identifiers` (A.2.3) is read here and nowhere
        // else in this function.
        const var_storage: ?@FieldType(Ast.VarDecl, "storage") = switch (self.peek()) {
            .kw_integer => .variable, // A.2.2.1 output_variable_type
            .kw_time => .time, // …its other alternative
            .kw_reg => .reg, // A.2.1.2's second arm
            else => null,
        };
        if (var_storage != null) {
            if (dir != .output) return self.failAt(
                self.pos,
                .E0207,
                "found {s}: A.2.1.2 gives a variable type to `output` only",
                .{self.found(self.pos)},
            );
            self.pos += 1;
            _ = self.eat(.kw_signed);
        }
        // A.2.1.2 `inout [ range ] list_of_port_identifiers ;` — §6.5.2.2's
        // "port direction declaration", the half of the clause that carries
        // the direction. Its range is compared against the port TYPE
        // declaration's in lowering, so it lands in its own field.
        const range: ?Ast.Dim = if (self.peek() == .lbracket) try self.parseDim() else null;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            if (var_storage) |storage| {
                // A.2.3 `list_of_variable_port_identifiers ::= port_identifier
                // [ = constant_expression ] { , … }` — the initializer slot the
                // net arms do not have.
                const init_expr: Ast.ExprId = if (self.eat(.assign_eq)) try self.parseExpr() else .none;
                try b.vars.append(self.arena, .{
                    .name = name,
                    // Both arms are integral: A.2.2.1's `output_variable_type`
                    // is `integer | time`, and §3.4.1 folds `time` to the same
                    // representation VerA gives an `integer`; Table 7-1 does
                    // the same for a `reg`'s bits.
                    .ty = .integer,
                    .init = init_expr,
                    .storage = storage,
                    .packed_range = range,
                    .main_tok = tok,
                });
            }
            if (findPort(b, name)) |p| {
                // §6.2 "Ports declared in the list of port declarations shall
                // not be redeclared within the body of the module." A direction
                // is what a `list_of_port_declarations` header carries and a
                // bare `list_of_ports` header cannot (Syntax 6-1), so a port
                // that already has one was declared already — in the ANSI
                // header, or by an earlier body declaration (§6.8's duplicate).
                if (p.direction != .unspecified) {
                    _ = self.failAt(tok, .E0218, "`{s}`", .{self.file.str(name)}) catch {};
                } else {
                    p.direction = dir;
                    if (disc != .none) p.discipline = disc;
                    if (range != null) p.range = range;
                }
            } else {
                _ = self.failAt(tok, .E0206, "`{s}`", .{self.file.str(name)}) catch {};
            }
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

    fn findPort(b: *Body, name: Ast.StrId) ?*Ast.Port {
        for (b.ports.items) |*p| if (p.name == name) return p;
        return null;
    }

    /// A.2.1.3 `list_of_net_identifiers ;` (§3.6.3). A net that names a header
    /// port binds the discipline to that port instead of declaring a new net,
    /// so lowering sees one object per terminal.
    ///
    /// §3.6.3 Syntax 3-6 puts the vector range between the discipline and the
    /// names — `electrical [3:0] p, q;` — so it is parsed here, once, and
    /// sticks to every name in the list.
    ///
    /// A `net_decl_assignment` (`electrical n = 5.0;`) parses here too — see the
    /// §3.6.3.2 note at the `assign_eq` arm below for what happens to the value.
    /// §6.7 a hierarchical name in a DECLARATION position, interned as ONE
    /// string with the source's own `.` between the parts.
    ///
    /// That join is the whole mechanism, and it is deliberate: `Elaborate.sep`
    /// is the same period, so the string a `defparam` path or an Annex F.2.1
    /// out-of-context declaration writes IS the flat name elaboration gives the
    /// entity it names. Neither needs a path walk, and neither needs a second
    /// representation. A name with no dot in it interns exactly as it did
    /// before, so the ordinary declaration paths are untouched.
    ///
    /// The parts are `expectIdent`s, so each has been through `internTok` and no
    /// longer carries a period of its own — which is what lets the join below be
    /// the whole mechanism rather than an approximation of one.
    ///
    /// `allow_index`: A.9.3 `hierarchical_identifier ::= { identifier [ [
    /// constant_expression ] ] . } identifier` — a per-segment index naming ONE
    /// element of a §6.2.2 instance array, legal on every segment but the last
    /// (the production puts it inside the braces, before the `.`). The index is
    /// folded HERE and spelled into the stored text as `[{d}]`, because
    /// elaboration mints instance-array elements under exactly that spelling
    /// (`Flatten.walkInstances`) and the shared representation's whole point is
    /// that a defparam key IS the flat name. A value the fold cannot reach is
    /// E0231 — interned text has no digits for an unevaluated expression.
    ///
    /// The net-declaration caller passes `false`: not because F.2.1's
    /// out-of-context form forbids an index, but because in that position a `[`
    /// after the name is how A.2.1.3's `ams_net_identifier` spells a vector
    /// range, and consuming it as an index would trade one diagnostic for a
    /// wronger one.
    fn parseDottedName(self: *Parser, allow_index: bool) Error!Ast.StrId {
        const first = try self.expectIdent();
        if (self.peek() != .dot and !(allow_index and self.peek() == .lbracket)) return first;
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(self.arena, self.file.str(first));
        while (true) {
            if (allow_index and self.peek() == .lbracket) {
                const tok = self.pos;
                self.pos += 1;
                const idx = try self.parseExpr();
                _ = try self.expect(.rbracket);
                const k = self.constIndex(idx) orelse return self.failAt(tok, .E0231, "", .{});
                var buf: [24]u8 = undefined;
                try joined.appendSlice(self.arena, std.fmt.bufPrint(&buf, "[{d}]", .{k}) catch unreachable);
                // A.9.3 an indexed segment is always followed by `.` — the
                // final identifier of a path carries no index.
                _ = try self.expect(.dot);
            } else if (!self.eat(.dot)) break;
            const part = try self.expectIdent();
            try joined.append(self.arena, '.');
            try joined.appendSlice(self.arena, self.file.str(part));
        }
        return self.file.intern(self.arena, joined.items);
    }

    /// Fold A.9.3's `[ constant_expression ]`: §2.6 integer literals and the
    /// +,-,*,/ arithmetic over them — the same set `Elaborate.constInt` folds
    /// for the instance-array RANGE these indices select from. Not parameter
    /// reads: the parameter table is elaboration's, and a value not in hand
    /// here cannot be spelled into interned text.
    fn constIndex(self: *Parser, e: Ast.ExprId) ?i64 {
        if (e == .none) return null;
        const x = &self.file.exprs;
        return switch (x.tag(e)) {
            .int_literal => x.intValue(e),
            .unary => blk: {
                const v = self.constIndex(x.lhs(e)) orelse break :blk null;
                break :blk switch (x.unOp(e)) {
                    .plus => v,
                    .minus => -v,
                    else => null,
                };
            },
            .binary => blk: {
                const l = self.constIndex(x.lhs(e)) orelse break :blk null;
                const r = self.constIndex(x.rhs(e)) orelse break :blk null;
                break :blk switch (x.binOp(e)) {
                    .add => l + r,
                    .sub => l - r,
                    .mul => l * r,
                    .div => if (r == 0) null else @divTrunc(l, r),
                    else => null,
                };
            },
            else => null,
        };
    }

    /// A.2.2.1 net_type keyword -> `Ast.NetKind`. Anything else is `.wire`,
    /// which is what a declaration naming no net type resolves as (§7.9).
    fn netKind(tag: token.Tag) Ast.NetKind {
        return switch (tag) {
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
            else => .wire,
        };
    }

    /// A.2.2.2, one keyword: its IEEE 1364-2005 clause 7 level and which of the
    /// production's two sides it may occupy. `strength0 ::= supply0 | strong0 |
    /// pull0 | weak0` and its `highz0` partner are the 0 side; the `1` spellings
    /// are the 1 side. `small`/`medium`/`large` are a `charge_strength`, a
    /// DIFFERENT production that appears only in A.2.1.3's `trireg`
    /// alternatives, so they are listed here to be recognised and refused — a
    /// parser that accepted any parenthesised strength after any net type would
    /// make `wire (small) w;` legal, and A.2.2.1 has no such derivation.
    const StrengthWord = struct { level: Ast.Strength, side: u8 };
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

    /// The eight drive strengths lex as `.kw_reserved` except `supply0`/
    /// `supply1`, which are also A.2.2.1 net types and so carry their own tags.
    /// Both paths end at the spelling, which is what A.2.2.2 is written in.
    fn strengthWord(self: *const Parser, i: u32) ?StrengthWord {
        return switch (self.tags[i]) {
            .kw_reserved, .kw_supply0, .kw_supply1 => strength_words.get(self.tokenText(i)),
            else => null,
        };
    }

    /// A.2.2.2 `drive_strength`, whose six alternatives all say the same thing:
    /// one 0-side spec and one 1-side spec, in either order. The caller has seen
    /// the `(` and decided it cannot begin anything else.
    fn parseDriveStrength(self: *Parser, s0: *Ast.Strength, s1: *Ast.Strength) Error!void {
        _ = try self.expect(.lparen);
        const first_tok = self.pos;
        const a = self.strengthWord(self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
        self.pos += 1;
        _ = try self.expect(.comma);
        const b = self.strengthWord(self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
        self.pos += 1;
        _ = try self.expect(.rparen);
        // `(strong0, pull0)` is derivable from no alternative of A.2.2.2, and
        // is exactly what an implementation that lexed two strength keywords
        // and took a maximum would wave through.
        if (a.side == b.side or a.side == 2 or b.side == 2)
            return self.failAt(first_tok, .E0207, "a drive strength pairs one 0-side with one 1-side strength", .{});
        s0.* = if (a.side == 0) a.level else b.level;
        s1.* = if (a.side == 1) a.level else b.level;
    }

    /// A.2.1.3 gives `trireg` alternatives of its own, and they are the only
    /// ones carrying `charge_strength ::= ( small ) | ( medium ) | ( large )`.
    /// A `drive_strength` on a net DECLARATION is a separate alternative that
    /// nothing in this tree writes, so a parenthesis after any other net type
    /// is refused here rather than read as the other production — which is the
    /// cheap wrong parser that would make `wire (small) w;` legal.
    fn parseChargeStrength(self: *Parser, kind: Ast.NetKind) Error!Ast.Strength {
        _ = try self.expect(.lparen);
        const tok = self.pos;
        const w = self.strengthWord(self.pos) orelse return self.failAt(tok, .E0207, "found {s}, which is not a charge strength", .{self.found(tok)});
        self.pos += 1;
        _ = try self.expect(.rparen);
        if (kind != .trireg or w.side != 2)
            return self.failAt(tok, .E0207, "a charge strength is only legal on a trireg", .{});
        return w.level;
    }

    /// A.2.2.3 `delay3 ::= # delay_value | # ( delay_value [ , delay_value
    /// [ , delay_value ] ] )`. The cursor is on the `#`.
    ///
    /// One value is all three transitions (IEEE 1364-2005 §7.14). Two leave
    /// `off` unset, because the clause derives it as the SMALLER of the two and
    /// that is arithmetic on the evaluated values, not a syntax node.
    fn parseDelay3(self: *Parser) Error!Ast.Delay3 {
        _ = try self.expect(.hash);
        if (!self.eat(.lparen)) {
            const v = try self.parseDelayValue();
            return .{ .rise = v, .fall = v, .off = v };
        }
        var out: Ast.Delay3 = .{};
        out.rise = try self.parseDelayValue();
        out.fall = out.rise;
        out.off = out.rise;
        if (self.eat(.comma)) {
            out.fall = try self.parseDelayValue();
            out.off = if (self.eat(.comma)) try self.parseDelayValue() else .none;
        }
        // A.2.2.3's innermost bracket pair closes after the THIRD value, so
        // from there the only terminal the production admits is `)`. A fourth
        // value is a missing parenthesis, and E0210 is the diagnostic that says
        // so — not E0207's generic "unexpected token", which would send the
        // reader looking for the end of the previous statement.
        if (self.peek() != .rparen) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
        self.pos += 1;
        return out;
    }

    /// A.2.2.3 `delay_value`. `mintypmax_expression` is not admitted: A.2.2.3
    /// spells it `mintypmax_expression` only inside `delay_control`, and the
    /// `:`-separated form has no selector in this compiler to choose from.
    fn parseDelayValue(self: *Parser) Error!Ast.ExprId {
        return self.parseExpr();
    }

    fn parseNetNames(self: *Parser, b: *Body, disc: Ast.StrId, kind: Ast.NetKind, is_ground: bool, st: Ast.NetStrength) Error!void {
        const range: ?Ast.Dim = if (self.peek() == .lbracket) try self.parseDim() else null;
        // A.2.1.3 puts `[ delay3 ]` between the range and the name list, and it
        // belongs to the NET, not to the declaration's optional assignment:
        // `wire #3 y = ~a;` delays y's own transition.
        //
        // NOT gated on `digital`. The bracket used to be an E0207 ("a net delay
        // has no meaning outside a digital design element") outside a `.v`
        // source, which is a verdict on the SEMANTICS written as a refusal of
        // the SYNTAX: §1.1 makes "the complete IEEE Std 1364 Verilog
        // specification" part of Verilog-AMS HDL, and A.2.1.3 grants the
        // bracket to every one of its twelve alternatives. A delay VerA has no
        // discrete kernel to honour is a delay it drops, the way it drops the
        // strength brackets above — silently dropping a timing annotation is
        // what every analog-only tool does with one, and it is not the same
        // claim as "this text is not derivable from the annex".
        const delay: Ast.Delay3 = if (self.peek() == .hash) try self.parseDelay3() else .{};
        while (true) {
            const tok = self.pos;
            // Annex F.2.1 step 3 / §3.10 order 1: an OUT-OF-CONTEXT declaration,
            // which the LRM prints as `electrical top.middle.bottom.sig;` and
            // which "overrides any discipline which may be declared for sig in
            // the module where sig was declared". The dotted name is interned
            // whole; `findPort` below cannot match it, so it lands as a net
            // declaration under its path and elaboration reads it as one.
            const name = try self.parseDottedName(false);
            // §3.6.3.2 / Syntax 3-6 `net_decl_assignment ::= ams_net_identifier =
            // expression` — a NODESET value: "the initializer shall be a
            // constant_expression and will be used as a nodeset value for the
            // potential of the net BY THE ANALOG SOLVER". Not an assignment and
            // not a clamp, so it changes no answer the device computes; it is an
            // initial guess handed to the host's solver. `ground` has no such
            // form (Syntax 3-7 gives it `list_of_net_identifiers`), so the `=`
            // there is still E0207.
            //
            // Carried on `NetDecl.init` and folded by lowering, which is where
            // both of the clause's rules can be judged: "shall be a
            // constant_expression" is E0365 (lowering owns the folder) and
            // "nets of non-continuous disciplines are not [allowed one]" is
            // E0366 (lowering owns the discipline table, and §10.2's default
            // has not been applied yet at this point in the parse).
            const nodeset: Ast.ExprId = if (!is_ground and self.eat(.assign_eq))
                try self.parseExpr()
            else
                .none;
            // Only the FIRST declaration binds. A port that already carries a
            // discipline gets a net entry instead, so lowering sees BOTH
            // declarations and can apply §7.4.4 (E0902) — overwriting here is
            // what used to make the second one invisible. The entry adds no
            // node: internNode finds the port's existing slot by name.
            const port = if (is_ground) null else findPort(b, name);
            if (port != null and port.?.discipline == .none) {
                port.?.discipline = disc;
                // §6.5.2.2: this IS the port type declaration. Recorded beside
                // the direction declaration's range rather than over it — see
                // Ast.Port.type_range.
                port.?.type_range = range;
                // `electrical p = 5.0;` on a header port lands here, and the
                // discipline is all this branch can carry: a Port has no
                // initializer slot. The nodeset gets a net entry of its own
                // with NO discipline — `.none` is what keeps it out of §7.4.4
                // (E0902), and `internNode` with an empty discipline finds the
                // port's slot without overwriting what this branch just bound.
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

    /// LRM §3.12 / A.2.1.3, both arms of `branch_declaration`:
    ///
    ///     branch ( a [, b] )  list_of_branch_identifiers ;
    ///     branch ( < p > )    list_of_branch_identifiers ;   // Syntax 3-9
    ///
    /// The second is the §3.12.1 PORT BRANCH, "a branch between the upper and
    /// lower connections of the port" — the same quantity `I(<p>)` reads, given
    /// a name. It is told from the first by one token, and the `<` is also what
    /// A.8.9's port_probe_function_call uses, so `parseAccess` spells it the
    /// same way.
    ///
    /// A.2.3 puts an optional `[ range ]` on each branch_identifier: a branch
    /// ARRAY, several branches over one terminal pair. The range rides on the
    /// declaration and lowering expands it, because that is where a constant
    /// expression can be folded.
    fn parseBranchDecl(self: *Parser, b: *Body) Error!void {
        self.pos += 1; // 'branch'
        _ = try self.expect(.lparen);
        const is_port_branch = self.eat(.lt);
        const hi = try self.parseNetRef();
        var lo: Ast.ExprId = .none;
        if (is_port_branch) {
            _ = try self.expect(.gt);
        } else if (self.eat(.comma)) {
            lo = try self.parseNetRef();
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
                .range = if (self.peek() == .lbracket) try self.parseDim() else null,
                .main_tok = name_tok,
            });
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.semicolon);
    }

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
        const ty: Ast.Type = switch (self.peek()) {
            .kw_integer, .kw_time => .integer, // §3.4.1: time folds to integer
            .kw_real, .kw_realtime => .real,
            .kw_string => .string,
            else => .unspecified, // §3.4.1 — inferred from the default by lowering
        };
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
            if (ty == .unspecified and self.peek() == .lbracket) try self.parseDim() else null;

        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            const dims = try self.parseDims();
            _ = try self.expect(.assign_eq);
            const default = try self.parseExpr();

            var ranges: std.ArrayList(Ast.ValueRange) = .empty;
            while (self.peek() == .kw_from or self.peek() == .kw_exclude) {
                try ranges.append(self.arena, try self.parseRange());
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
                try names.append(self.arena, try self.internString(tok));
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
            return .{ .kind = kind, .lo = try self.parseValueRangeExpr() };
        }

        const lo_inclusive = self.peek() == .lbracket;
        self.pos += 1;
        const lo = try self.parseValueRangeExpr();
        // `exclude ( expr )` — a parenthesized single value, not a range.
        if (self.peek() != .colon) {
            _ = try self.expect(.rparen);
            return .{ .kind = kind, .lo = lo };
        }
        self.pos += 1;
        const hi = try self.parseValueRangeExpr();
        const hi_inclusive = switch (self.peek()) {
            .rbracket => true,
            .rparen => false,
            else => return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)}),
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
        return self.parseExpr();
    }

    /// A.2.1.3 integer/real/string declaration (§3.2, §3.3). One VarDecl per
    /// name; `variable_type ::= id { dimension } [ = expr ]` (A.2.2.1).
    fn parseVarDecl(self: *Parser, out: *std.ArrayList(Ast.VarDecl)) Error!void {
        const storage: @FieldType(Ast.VarDecl, "storage") = if (self.peek() == .kw_time) .time else .variable;
        const ty: Ast.Type = switch (self.peek()) {
            .kw_integer, .kw_time => .integer,
            .kw_string => .string,
            else => .real, // real, realtime
        };
        self.pos += 1;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            const dims = try self.parseDims();
            var init_expr: Ast.ExprId = .none;
            if (self.eat(.assign_eq)) init_expr = try self.parseExpr();
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

    /// The width of `[msb:lsb]` when both bounds are integer LITERALS.
    ///
    /// ponytail: literals only. Folding `[W-1:0]` needs the constant evaluator,
    /// which lives in lowering.
    fn literalWidth(self: *const Parser, d: Ast.Dim) ?u64 {
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
    fn parseDims(self: *Parser) Error![]const Ast.Dim {
        if (self.peek() != .lbracket) return &.{};
        var dims: std.ArrayList(Ast.Dim) = .empty;
        while (self.peek() == .lbracket)
            try dims.append(self.arena, try self.parseDim());
        return dims.items;
    }

    /// A.2.5 `dimension ::= [ expr : expr ]` (§3.2.2, §3.4.4).
    fn parseDim(self: *Parser) Error!Ast.Dim {
        _ = try self.expect(.lbracket);
        const msb = try self.parseExpr();
        _ = try self.expect(.colon);
        const lsb = try self.parseExpr();
        _ = try self.expect(.rbracket);
        return .{ .msb = msb, .lsb = lsb };
    }

    // -----------------------------------------------------------------------
    // A.2.6 analog_function_declaration — LRM §4.7.1 · A.6.2 analog_construct
    // -----------------------------------------------------------------------

    fn parseAnalog(self: *Parser, b: *Body) Error!void {
        const main_tok = self.pos;
        self.pos += 1; // 'analog'
        if (self.peek() == .kw_function) return self.parseFuncDecl(b, main_tok);
        // §5.2.1 `analog initial analog_function_statement`
        const is_initial = self.eat(.kw_initial);
        const body = try self.parseStmtNoNull(); // A.6.2 takes one analog_statement
        try b.analog.append(self.arena, .{
            .is_initial = is_initial,
            .body = body,
            .main_tok = main_tok,
        });
    }

    /// LRM §4.7.1: `analog function [type] name ; items stmt endfunction`.
    /// Argument types come either from the declaration itself (`input real x;`)
    /// or from a matching variable declaration (`input x; real x;`, A.2.6).
    fn parseFuncDecl(self: *Parser, b: *Body, main_tok: u32) Error!void {
        self.pos += 1; // 'function'
        const ret_ty: Ast.Type = switch (self.peek()) {
            .kw_integer => .integer,
            .kw_real => .real,
            .kw_string => .string,
            else => .real, // §4.7.1 default
        };
        if (self.peek() == .kw_integer or self.peek() == .kw_real or self.peek() == .kw_string) {
            self.pos += 1;
        }
        const name = try self.expectIdent();
        _ = try self.expect(.semicolon);

        var args: std.ArrayList(Ast.FuncArg) = .empty;
        var params: std.ArrayList(Ast.ParamDecl) = .empty;
        var vars: std.ArrayList(Ast.VarDecl) = .empty;
        var body: std.ArrayList(Ast.StmtId) = .empty;

        // §4.7.1's two body restrictions are checked at the syntax that
        // violates them (`begin :` and `return ;`), not by a walk afterwards,
        // so the diagnostic lands on the offending token. Analog functions do
        // not nest — A.2.6 has no analog_function_declaration inside a function
        // body — so a plain save/restore is the whole scope discipline.
        const saved_in_fn = self.in_analog_fn;
        self.in_analog_fn = true;
        defer self.in_analog_fn = saved_in_fn;

        while (true) {
            try self.skipAttributes();
            switch (self.peek()) {
                .eof, .kw_endfunction => break,
                .kw_input, .kw_output, .kw_inout => {
                    const dir = portDirection(self.peek());
                    self.pos += 1;
                    // `input real x;` (A.2.7 task_port_type) or bare `input x;`
                    const ty: Ast.Type = switch (self.peek()) {
                        .kw_integer, .kw_time => .integer,
                        .kw_real, .kw_realtime => .real,
                        .kw_string => .string,
                        else => .unspecified,
                    };
                    if (ty != .unspecified) self.pos += 1 else _ = try self.optDiscipline();
                    // A.2.6 `input_declaration ::= input [ range ] list_of_ports`
                    // — one range, BEFORE the names, shared by all of them.
                    // §4.7.2.3's own example is `output [0:1] out;` and §4.7.1's
                    // Example 3 is `inout [0:1]a;`.
                    const dims = try self.parseDims();
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
                    try self.parseParamDecl(&params);
                    _ = try self.expect(.semicolon);
                },
                .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                    const first = vars.items.len;
                    try self.parseVarDecl(&vars);
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
                else => {
                    const before = self.pos;
                    const s = self.parseStmt() catch |e| {
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
            var d = self.failWith(main_tok, .E0224);
            d.msg("`{s}` has an empty formal list", .{self.file.str(name)});
            try d.emit();
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
                    else => return self.failAt(self.pos, .E0211, "found {s}", .{self.found(self.pos)}),
                };
                self.pos += 1;
            }
        }
        _ = self.eat(.semicolon);

        var attrs: std.ArrayList(Ast.NatureAttr) = .empty;
        while (self.peek() != .kw_endnature and self.peek() != .eof) {
            const attr = try self.parseNatureAttr();
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
    fn parseNatureAttr(self: *Parser) Error!Ast.NatureAttr {
        const tok = self.pos;
        const name: Ast.StrId = switch (self.peek()) {
            .identifier, .escaped_identifier => try self.expectIdent(),
            .kw_abstol, .kw_access, .kw_units, .kw_ddt_nature, .kw_idt_nature => blk: {
                const s = try self.file.intern(self.arena, self.tokenText(self.pos));
                self.pos += 1;
                break :blk s;
            },
            else => return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)}),
        };
        _ = try self.expect(.assign_eq);
        const value = try self.parseExpr();
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
                            .attr = try self.parseNatureAttr(),
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
                        else => return self.failAt(self.pos, .E0212, "found {s}", .{self.found(self.pos)}),
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
                    try attrs.append(self.arena, try self.parseNatureAttr());
                },
                else => return self.failAt(self.pos, .E0213, "found {s}", .{self.found(self.pos)}),
            }
        }
        _ = try self.expect(.kw_enddiscipline);
        d.overrides = overrides.items;
        d.attrs = attrs.items;
        return d;
    }

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
    fn parseStmtNoNull(self: *Parser) Error!Ast.StmtId {
        if (!self.digital and self.peek() == .semicolon)
            _ = self.failAt(self.pos, .E0219, "", .{}) catch {};
        return self.parseStmt();
    }

    /// One analog statement (A.6.4). Digital `initial`/`always`, `fork`/`join`,
    /// `wait` and the procedural continuous assignments are NOT dispatched
    /// here: they fall through to the expression statement and report "expected
    /// expression", which is the annex C answer — they are not analog
    /// statements. `casex`/`casez` ARE dispatched, to `parseCase`, so annex
    /// C.7's own diagnostic (E0416) is what the source dies on.
    pub fn parseStmt(self: *Parser) Error!Ast.StmtId {
        try self.skipAttributes();
        const tok = self.pos;
        if (self.digital and self.eat(.hash)) {
            const delay = if (self.eat(.lparen)) blk: {
                const value = try self.parseExpr();
                _ = try self.expect(.rparen);
                break :blk value;
            } else try self.parsePrimary();
            const body = try self.parseStmt();
            return self.file.addStmt(self.arena, .{ .event_control = .{ .event = delay, .body = body, .kind = .delay } }, tok);
        }
        // A.6.5 `wait_statement ::= wait ( expression ) statement_or_null` —
        // digital only, like `#`: A.6.4 has no analog alternative for it.
        if (self.digital and self.peek() == .kw_wait) {
            self.pos += 1;
            _ = try self.expect(.lparen);
            const cond = try self.parseExpr();
            _ = try self.expect(.rparen);
            const body = try self.parseStmt();
            return self.file.addStmt(self.arena, .{ .event_control = .{ .event = cond, .body = body, .kind = .level } }, tok);
        }
        switch (self.peek()) {
            .semicolon => {
                self.pos += 1;
                return self.file.addStmt(self.arena, .empty, tok);
            },
            .kw_begin => return self.parseSeqBlock(),
            .kw_if => return self.parseIf(null, tok), // §5.8 / A.6.6
            // §5.8.3 / A.6.7. `casex`/`casez` share the production and are
            // refused in lowering by E0416, the code annex C.7 owns.
            .kw_case => return self.parseCase(.normal, null),
            .kw_casex => return self.parseCase(.casex, null),
            .kw_casez => return self.parseCase(.casez, null),
            .kw_for => return self.parseFor(null, tok), // §5.9.2 / A.6.8
            .kw_while => { // §5.9.1
                self.pos += 1;
                _ = try self.expect(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expect(.rparen);
                const body = try self.parseStmt();
                return self.file.addStmt(self.arena, .{ .while_stmt = .{ .cond = cond, .body = body } }, tok);
            },
            .kw_repeat => { // §5.9
                self.pos += 1;
                _ = try self.expect(.lparen);
                const count = try self.parseExpr();
                _ = try self.expect(.rparen);
                const body = try self.parseStmt();
                return self.file.addStmt(self.arena, .{ .repeat_stmt = .{ .count = count, .body = body } }, tok);
            },
            .at => return self.parseEventControl(), // §5.10 / A.6.5
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
                } else try self.parseExpr();
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
            .system_identifier => return self.parseSysTask(),
            else => return self.parseExprOrContributeStmt(),
        }
    }

    /// §5.3.2 / A.6.3 analog_seq_block. Local declarations are only legal on a
    /// named block; accepting them either way costs nothing and keeps the
    /// diagnostic for the real error (an undeclared name) in lowering.
    fn parseSeqBlock(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // 'begin'
        var blk: Ast.SeqBlock = .{};
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
            try self.skipAttributes();
            switch (self.peek()) {
                .kw_parameter, .kw_localparam => {
                    try self.parseParamDecl(&params);
                    _ = try self.expect(.semicolon);
                },
                .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                    try self.parseVarDecl(&vars);
                    _ = try self.expect(.semicolon);
                },
                else => break,
            }
        }

        var body: std.ArrayList(Ast.StmtId) = .empty;
        while (self.peek() != .kw_end and self.peek() != .eof) {
            const before = self.pos;
            // A.6.3 `analog_seq_block ::= begin [ : id ... ] { analog_statement }`
            // — no null alternative, so a stray `;` here is E0219.
            const s = self.parseStmtNoNull() catch |e| {
                if (e == error.OutOfMemory) return e;
                self.recoverStatement(before);
                continue;
            };
            try body.append(self.arena, s);
        }
        _ = try self.expect(.kw_end);

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
    fn parseCase(self: *Parser, kind: Ast.CaseKind, gen: ?*Body) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // 'case' / 'casex' / 'casez'
        _ = try self.expect(.lparen);
        const scrutinee = try self.parseExpr();
        _ = try self.expect(.rparen);

        var arms: std.ArrayList(Ast.CaseArm) = .empty;
        while (self.peek() != .kw_endcase and self.peek() != .eof) {
            try self.skipAttributes();
            var labels: std.ArrayList(Ast.ExprId) = .empty;
            if (self.eat(.kw_default)) {
                _ = self.eat(.colon); // A.6.7: `default [ : ]`
            } else {
                while (true) {
                    try labels.append(self.arena, try self.parseExpr());
                    if (!self.eat(.comma)) break;
                }
                _ = try self.expect(.colon);
            }
            const body = if (gen) |b| try self.parseGenerateBlock(b) else try self.parseStmt();
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
    fn parseEventControl(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        self.pos += 1; // '@'
        // A.6.5 `event_control ::= … | @* | @ (*)`. Both spellings mean the same
        // implicit list, and neither carries an expression at all, so the
        // statement records `.none` — see `Ast.StmtKind.event_control`.
        if (self.peek() == .star) {
            self.pos += 1;
            return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try self.parseStmt() } }, tok);
        }
        const event = if (self.eat(.lparen)) blk: {
            if (self.peek() == .star and self.peekAt(1) == .rparen) {
                self.pos += 2;
                return self.file.addStmt(self.arena, .{ .event_control = .{ .event = .none, .body = try self.parseStmt() } }, tok);
            }
            const e = try self.parseEventExpr();
            _ = try self.expect(.rparen);
            break :blk e;
        } else blk: {
            // `@ hierarchical_event_identifier`
            const id_tok = self.pos;
            const name = try self.expectIdent();
            break :blk try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name });
        };
        const body = try self.parseStmt();
        return self.file.addStmt(self.arena, .{ .event_control = .{ .event = event, .body = body } }, tok);
    }

    /// A.6.5 analog_event_expression — `or` and `,` both build `.event_or`
    /// (§4.2.2 puts them at the `||` precedence level, below everything else).
    fn parseEventExpr(self: *Parser) Error!Ast.ExprId {
        var lhs = try self.parseEventTerm();
        while (self.peek() == .kw_or or self.peek() == .comma) {
            const tok = self.pos;
            self.pos += 1;
            const rhs = try self.parseEventTerm();
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
    fn parseEventTerm(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        // A.6.5 `event_expression ::= … | driver_update expression` — DIGITAL,
        // and it appears in `event_expression`, never in
        // `analog_event_expression`, so it is legal only in the discrete context
        // of a §7.6 connect module (§9.22 paragraph 3). Outside one the keyword
        // falls through to `parseExpr` and is the ordinary "expected an
        // expression" — a keyword is not an identifier (§2.8.2).
        if (self.in_connect_module and self.peek() == .kw_driver_update) {
            self.pos += 1;
            const sig = try self.parseExpr();
            return self.file.exprs.add(self.arena, .{ .tag = .event_driver_update, .main_tok = tok, .lhs = sig });
        }
        // A.6.5 `event_expression ::= posedge expression | negedge expression`
        // — DIGITAL like `driver_update`, but legal in any discrete event
        // expression, not only a connect module's.
        if (self.peek() == .kw_posedge or self.peek() == .kw_negedge) {
            const edge: Ast.ExprTag = if (self.peek() == .kw_posedge) .event_posedge else .event_negedge;
            self.pos += 1;
            const sig = try self.parseExpr();
            return self.file.exprs.add(self.arena, .{ .tag = edge, .main_tok = tok, .lhs = sig });
        }
        const tag: Ast.ExprTag = switch (self.peek()) {
            .kw_initial_step => .event_initial_step,
            .kw_final_step => .event_final_step,
            else => return self.parseExpr(),
        };
        self.pos += 1;
        var names: std.ArrayList(Ast.StrId) = .empty;
        if (self.eat(.lparen)) {
            // A.6.5 makes the analysis list NON-EMPTY and the whole
            // parenthesised group optional, so `final_step()` has no
            // derivation — annex G Table G.2 item 13 says it in prose
            // ("without arguments should not have parenthesis").
            if (self.peek() == .rparen)
                _ = self.failAt(self.pos, .E0220, "after `{s}`", .{@tagName(tag)[6..]}) catch {};
            if (self.peek() != .rparen) while (true) {
                const s = try self.expect(.string_literal);
                try names.append(self.arena, try self.internString(s));
                if (!self.eat(.comma)) break;
            };
            _ = try self.expect(.rparen);
        }
        const off = try self.file.exprs.addStrList(self.arena, names.items);
        return self.file.exprs.add(self.arena, .{ .tag = tag, .main_tok = tok, .extra = off });
    }

    /// A.6.9 `$task [ ( [expr] {, [expr]} ) ] ;` — ch9 system tasks. The name
    /// keeps its `$` so lowering reports it the way the user wrote it.
    fn parseSysTask(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const name = try self.internTok(tok);
        self.pos += 1;
        var args: []const Ast.ExprId = &.{};
        if (self.peek() == .lparen) args = try self.parseCallArgs();
        _ = try self.expect(.semicolon);
        return self.file.addStmt(self.arena, .{ .sys_task = .{ .name = name, .args = args } }, tok);
    }

    /// Contribution vs procedural-assignment disambiguation. LRM §5.6, §5.7.
    /// One expression is parsed first (`<+`, `=` and `:` all bind looser than
    /// every operator in Table 4-3), then the operator decides the statement.
    pub fn parseExprOrContributeStmt(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const lhs = if (self.digital) try self.parsePostfix() else try self.parseExpr();
        if (self.digital and self.eat(.lt_eq)) {
            const timing = try self.parseIntraTiming();
            const value = try self.parseExpr();
            _ = try self.expect(.semicolon);
            return self.file.addStmt(self.arena, .{ .assign = .{
                .target = lhs,
                .value = value,
                .nonblocking = true,
                .timing = timing.expr,
                .timing_is_delay = timing.is_delay,
            } }, tok);
        }
        switch (self.peek()) {
            .contribute => { // §5.6 / A.6.10
                self.pos += 1;
                const rhs = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.file.addStmt(self.arena, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, tok);
            },
            .assign_eq => { // §5.7 / A.6.2
                self.pos += 1;
                const timing = try self.parseIntraTiming();
                const value = try self.parseExpr();
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
                const probe = try self.parsePrimary();
                _ = try self.expect(.eq_eq);
                const eqn = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.file.addStmt(
                    self.arena,
                    .{ .indirect = .{ .lhs = lhs, .probe = probe, .eqn = eqn } },
                    tok,
                );
            },
            else => return self.failAt(self.pos, .E0214, "found {s}", .{self.found(self.pos)}),
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
    fn parseIntraTiming(self: *Parser) Error!struct { expr: Ast.ExprId, is_delay: bool } {
        if (!self.digital) return .{ .expr = .none, .is_delay = false };
        switch (self.peek()) {
            .hash => {
                self.pos += 1;
                if (self.eat(.lparen)) {
                    const value = try self.parseExpr();
                    _ = try self.expect(.rparen);
                    return .{ .expr = value, .is_delay = true };
                }
                return .{ .expr = try self.parsePrimary(), .is_delay = true };
            },
            .at => {
                self.pos += 1;
                if (self.eat(.lparen)) {
                    const e = try self.parseEventExpr();
                    _ = try self.expect(.rparen);
                    return .{ .expr = e, .is_delay = false };
                }
                const id_tok = self.pos;
                const name = try self.expectIdent();
                return .{ .expr = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = id_tok, .str = name }), .is_delay = false };
            },
            else => return .{ .expr = .none, .is_delay = false },
        }
    }

    /// A.6.8 `for` header assignment — an analog_variable_assignment with no
    /// terminating `;`.
    fn parseAssignNoSemi(self: *Parser) Error!Ast.StmtId {
        const tok = self.pos;
        const target = try self.parseExpr();
        _ = try self.expect(.assign_eq);
        const value = try self.parseExpr();
        return self.file.addStmt(self.arena, .{ .assign = .{ .target = target, .value = value } }, tok);
    }

    // -----------------------------------------------------------------------
    // A.8.3 expressions — LRM §4.1, §4.2 (precedence climbing)
    // -----------------------------------------------------------------------

    /// Full expression, conditional operator included. LRM §4.1, §4.2.
    pub fn parseExpr(self: *Parser) Error!Ast.ExprId {
        return self.parseExprPrec(prec_ternary);
    }

    /// Precedence climbing over LRM Table 4-3 (§4.2.2).
    fn parseExprPrec(self: *Parser, min_prec: u8) Error!Ast.ExprId {
        var lhs = try self.parseUnary();
        while (true) {
            const t = self.peek();
            // §4.2.12 conditional — lowest precedence, right associative.
            if (t == .question and min_prec <= prec_ternary) {
                const tok = self.pos;
                self.pos += 1;
                try self.skipAttributes();
                const then_e = try self.parseExpr();
                _ = try self.expect(.colon);
                const else_e = try self.parseExprPrec(prec_ternary);
                lhs = try self.file.exprs.add(self.arena, .{
                    .tag = .ternary,
                    .main_tok = tok,
                    .lhs = lhs,
                    .rhs = then_e,
                    .extra = @intFromEnum(else_e),
                });
                continue;
            }
            const prec = binopPrec(t);
            if (prec == 0 or prec < min_prec) return lhs;
            const tok = self.pos;
            self.pos += 1;
            try self.skipAttributes(); // A.8.3 `binary_operator { attribute_instance }`
            // §4.2.2: "All operators associate left to right with the exception
            // of the conditional operator which associates right to left."
            // There is no `**` carve-out — §4.2.12 names `?:` as the only
            // right-associative operator, and `?:` is handled above, not here.
            // `**` used to be excepted, which made `2**3**2` 512 instead of 64.
            const rhs = try self.parseExprPrec(prec + 1);
            lhs = try self.file.exprs.add(self.arena, .{
                .tag = .binary,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = rhs,
                .extra = @intFromEnum(binOp(t)),
            });
        }
    }

    /// A.8.6 unary_operator (§4.2.1, §4.2.7–§4.2.10). Unary binds tighter than
    /// every binary operator (Table 4-3, top row).
    fn parseUnary(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const op: Ast.UnaryOp = switch (self.peek()) {
            .plus => .plus,
            .minus => .minus,
            .bang => .logical_not,
            .tilde => .bit_not,
            .amp => .reduce_and,
            .tilde_amp => .reduce_nand,
            .pipe => .reduce_or,
            .tilde_pipe => .reduce_nor,
            // §4.2.10 reduction xor. Parsed like its four siblings and refused
            // in LOWERING (E0320, "xor reduction is not in the analog subset"),
            // not here: dying on E0215 "expected an operand" is a recovery
            // artifact that names no rule and would fire for any token that
            // cannot start an operand, so the subset check was never reached.
            .caret => .reduce_xor,
            .tilde_caret, .caret_tilde => .reduce_xnor,
            else => return self.parsePostfix(),
        };
        self.pos += 1;
        try self.skipAttributes(); // A.8.3 `unary_operator { attribute_instance }`
        const operand = try self.parseUnary();
        return self.file.exprs.add(self.arena, .{
            .tag = .unary,
            .main_tok = tok,
            .lhs = operand,
            .extra = @intFromEnum(op),
        });
    }

    /// §3.2.2/§3.4.4 array and part selects: `base[i]`, `base[msb:lsb]`.
    fn parsePostfix(self: *Parser) Error!Ast.ExprId {
        var e = try self.parsePrimary();
        while (self.peek() == .lbracket) {
            const tok = self.pos;
            self.pos += 1;
            var idx = try self.parseExpr();
            if (self.eat(.colon)) { // A.8.3 analog_range_expression
                const lsb = try self.parseExpr();
                idx = try self.file.exprs.add(self.arena, .{
                    .tag = .range,
                    .main_tok = tok,
                    .lhs = idx,
                    .rhs = lsb,
                });
            }
            _ = try self.expect(.rbracket);
            e = try self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = e, .rhs = idx });
        }
        return e;
    }

    /// A.8.4 analog_primary.
    pub fn parsePrimary(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        // §10.6: a keyword the active set does not reserve is just a name, so
        // `sin` under "1364-2005" reads as a variable, not as §4.3.2's builtin.
        // (`tokenText` still switches on the real tag, so the spelling is exact.)
        const t = if (self.identLike(tok)) token.Tag.identifier else self.peek();
        switch (t) {
            .int_literal, .real_literal => return self.parseNumber(),
            .string_literal => { // §2.7
                const s = try self.internString(tok);
                self.pos += 1;
                return self.file.exprs.add(self.arena, .{ .tag = .str_literal, .main_tok = tok, .str = s });
            },
            .lparen => {
                self.pos += 1;
                const e = try self.parseExpr();
                _ = try self.expect(.rparen);
                return e;
            },
            // §4.2.13 / A.8.1 analog_concatenation, analog_multiple_concatenation
            .lbrace => {
                var items: std.ArrayList(Ast.ExprId) = .empty;
                const count = try self.braceOperands(&items);
                if (count) |n| return self.multiConcat(tok, n, items.items);
                if (try self.foldBitConcat(tok, items.items)) |folded| return folded;
                const off = try self.file.exprs.addExprList(self.arena, items.items);
                return self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
            },
            // A.8.1 assignment_pattern `'{ ... }` (§3.4.4 array defaults,
            // §4.5.6 filter coefficient args)
            .apostrophe_lbrace => {
                self.pos += 1;
                var items: std.ArrayList(Ast.ExprId) = .empty;
                if (self.peek() != .rbrace) {
                    const first = try self.parseExpr();
                    // A.8.1's second alternative:
                    //
                    //   assignment_pattern ::= '{ expression { , expression } }
                    //                        | '{ constant_expression
                    //                             { expression { , expression } } }
                    //
                    // one replication filling the WHOLE pattern — §4.2.14's own
                    // `'{ 5{0.0} }`, "a replication operator to repeat 0.0 five
                    // times so that every element of data2 is assigned to 0.0".
                    // There is no production for two replication groups side by
                    // side, so nothing but `}` may follow the inner group. The
                    // inner braces are plain `{`; a `'{` there is a ROW of a
                    // multi-dimensional pattern (§3.4.8) and stays one element.
                    if (self.peek() == .lbrace) {
                        var inner: std.ArrayList(Ast.ExprId) = .empty;
                        try self.braceGroup(&inner);
                        const n = self.replCount(first) orelse
                            return self.failAt(self.file.exprs.mainTok(first), .E0223, "", .{});
                        for (0..n) |_| try items.appendSlice(self.arena, inner.items);
                    } else {
                        try items.append(self.arena, first);
                        while (self.eat(.comma))
                            try items.append(self.arena, try self.parseExpr());
                    }
                }
                _ = try self.expect(.rbrace);
                const off = try self.file.exprs.addExprList(self.arena, items.items);
                return self.file.exprs.add(self.arena, .{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
            },
            .identifier, .escaped_identifier => {
                const text = self.tokenText(tok);
                const name = try self.file.intern(self.arena, text);
                self.pos += 1;
                // §2.9: an attribute_instance "can appear as a suffix to an
                // operator or a Verilog-AMS function name in an expression"
                // (Example 7: `add (* mode = "cla" *) (b, c)`), and A.8.2 puts
                // the slot in the grammar — `analog_function_call ::=
                // analog_function_identifier { attribute_instance } ( ... )`.
                // Only a CALL has that slot, so the skip is rolled back when no
                // `(` follows: a bare name must not swallow an attribute that
                // is a prefix on whatever comes next.
                if (self.peek() == .attr_open) {
                    const before_attrs = self.pos;
                    const attr_mark = self.attrs.items.len;
                    try self.skipAttributes();
                    if (self.peek() != .lparen) {
                        self.pos = before_attrs;
                        // The specs come with the cursor: this instance belongs
                        // to whatever follows and will be collected there.
                        self.attrs.shrinkRetainingCapacity(attr_mark);
                    }
                }
                // §5.5.3 Syntax 5-4 `nature_attribute_reference ::=
                // net_identifier . potential_or_flow . nature_attribute_identifier`
                // — "the attributes for a net or a branch can be accessed by
                // using the hierarchical referencing operator (.) to the
                // potential or flow for the net or branch". `potential` and
                // `flow` are annex B keywords, so this is not the §6.8
                // hierarchical-name spelling; both land in `.hier_ident` all the
                // same, which is that tag's documented job, and lowering tells
                // them apart by resolving the parts.
                if (self.peek() == .dot) {
                    var parts: std.ArrayList(Ast.StrId) = .empty;
                    try parts.append(self.arena, name);
                    while (self.eat(.dot)) {
                        // Syntax 5-4's middle and last parts are annex B
                        // KEYWORDS, not identifiers — `potential`/`flow` on the
                        // one hand and the §3.6.1.2 attribute names on the other
                        // — which is the same list `parseNatureAttr` admits at a
                        // nature declaration, for the same reason.
                        const part = switch (self.peek()) {
                            .kw_potential,
                            .kw_flow,
                            .kw_abstol,
                            .kw_access,
                            .kw_units,
                            .kw_ddt_nature,
                            .kw_idt_nature,
                            => blk: {
                                const s = try self.internTok(self.pos);
                                self.pos += 1;
                                break :blk s;
                            },
                            else => try self.expectIdent(),
                        };
                        try parts.append(self.arena, part);
                    }
                    // §6.7.1, fourth bullet: "Analog user defined functions can
                    // be accessed hierarchically." A dotted name followed by an
                    // argument list is that, and it is a CALL — so it becomes
                    // `.call` under the joined name rather than a `.hier_ident`
                    // nothing could apply arguments to.
                    //
                    // The join is the SOURCE spelling, §6.7's own `.`, and it
                    // coincides with the flat name elaboration gives a child's
                    // function precisely because `Elaborate.sep` is that same
                    // separator for that reason. If the mangling ever stops being
                    // the path, this join and `Lower.flatName` are the two sites.
                    if (self.peek() == .lparen) {
                        var joined: std.ArrayList(u8) = .empty;
                        for (parts.items, 0..) |part, i| {
                            if (i != 0) try joined.append(self.arena, '.');
                            try joined.appendSlice(self.arena, self.file.str(part));
                        }
                        const flat = try self.file.strings.intern(self.arena, joined.items);
                        const args = try self.parseCallArgs();
                        return self.addCall(.call, tok, flat, args);
                    }
                    const off = try self.file.exprs.addStrList(self.arena, parts.items);
                    return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
                }
                if (self.peek() == .lparen) {
                    // §4.4 branch probe vs §4.7 user function: only a declared
                    // nature access name (§3.6.1.4) probes a branch.
                    if (self.access_names.contains(text)) {
                        return self.parseAccess(name, tok);
                    }
                    const args = try self.parseCallArgs();
                    return self.addCall(.call, tok, name, args);
                }
                return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
            },
            // §5.5.1 Syntax 5-3 `nature_access_function ::=
            // nature_attribute_identifier | potential | flow`, and §4.4: "as an
            // alternative to using the access attribute specified in the
            // discipline, the generic potential and flow access functions are
            // also supported". Same production as `V(...)`/`I(...)`, so the
            // same parse — lowering maps the two spellings onto the same
            // `Access` and skips only the §3.6.1.4 NAME match (that is what
            // "generic" means).
            //
            // The two words are annex B keywords, which is why they arrive as
            // their own tags rather than through `access_names` above, and also
            // why §3.13.2's shadowing rule cannot bite here: `real potential;`
            // is a syntax error long before it could take the name away.
            .kw_potential, .kw_flow => {
                const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
                self.pos += 1;
                return self.parseAccess(name, tok);
            },
            // §2.8.3 / A.8.2 analog_system_function_call (ch9). `$name` with no
            // argument list is the same tag with an empty list.
            .system_identifier => {
                const name = try self.internTok(tok);
                self.pos += 1;
                // §6.2.1/§6.7 Syntax 6-9 `hierarchical_identifier ::= [ $root . ]
                // { identifier [ [ constant_expression ] ] . } identifier`.
                // `$root` is the only system name with a `.` after it, and what
                // it does is disambiguate: §6.2.1 "The name $root is used to
                // unambiguously refer to a top-level instance or to an instance
                // path starting from the root of the instantiation tree", where
                // an unprefixed path takes the local scope first. The prefix
                // rides along as part 0 of the path and `Lower.flatName` is where
                // it means something — one site, and it is the site that already
                // knows which module is the root.
                if (self.peek() == .dot) {
                    var parts: std.ArrayList(Ast.StrId) = .empty;
                    try parts.append(self.arena, name);
                    while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
                    const off = try self.file.exprs.addStrList(self.arena, parts.items);
                    return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
                }
                const args: []const Ast.ExprId = if (self.peek() == .lparen)
                    try self.parseCallArgs()
                else
                    &.{};
                return self.addCall(.sys_call, tok, name, args);
            },
            // A.2.5 value_range_expression `inf` (only meaningful in §3.4.2).
            .kw_inf => {
                self.pos += 1;
                return self.file.exprs.add(self.arena, .{ .tag = .pos_inf, .main_tok = tok });
            },
            else => {},
        }

        // Keyword-named calls. The four groups are disjoint by construction
        // (token.zig's annex A.8.2/A.6.5 test) and map 1:1 onto ExprTag.
        const call_tag: Ast.ExprTag = if (token.isMathFunction(t))
            .builtin_call // §4.3
        else if (token.isFilterFunction(t))
            .filter_call // §4.5
        else if (token.isSmallSignalFunction(t))
            .noise_call // §4.6
        else if (token.isEventFunction(t))
            .event_function // §5.10.3
        else if (t == .kw_analysis)
            .sys_call // §4.6.1 analysis_function_call
        else if (t == .kw_initial_step or t == .kw_final_step)
            return self.parseEventTerm() // §5.10.2
        else
            return self.failAt(self.pos, .E0209, "found {s}", .{self.found(self.pos)});

        const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
        self.pos += 1;
        const args = try self.parseCallArgs();
        return self.addCall(call_tag, tok, name, args);
    }

    inline fn addCall(self: *Parser, tag: Ast.ExprTag, tok: u32, name: Ast.StrId, args: []const Ast.ExprId) Error!Ast.ExprId {
        const off = try self.file.exprs.addExprList(self.arena, args);
        return self.file.exprs.add(self.arena, .{
            .tag = tag,
            .main_tok = tok,
            .extra = off,
            .str = name,
        });
    }

    /// §4.4.1 branch_probe_function_call / §4.4.2 port_probe_function_call
    /// (A.8.2). `V(a)`, `V(a,b)`, `I(br)`, `I(<p>)`.
    fn parseAccess(self: *Parser, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
        _ = try self.expect(.lparen);
        if (self.eat(.lt)) { // §5.4.3 port branch `I(<p>)`
            const port = try self.parseNetRef();
            _ = try self.expect(.gt);
            _ = try self.expect(.rparen);
            return self.file.exprs.add(self.arena, .{
                .tag = .port_access,
                .main_tok = tok,
                .lhs = port,
                .str = name,
            });
        }
        if (try self.parseHierBranchRef(name, tok)) |e| return e;
        const hi = try self.parseNetRef();
        var lo: Ast.ExprId = .none;
        if (self.eat(.comma)) lo = try self.parseNetRef();
        _ = try self.expect(.rparen);
        return self.file.exprs.add(self.arena, .{
            .tag = .branch_access,
            .main_tok = tok,
            .lhs = hi,
            .rhs = lo,
            .str = name,
        });
    }

    /// A.8.9 / Syntax 5-3 hierarchical_unnamed_branch_reference:
    ///
    ///   hierarchical_inst_identifier.branch ( branch_terminal [ , branch_terminal ] )
    ///
    /// §5.6.8.2's spelling for the branch a CHILD already owns —
    /// `V(top.drv.branch(x,y)) <+ 1.2;` — as against §5.6.8.1's
    /// `V(top.drv.x, top.drv.y)`, which creates a new branch in the module that
    /// writes it. `branch` is a keyword, so the dotted tail `parseNetRef` walks
    /// stops on it; this is the production that owns that token.
    ///
    /// The terminals are rewritten onto the instance path, so `drv.branch(x,y)`
    /// becomes the ordinary terminal pair `drv.x`, `drv.y` and everything
    /// downstream — elaboration's flat naming, the contribution index, codegen —
    /// is unchanged.
    ///
    /// ponytail: that rewrite makes the two spellings ONE branch, which is right
    /// for a flow contribution (§5.6.1.2 sums same-kind contributions to a pair
    /// whichever instance wrote them) and understates §5.6.8.2 for a POTENTIAL
    /// one, where reaching the child's branch should also discard what the child
    /// retained on it. The upgrade is to attribute the contribution to the
    /// child's `Ast.AnalogBlock.unit` instead of the writer's — the same field
    /// `Lower.discardOpposite` and `potentialSourceHere` already key on.
    ///
    /// The `( < port_identifier > )` alternatives of the production are not
    /// parsed: they name the child's §5.4.3 port flow, which is a different
    /// quantity from a node pair, and nothing asks for them yet.
    fn parseHierBranchRef(self: *Parser, name: Ast.StrId, tok: u32) Error!?Ast.ExprId {
        var parts: std.ArrayList(Ast.StrId) = .empty;
        {
            var i = self.pos;
            if (!self.identLike(i)) return null;
            while (self.tags[i + 1] == .dot) : (i += 2) {
                if (self.tags[i + 2] == .kw_branch) {
                    if (self.tags[i + 3] != .lparen) return null;
                    break;
                }
                if (!self.identLike(i + 2)) return null;
            } else return null;
        }
        while (true) {
            try parts.append(self.arena, try self.expectIdent());
            _ = try self.expect(.dot);
            if (self.eat(.kw_branch)) break;
        }
        _ = try self.expect(.lparen);
        const hi = try self.hierTerminal(parts.items, tok);
        var lo: Ast.ExprId = .none;
        if (self.eat(.comma)) lo = try self.hierTerminal(parts.items, tok);
        _ = try self.expect(.rparen);
        _ = try self.expect(.rparen);
        return try self.file.exprs.add(self.arena, .{
            .tag = .branch_access,
            .main_tok = tok,
            .lhs = hi,
            .rhs = lo,
            .str = name,
        });
    }

    /// One `branch_terminal` of the production above, rewritten onto `prefix`.
    fn hierTerminal(self: *Parser, prefix: []const Ast.StrId, tok: u32) Error!Ast.ExprId {
        var parts: std.ArrayList(Ast.StrId) = .empty;
        try parts.appendSlice(self.arena, prefix);
        try parts.append(self.arena, try self.expectIdent());
        while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
        const off = try self.file.exprs.addStrList(self.arena, parts.items);
        return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
    }

    /// A.8.9 / A.2.1.3 branch terminal: a net or branch identifier, optionally
    /// with a §5.5.2 bit select — "the access functions can only be applied to
    /// scalars or individual elements of a vector. The scalar element of a
    /// vector is selected with an index, e.g., V(in[1])".
    ///
    /// The index is any expression: §5.5.2 requires a CONSTANT one, but
    /// "constant" there admits a genvar, which is only constant part-way
    /// through elaboration. Lowering folds it (E0352).
    ///
    /// §6.7.1 also lets a terminal be a HIERARCHICAL name: "potential and flow
    /// access for named and unnamed branches (including port branches) can be
    /// done hierarchically", and §5.5.4's own example probes `V(drv.a)`. Those
    /// land in `.hier_ident`, the same tag `parsePrimary` builds for a dotted
    /// name in a value position, and lowering resolves the path against the
    /// elaborated design.
    ///
    /// §6.7 Syntax 6-9 puts the `$root .` prefix on the SAME production, so a
    /// probe terminal takes it too: `V($root.global_supply.vdd)` is what §7.8.6's
    /// supply-sensitive connect module is written with. It rides along as part 0
    /// of the path, exactly as `parsePrimary` does it for a value position, and
    /// `Lower.flatName` is the one place that strips it.
    ///
    /// ponytail: ordinary and `$root` terminals share the dotted-tail parse.
    /// No index INSIDE a path (`u[0].a`); adding it needs a resolution rule,
    /// and `hier_ident` is already the shape it would use.
    fn parseNetRef(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        const name = if (self.peek() == .system_identifier and self.tags[self.pos + 1] == .dot) blk: {
            const root = try self.internTok(self.pos);
            self.pos += 1;
            break :blk root;
        } else try self.expectIdent();
        if (self.peek() == .dot) {
            var parts: std.ArrayList(Ast.StrId) = .empty;
            try parts.append(self.arena, name);
            while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
            const off = try self.file.exprs.addStrList(self.arena, parts.items);
            return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
        }
        const base = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
        if (self.peek() != .lbracket) return base;
        self.pos += 1;
        const idx = try self.parseExpr();
        _ = try self.expect(.rbracket);
        return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
    }

    /// A.8.2 / A.6.9 argument list. An omitted argument (`f(a, , c)`, and the
    /// empty filter/task slots the grammar allows) becomes `.none`, so lowering
    /// can apply the per-function defaults instead of guessing arity.
    fn parseCallArgs(self: *Parser) Error![]const Ast.ExprId {
        _ = try self.expect(.lparen);
        var items: std.ArrayList(Ast.ExprId) = .empty;
        if (self.peek() != .rparen) {
            while (true) {
                if (self.peek() == .comma or self.peek() == .rparen) {
                    try items.append(self.arena, .none);
                } else {
                    try items.append(self.arena, try self.parseExpr());
                }
                if (!self.eat(.comma)) break;
            }
        }
        _ = try self.expect(.rparen);
        return items.items;
    }

    /// Operator precedence. LRM §4.2.2 Table 4-3, highest binds tightest.
    /// 0 = not a binary operator.
    fn binopPrec(tag: token.Tag) u8 {
        return switch (tag) {
            .star_star => 12,
            .star, .slash, .percent => 11,
            .plus, .minus => 10,
            .lt_lt, .gt_gt, .lt_lt_lt, .gt_gt_gt => 9,
            .lt, .lt_eq, .gt, .gt_eq => 8,
            .eq_eq, .bang_eq, .eq_eq_eq, .bang_eq_eq => 7,
            .amp => 6,
            .caret, .caret_tilde, .tilde_caret => 5,
            .pipe => 4,
            .amp_amp => 3,
            .pipe_pipe => 2,
            else => 0,
        };
    }

    /// §4.2.12 `?:` sits below every binary operator (Table 4-3, last row).
    const prec_ternary: u8 = 1;

    /// A.8.6 binary_operator → `Ast.BinaryOp`. `===`/`!==`/`<<<`/`>>>` are
    /// mapped, not rejected: annex C.5 rejection is lowering's message.
    fn binOp(tag: token.Tag) Ast.BinaryOp {
        return switch (tag) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .star_star => .pow,
            .eq_eq => .eq,
            .bang_eq => .neq,
            .eq_eq_eq => .case_eq,
            .bang_eq_eq => .case_neq,
            .lt => .lt,
            .lt_eq => .le,
            .gt => .gt,
            .gt_eq => .ge,
            .amp_amp => .logical_and,
            .pipe_pipe => .logical_or,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .caret_tilde, .tilde_caret => .bit_xnor,
            .lt_lt => .shl,
            .gt_gt => .shr,
            .lt_lt_lt => .ashl,
            .gt_gt_gt => .ashr,
            else => unreachable,
        };
    }

    // -----------------------------------------------------------------------
    // Literals — LRM §2.6 numbers, §2.7 strings, §2.8 identifiers
    // -----------------------------------------------------------------------

    /// §2.6.1 integer (incl. sized/based) and §2.6.2 real (exponent + SI scale
    /// factor) literals. Values are computed here because the token stream
    /// stores only {tag,start}.
    fn parseNumber(self: *Parser) Error!Ast.ExprId {
        const tok = self.pos;
        self.pos += 1;

        if (self.tags[tok] == .int_literal) {
            const text = self.gluedNumberText(tok);
            const lit = @import("integer.zig").parse(self.arena, text) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.FourStateDigit => self.failAt(tok, .E0130, "invalid mixed decimal digits in `{s}`", .{text}),
                error.MissingBase => self.failAt(tok, .E0131, "`{s}`", .{text}),
                error.MissingDigits => self.failAt(tok, .E0132, "`{s}`", .{text}),
                else => self.failAt(tok, .E0133, "`{s}`", .{text}),
            };
            if (lit.asInt()) |value| {
                defer self.arena.free(lit.planes);
                return self.file.exprs.addIntLiteral(self.arena, tok, .{
                    .value = value,
                    .width = if (lit.sized) lit.width else 0,
                    .signed = lit.signed,
                });
            }
            return self.file.exprs.addLogic(self.arena, tok, lit);
        }

        const text = self.tokenText(tok);
        // §2.6.2 decoding — `_` removal and the Table 2-1 scale factor — lives
        // in `lexer.parseReal` for the same reason §2.6.1 lives in `parseInt`:
        // exactly ONE decoder. The second one here computed `mantissa * scale`,
        // which rounds twice (once for the mantissa, once for the product) and
        // disagreed with the tested decoder on 2376 of the 9990 two-digit
        // scaled literals by 1 ulp. `parseReal` joins the text and rounds once.
        const v = lexer.parseReal(text) catch |e| return switch (e) {
            error.LiteralTooLong => self.failAt(tok, .E0134, "", .{}),
            else => self.failAt(tok, .E0133, "`{s}`", .{text}),
        };
        return self.file.exprs.addReal(self.arena, tok, v);
    }

    /// The span `lexer.parseInt` has to see to name a MALFORMED §2.6.1 second
    /// form — normally just the token, occasionally the token plus the one
    /// glued to it.
    ///
    /// §2.6.1's second form "shall be composed of up to three tokens — an
    /// optional size constant, an apostrophe character (') followed by a base
    /// format character, and the digits". The lexer stops the number exactly
    /// where the clause stops it, so the three forms the clause itself calls
    /// illegal arrive as a well-formed literal plus a separate token: `4' h5`
    /// (no white space is allowed between the apostrophe and the base format),
    /// `8'y11` (`y` is not one of the eight legal base letters) and Example 1's
    /// `4af` ("hexadecimal format requires 'h"). Reporting "expected `;`" about
    /// a form the LRM labels illegal — and offering to insert the semicolon
    /// mid-number — is the wrong message, so when the next token begins
    /// EXACTLY where this one ended, the user wrote one number and the decoder
    /// gets to say which rule it broke.
    ///
    /// Adjacency is the whole test: `4 af` really is two things with an
    /// operator missing between them and keeps that message. `.apostrophe_lbrace`
    /// is deliberately not in the set — `2'{1}` is §4.2.14's assignment
    /// pattern, where the apostrophe is legal and is not a base format.
    fn gluedNumberText(self: *const Parser, tok: u32) []const u8 {
        const text = self.tokenText(tok);
        const start = self.starts[tok];
        const next = self.starts[tok + 1]; // the stream always ends in `.eof`
        if (next != start + text.len) return text;
        switch (self.tags[tok + 1]) {
            // Only when the glued text is spelled ENTIRELY in digits of some
            // base — that is what makes it a number with the base format left
            // out. `1g` is not, and 56_scale_factor_alphabet_rejected.va says
            // exactly why: §2.6.2's scale_factor alphabet has no `g`, so `1g`
            // "is the integer 1 followed by an identifier" and E0207 is the
            // truth about it.
            .identifier => for (self.tokenText(tok + 1)) |c| {
                if (!lexer.isBasedDigit(c, 16)) return text;
            },
            // Only an apostrophe: a stray backtick is the preprocessor's, and
            // gluing it would decode as a four-state digit and say so (E0130).
            .invalid => if (self.src[next] != '\'') return text,
            else => return text,
        }
        return self.src[start .. next + self.tokenText(tok + 1).len];
    }

    /// A.8.1, both brace forms at once:
    ///
    ///     analog_concatenation          ::= { analog_expression
    ///                                         { , analog_expression } }
    ///     analog_multiple_concatenation ::= { constant_expression
    ///                                         analog_concatenation }
    ///
    /// Consumes `{ ... }` at `self.pos` and appends the group's OPERANDS to
    /// `items`, flattened. Returns the replication count when it is not a
    /// literal, in which case `items` holds one unreplicated copy.
    ///
    /// The two forms are told apart by one token of lookahead PAST the first
    /// expression, not two past the `{`: a `{` there opens the inner
    /// concatenation of a replication where a `,` or a `}` ends an ordinary
    /// operand. Two tokens past the `{` is not enough — `{2+1{a}}` is a
    /// replication and `{2+1}` is not. The analog folding path treats an
    /// initial braced group directly as operands. Digital mode parses it as an
    /// expression too, allowing a constant concatenation to be the multiplier.
    ///
    /// The existing analog path flattens for §4.2.13, because the widths a
    /// concatenation joins live only in the token text (see `foldBitConcat`):
    /// `{4{2'b10}}` has to reach the fold as four sized operands and
    /// `{b, {3{a, b}}}` as seven, which is exactly what the clause says each
    /// "yields the same value as". A zero count contributes no operands —
    /// "a replication with a zero replication constant is considered to have a
    /// size of zero and is ignored" — so `{{0{a}}, b}` arrives as `{b}`, legal
    /// precisely because b has positive size.
    ///
    /// A count that is not a literal cannot be unrolled here, and must not be:
    /// §3.3 Table 3-3 allows a nonconstant multiplier when the result is a
    /// string (`{i{"Hi"}}`). That one keeps its `.multi_concat` node and
    /// lowering repeats the string. Digital mode keeps every group and count:
    /// flattening would erase zero-replication legality and operand evaluation.
    fn braceOperands(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!?Ast.ExprId {
        _ = try self.expect(.lbrace);
        if (self.eat(.rbrace)) return null;

        if (self.digital or self.peek() != .lbrace) {
            const first = try self.parseExpr();
            if (self.peek() == .lbrace) {
                var inner: std.ArrayList(Ast.ExprId) = .empty;
                try self.braceGroup(&inner);
                _ = try self.expect(.rbrace);
                if (self.digital) {
                    // Preserve the multiplier and grouping: zero replication
                    // still evaluates its operands and has contextual legality.
                    try items.appendSlice(self.arena, inner.items);
                    return first;
                }
                const n = self.replCount(first) orelse {
                    try items.appendSlice(self.arena, inner.items);
                    return first;
                };
                for (0..n) |_| try items.appendSlice(self.arena, inner.items);
                return null;
            }
            try items.append(self.arena, first);
            if (!self.eat(.comma)) {
                _ = try self.expect(.rbrace);
                return null;
            }
        }
        while (true) {
            if (!self.digital and self.peek() == .lbrace) {
                try self.braceGroup(items);
            } else try items.append(self.arena, try self.parseExpr());
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rbrace);
        return null;
    }

    /// `braceOperands` for the positions that cannot pass a count upwards: a
    /// nonconstant replication stays ONE operand instead of being returned.
    fn braceGroup(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!void {
        const at = self.pos;
        var g: std.ArrayList(Ast.ExprId) = .empty;
        if (try self.braceOperands(&g)) |c| {
            try items.append(self.arena, try self.multiConcat(at, c, g.items));
        } else if (self.digital) {
            const off = try self.file.exprs.addExprList(self.arena, g.items);
            try items.append(self.arena, try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = at, .extra = off }));
        } else try items.appendSlice(self.arena, g.items);
    }

    /// `{count{items}}` kept unexpanded for lowering (§3.3's nonconstant
    /// multiplier). `rhs` is the inner `.concat`, exactly as `Ast.ExprTag`
    /// documents the tag.
    fn multiConcat(self: *Parser, tok: u32, count: Ast.ExprId, items: []const Ast.ExprId) Error!Ast.ExprId {
        const off = try self.file.exprs.addExprList(self.arena, items);
        const inner = try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
        return self.file.exprs.add(self.arena, .{ .tag = .multi_concat, .main_tok = tok, .lhs = count, .rhs = inner });
    }

    /// §4.2.13's "non-negative, non-x and non-z constant expression" when it is
    /// a literal — the only constant the parser can evaluate, since parameters
    /// are not folded until lowering.
    ///
    /// A negative count is not reported here: it returns null, the group keeps
    /// its `.multi_concat`, and `lowerConcat` names the rule with the folder in
    /// hand so `{n-5{a}}` gets the same verdict as `{-5{a}}`.
    ///
    /// ponytail: the cap is an unrolling guard, not a rule. 32 bits is the
    /// widest concatenation an `integer` can hold (E0217), so no legal integer
    /// replication comes near it; a string replication past the cap falls to
    /// the same lowering path as a nonconstant one.
    fn replCount(self: *const Parser, e: Ast.ExprId) ?u32 {
        const ex = &self.file.exprs;
        if (ex.tag(e) != .int_literal) return null;
        const v = ex.intValue(e);
        if (v < 0 or v > 4096) return null;
        return @intCast(v);
    }

    /// §4.2.13 integer concatenation. "Unsized constant numbers shall not be
    /// allowed in concatenations. This is because the size of each operand in
    /// the concatenation is needed to calculate the complete size" — so the
    /// operation is only defined for operands that carry a width, and the ONLY
    /// Verilog-A expression that carries one is a §2.6.1 sized constant. (A
    /// variable could not help: §3.2.1 makes `integer` 32 bits, so two of them
    /// already overflow the current result type.) This existing analog fold
    /// retains the result width; digital concatenations stay in the AST.
    ///
    /// Returns null when no operand is sized, which leaves `{a, b}` as a
    /// `.concat` node for the paths that (mis)use brace lists for §4.5.11
    /// filter coefficients and §3.2.2 array assignment, and for the §3.3
    /// Table 3-3 string form that lowering folds.
    fn foldBitConcat(self: *Parser, tok: u32, items: []const Ast.ExprId) Error!?Ast.ExprId {
        if (self.digital) return null;
        const ex = &self.file.exprs;
        var any_sized = false;
        for (items) |it| {
            if (ex.tag(it) == .logic_literal) return null;
            if (ex.tag(it) != .int_literal) continue;
            if (ex.intLiteral(it).width != 0) any_sized = true;
        }
        if (!any_sized) return null;

        var acc: u64 = 0;
        var total: u64 = 0;
        for (items) |it| {
            const lit: ?lexer.IntLiteral = if (ex.tag(it) == .int_literal and ex.intLiteral(it).width != 0)
                ex.intLiteral(it)
            else
                null;
            const l = lit orelse {
                var d = self.failWith(ex.mainTok(it), .E0216);
                d.help("give the operand a width, e.g. `8'd5`", .{});
                try d.emit();
                return error.ParseError;
            };
            total += l.width;
            // §3.2.1: the result is an integer, which is 32-bit. Wrapping it
            // silently would corrupt the value, so it is diagnosed.
            if (total > 32) return self.failAt(tok, .E0217, "at least {d} bits wide", .{total});
            const mask: u64 = (@as(u64, 1) << @intCast(l.width)) - 1;
            acc = (acc << @intCast(l.width)) | (@as(u64, @bitCast(l.value)) & mask);
        }
        return try ex.addIntLiteral(self.arena, tok, .{ .value = @bitCast(acc), .width = @intCast(total), .signed = false });
    }

    /// §2.7 string literal contents, with escapes processed, then §3.3's
    /// literal→string conversion applied. Only allocates when the literal
    /// actually contains a backslash.
    ///
    /// The escape decode is `lexer.stringContents` and not a copy of it: a
    /// second decoder here is what left `\ddd` (§2.7 Table 2-2) undecoded on
    /// the live path, so `"\0"` became the character `0` while the lexer's
    /// tested decoder had it right all along.
    fn internString(self: *Parser, tok: u32) Error!Ast.StrId {
        const raw = self.tokenText(tok);
        const body = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            return self.file.intern(self.arena, body);
        }
        const decoded = try lexer.stringContents(self.arena, raw);
        // Direct display formats retain octal NUL bytes (§9.4.2). Digital
        // string-variable conversion is not part of this executor yet.
        if (self.digital) return self.file.intern(self.arena, decoded);
        // §3.3 spells the conversion out in three steps: "all the \0 characters
        // are ignored", an empty remainder becomes the empty string, otherwise
        // the rest is kept — so `"hello\0world"` is `helloworld`, NOT a
        // C-style truncation at the NUL. Compacting in place is that rule.
        var n: usize = 0;
        for (decoded) |c| {
            if (c == 0) continue;
            decoded[n] = c;
            n += 1;
        }
        return self.file.intern(self.arena, decoded[0..n]);
    }

    /// Source text of a token. `token.Stored` has no length (DOD: recompute,
    /// don't store), so the lexeme is re-scanned from `start` — by the LEXER,
    /// which is what makes it exact: `lexer.tokenEnd` re-runs `next()`, and
    /// `next()` is a pure function of (src, pos) (see lexer.zig's header).
    ///
    /// A parser-side copy of the scanners used to live here and it had drifted:
    /// its escaped-identifier arm stopped at white space, where §2.8.1 and
    /// `lexer.lexEscapedIdentifier` stop at any byte outside printable ASCII
    /// 33–126 — so a non-ASCII byte (a UTF-8 comment character pasted into a
    /// name) ended the identifier for the lexer and not for the parser, and the
    /// two disagreed about where the next token began.
    fn tokenText(self: *const Parser, i: u32) []const u8 {
        const lx: lexer.Lexer = .{ .src = self.src };
        const text = lx.tokenText(self.starts[i]);
        // §2.8.1: the `\` opens the identifier but is not part of the name.
        // The terminator is not in the span, so only the head is stripped.
        return if (self.tags[i] == .escaped_identifier) text[1..] else text;
    }

    // -----------------------------------------------------------------------
    // Token access — LRM §2.2 (the stream), §2.8 (identifiers)
    // -----------------------------------------------------------------------

    fn peek(self: *const Parser) token.Tag {
        return self.tags[self.pos];
    }

    fn peekAt(self: *const Parser, n: u32) token.Tag {
        const i = self.pos + n;
        return self.tags[@min(i, self.tags.len - 1)];
    }

    fn eat(self: *Parser, t: token.Tag) bool {
        if (self.peek() != t) return false;
        self.pos += 1;
        return true;
    }

    /// Byte just past the previous token: where a missing terminator has to be
    /// typed, and so where `expect`'s machine-applicable insertion is anchored.
    ///
    /// `token.Stored` carries no length (DOD: recompute, don't store), so the
    /// lexeme is measured. Two tags need care: `tokenText` strips the `\` of an
    /// escaped identifier from the NAME though it is part of the source span,
    /// and `.eof` has no text at all.
    fn endOfPrev(self: *const Parser) u32 {
        if (self.pos == 0) return self.starts[0];
        const i = self.pos - 1;
        if (self.tags[i] == .eof) return self.starts[i];
        const backslash: u32 = @intFromBool(self.tags[i] == .escaped_identifier);
        return self.starts[i] + backslash + @as(u32, @intCast(self.tokenText(i).len));
    }

    fn expect(self: *Parser, t: token.Tag) Error!u32 {
        if (self.peek() != t) {
            // The title is only "unexpected token", so the caret carries what
            // the grammar wanted here.
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected {s}", .{tagDesc(t)});
            // A missing TERMINATOR is never missing where it is reported: the
            // previous construct ended, nobody wrote the token, and the caret
            // lands on whatever came next — often on the following line. E0207's
            // own `--explain` says so ("look at the end of the previous
            // statement first"); the machine-applicable fix says it in the one
            // place a reader is already looking, and points at the column where
            // the character has to be typed.
            if (isTerminator(t)) if (token.Tag.lexeme(t)) |text| {
                const at = self.endOfPrev();
                d.suggest(
                    .{ .span = .{ .start = at, .end = at }, .replacement = text },
                    "insert `{s}` after the previous {s}",
                    .{ text, if (t == .semicolon) "statement" else "item" },
                );
            };
            try d.emit();
            return error.ParseError;
        }
        const i = self.pos;
        self.pos += 1;
        return i;
    }

    /// Can the token at `i` stand where the grammar wants an identifier?
    ///
    /// §2.8/§2.8.1 identifiers always can. So can a KEYWORD that the active
    /// §10.6 keyword set does not reserve: "the version_specifier specifies
    /// the valid set of reserved keywords in effect when a design unit is
    /// parsed", and §10.6's worked example turns exactly on this — under
    /// `begin_keywords "1364-2005", `input sin;` is "OK since sin is not a
    /// keyword in 1364-2005". §10.6 also says the directive does "not affect
    /// the … tokens", which is why this is a parser rule and not a lexer one:
    /// `analog` stays `kw_analog` in the very same module.
    ///
    /// Escaped identifiers (§2.8.1) never reach `keyword_map` in the first
    /// place, so nothing is applied to them twice.
    fn identLike(self: *const Parser, i: u32) bool {
        const j = @min(i, self.tags.len - 1);
        return switch (self.tags[j]) {
            .identifier, .escaped_identifier => true,
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != token.default_keyword_set and
                token.isKeyword(t) and
                !token.isReserved(self.tokenText(j), self.kw_set),
        };
    }

    /// §2.8/§2.8.1 identifier or escaped identifier, interned.
    fn expectIdent(self: *Parser) Error!Ast.StrId {
        if (!self.identLike(self.pos))
            return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)});
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// Intern a token's text as a NAME — and the one place §2.8.1 is normalized
    /// away, which is why the period substitution belongs here and nowhere else.
    ///
    /// `tokenText` already drops the leading backslash because it is not part of
    /// the name. The other thing an escaped identifier smuggles into a name is a
    /// PERIOD: §2.8.1 ends the identifier at white space and admits every
    /// printable character before it, so `\x.y ` is the identifier `x.y`. That
    /// collides head-on with `Elaborate.sep`, which is a period, and four places
    /// downstream read a period as a path separator without being able to check
    /// — `Elaborate.isOoc` (a dot means an Annex F.2.1 out-of-context
    /// declaration), `parseDottedName`'s join, `Flatten.join`, `Lower.flatName`.
    /// Left raw, `\x.y` declared inside instance `u` flattens to `u.x.y`, the
    /// same string as net `y` inside instance `x` inside `u`: two nets, one node,
    /// silently.
    ///
    /// A SPACE is the substitute because §2.8.1's own terminator is white space:
    /// it is the one byte that cannot already be inside an identifier, which
    /// makes the substitution injective — no unescaped name can be mistaken for
    /// an escaped one. `naming.sanitize` turns it into `Z20` before it reaches
    /// the emitted `U`. What it costs is readability, in exactly the case that
    /// was previously wrong and nowhere else: a name with no period is interned
    /// byte-for-byte as before, with no allocation.
    ///
    /// After this point, a period in a name means "path separator", full stop.
    fn internTok(self: *Parser, i: u32) Error!Ast.StrId {
        // The two bytes are spelled out rather than imported from `ir/`, for the
        // same reason `parseDottedName`'s `.` is: the frontend owns the source
        // half of a two-sided convention and does not depend on the IR.
        const text = self.tokenText(i);
        if (self.tags[i] != .escaped_identifier) return self.file.intern(self.arena, text);
        if (std.mem.indexOfScalar(u8, text, '.') == null)
            return self.file.intern(self.arena, text);
        const buf = try self.arena.dupe(u8, text);
        std.mem.replaceScalar(u8, buf, '.', ' ');
        return self.file.intern(self.arena, buf);
    }

    /// §2.9 Syntax 2-4 / A.9.1:
    ///
    ///     attribute_instance ::= (* attr_spec { , attr_spec } *)
    ///     attr_spec          ::= attr_name [ = constant_expression ]
    ///
    /// Every spec is COLLECTED, into `self.attrs`, which `parseModule` hands to
    /// the enclosing module. Nothing downstream reads an attribute's value — the
    /// list exists so §2.9's "constant_expression" and §2.9.2's value domains can
    /// be checked at all, and both are properties of the attr_spec alone, so the
    /// item it decorated does not have to be recorded with it.
    ///
    /// It used to be a token scan, which is why it is still named for skipping:
    /// the caller's cursor lands past the instance either way, and 14 call sites
    /// depend on that. The value is now a real `parseExpr`, so a malformed one is
    /// a diagnostic where it used to be silently swallowed.
    fn skipAttributes(self: *Parser) error{OutOfMemory}!void {
        self.parseAttributes() catch |e| {
            // OOM is never recoverable — swallowing
            // it here would resume parsing with whatever half-built state the
            // allocator refused to finish.
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // A parse error inside an attribute has already been reported. The
            // cursor is resynchronized to the closing `*)` so ONE bad attribute
            // does not turn the decorated declaration into a second diagnostic.
            while (true) : (self.pos += 1) switch (self.peek()) {
                .eof => return,
                .attr_close => {
                    self.pos += 1;
                    return;
                },
                else => {},
            };
        };
    }

    fn parseAttributes(self: *Parser) Error!void {
        while (self.peek() == .attr_open) {
            // §2.9: "Nesting of attribute instances is disallowed. It shall be
            // illegal to specify the value of an attribute with a constant
            // expression that contains an attribute instance." Checked HERE
            // because an attribute value is a full `parseExpr`, and A.8.3 gives
            // an operator its own `{ attribute_instance }` slot — so without this
            // counter `(* outer = (1 + (* inner *) 2) *)` would parse cleanly, the
            // inner instance being legal in every position but this one.
            if (self.attr_depth != 0) {
                var d = self.failWith(self.pos, .E0357);
                d.msg("the value contains an attribute instance", .{});
                d.note("§2.9: \"Nesting of attribute instances is disallowed\"", .{});
                try d.emit();
                return error.ParseError;
            }
            self.pos += 1;
            self.attr_depth += 1;
            defer self.attr_depth -= 1;
            while (true) {
                const tok = self.pos;
                // `attr_name ::= identifier`, but §2.9.2's own `units` is an
                // annex B keyword and so arrives as one (`kw_units`) — the same
                // collision `parseNatureAttr` handles. In this position no
                // keyword can be anything else, so every keyword is a name.
                if (!self.identLike(tok) and !token.isKeyword(self.peek()))
                    return self.failAt(tok, .E0208, "found {s}", .{self.found(tok)});
                const name = try self.internTok(tok);
                self.pos += 1;
                // "[ = constant_expression ]" — §2.9's own default: "If the
                // value is not specified, then ... the default value is 1."
                const value: Ast.ExprId = if (self.eat(.assign_eq))
                    try self.parseExpr()
                else
                    .none;
                try self.attrs.append(self.arena, .{ .name = name, .value = value, .main_tok = tok });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.attr_close);
        }
    }

    /// Resynchronize after a bad statement or module item: past the next `;`,
    /// or up to a keyword that closes the enclosing construct.
    inline fn recoverStatement(self: *Parser, before: u32) void {
        if (self.pos == before) self.pos += 1;
        while (true) : (self.pos += 1) switch (self.peek()) {
            .eof,
            .kw_end,
            .kw_endmodule,
            .kw_endfunction,
            .kw_endgenerate,
            .kw_endcase,
            .kw_endnature,
            .kw_enddiscipline,
            .kw_analog,
            => return,
            .semicolon => {
                self.pos += 1;
                return;
            },
            else => {},
        };
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    fn failAt(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        self.failed = true;
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        if (tok < self.tags.len and self.tags[tok] == .invalid) {
            if (try self.failRunawayString(span)) return error.ParseError;
        }
        try self.bag.add(.parse, code, span, fmt, args);
        return error.ParseError;
    }

    /// §2.7: a string that runs off its line reaches the parser as one
    /// `.invalid` token, and whichever context happens to catch it says only
    /// "found invalid token" — naming neither the rule nor the fix. Handled in
    /// the funnel rather than at the `.E0209` call site because the same token
    /// is equally reachable from statement and module-item position.
    /// Returns true when it emitted; the classification lives in
    /// `lexer.stringRunaway`.
    fn failRunawayString(self: *Parser, span: diag.Span) Error!bool {
        const kind = lexer.stringRunaway(self.src, span);
        if (kind == .none) return false;

        var d = self.bag.build(.parse, .E0138, span);
        d.point("this literal is still open at the end of the line", .{});
        if (kind == .line_continuation) {
            d.note(
                "the trailing `\\` is an IEEE 1800 SystemVerilog continuation (§5.9); " ++
                    "Verilog-AMS derives from IEEE 1364-2005, which has no such escape",
                .{},
            );
        }
        d.help("keep the literal on one line — `\\n` inside it is what breaks the output", .{});
        try d.emit();
        return true;
    }

    /// Same diagnostic, opened for a label / note / suggestion. The call site
    /// still has to `return error.ParseError` after `emit`.
    fn failWith(self: *Parser, tok: u32, code: diag.Code) diag.Builder {
        self.failed = true;
        return self.bag.build(.parse, code, lexer.tokenSpan(self.src, self.starts, tok));
    }

    /// Human name of the token at `i`, for the "found ..." half of a message.
    fn found(self: *const Parser, i: u32) []const u8 {
        return switch (self.tags[i]) {
            .eof => "end of file",
            .invalid => "invalid token",
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            .kw_reserved,
            => self.tokenText(i),
            else => |t| tagDesc(t),
        };
    }
};

/// Name of an expected token in a diagnostic.
///
/// Punctuation is spelled as the CHARACTER the user has to type, in backticks:
/// "expected `)`" is a repair instruction, "expected r_paren" is a puzzle about
/// our `token.Tag` field names. The categories that have no fixed spelling stay
/// prose. `token.Tag.lexeme` is the single source for every spelling, so an
/// operator added there needs no entry here.
fn tagDesc(t: token.Tag) []const u8 {
    return switch (t) {
        .eof => "end of file",
        .invalid => "invalid token",
        .identifier, .escaped_identifier => "an identifier",
        .system_identifier => "a system task or function name",
        .int_literal => "an integer literal",
        .real_literal => "a real literal",
        .string_literal => "a string literal",
        .kw_reserved => "a reserved keyword",
        else => token.Tag.quoted(t) orelse @tagName(t),
    };
}

/// Tokens that CLOSE something: when one is missing, the place to type it is
/// the end of the construct before it, not the token the parser choked on.
/// Drives the machine-applicable insertion in `expect`.
fn isTerminator(t: token.Tag) bool {
    return switch (t) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Self-check. The REAL lexer drives the real parser, so the check exercises the
// grammar against the token stream the engine actually produces. A throwaway
// second lexer lived here and its own comment admitted it was weaker — no §2.6.1
// based numbers, no §2.7 strings, no §10.6 directives — so every test that
// needed one of those had to opt into a second entry point.
// ---------------------------------------------------------------------------

const TestResult = struct {
    file: Ast.SourceFile,
    bag: *diag.Bag,

    fn count(self: TestResult) usize {
        return self.bag.count();
    }

    fn code(self: TestResult, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: TestResult, i: usize) []const u8 {
        return self.bag.at(i).message;
    }
};

fn newBag(arena: std.mem.Allocator, src: []const u8) !*diag.Bag {
    const bag = try arena.create(diag.Bag);
    bag.* = diag.Bag.init(arena);
    try bag.setSingleFile("test.va", src, 0);
    return bag;
}

fn parseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    var list = try lexer.Lexer.tokenize(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

test "§10.6 begin_keywords picks which annex B words are reserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // LRM §10.6 worked example: `sin` is a port name under 1364-2005. Note the
    // module body still uses `analog` — a VAMS-only annex B keyword — because
    // §10.6 changes reserving, not tokens.
    const ok =
        \\`begin_keywords "1364-2005"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\  electrical sin, n;
        \\  analog I(sin,n) <+ V(sin,n) + sin;
        \\endmodule
        \\`end_keywords
    ;
    const a = try parseForTest(arena, ok);
    try std.testing.expectEqual(@as(usize, 0), a.count());
    try std.testing.expectEqualStrings("sin", a.file.str(a.file.modules[0].ports[0].name));

    // Same code, VAMS keywords: "shall result in an error".
    const bad =
        \\`begin_keywords "VAMS-2023"
        \\module m2(sin, n);
        \\  inout sin, n;
        \\endmodule
        \\`end_keywords
    ;
    const b = try parseForTest(arena, bad);
    try std.testing.expect(b.count() > 0);
    try std.testing.expectEqual(diag.Code.E0208, b.code(0));
    try std.testing.expectEqualStrings("found `sin`", b.msg(0));

    // The set is restored by `end_keywords, so `sin` is reserved again after.
    const c = try parseForTest(arena,
        \\`begin_keywords "1364-1995"
        \\`end_keywords
        \\module m(sin);
        \\endmodule
    );
    try std.testing.expect(c.count() > 0);

    // §10.6: only these five specifiers exist.
    const d = try parseForTest(arena, "`begin_keywords \"1800-2017\"\n`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0135, d.code(0));
    try std.testing.expectEqualStrings("`1800-2017`", d.msg(0));

    // Unbalanced. An open `begin_keywords at end of file is NOT an error:
    // §10.6 scopes the directive "even across source code file boundaries",
    // so the set simply carries on into whatever is compiled next.
    const e = try parseForTest(arena, "`begin_keywords \"VAMS-2.3\"\nmodule m; endmodule\n");
    try std.testing.expectEqual(@as(usize, 0), e.count());
    // The other way round has no such reading.
    const f = try parseForTest(arena, "`end_keywords\n");
    try std.testing.expectEqual(diag.Code.E0136, f.code(0));

    // §10.6: "can only be specified outside of a design element".
    const g = try parseForTest(arena,
        \\module m;
        \\`begin_keywords "1364-2005"
        \\endmodule
        \\`end_keywords
    );
    try std.testing.expectEqual(diag.Code.E0202, g.code(0));
    try std.testing.expectEqualStrings("`begin_keywords inside a module", g.msg(0));
}

test "§2.6.1 based literals decode to the right VALUE, not just to a token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m;
        \\  integer a, b, c, d;
        \\  analog begin
        \\    a = 8'hFFFF;
        \\    b = 4'shf;
        \\    c = 'h837ff;
        \\    d = 16'b0011_0101;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const body = res.file.modules[0].analog[0].body;
    const stmts = switch (res.file.stmt(body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // These are the regression pins: the parser's old private decoder ignored
    // the size (65535) and skipped the `s` designator (15).
    const want = [_]i32{ 255, -1, 0x837ff, 0x35 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a2| a2.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }
}

test "§4.2.13 a sized-constant concatenation joins BITS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4'b1010, 4'b0101};
        \\    b = {1'b1, 3'b101};
        \\    c = {4'shf, 4'b0001};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 0xA5; §4.2.13's own example `{1'b1, 3'b101}` == 4'b1101; and a signed
    // operand contributes its BITS (4'shf is -1, i.e. 1111), not its value.
    const want = [_]i32{ 165, 0b1101, 0xf1 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // "Unsized constant numbers shall not be allowed in concatenations."
    const unsized = try parseForTest(arena, "module m; integer a; analog a = {1'b1, 3}; endmodule");
    try std.testing.expectEqual(diag.Code.E0216, unsized.code(0));
    // §3.2.1: 33 bits does not fit an integer, and must not wrap silently.
    const wide = try parseForTest(arena, "module m; integer a; analog a = {16'h0, 16'h0, 1'b1}; endmodule");
    try std.testing.expectEqual(diag.Code.E0217, wide.code(0));
    try std.testing.expectEqualStrings("at least 33 bits wide", wide.msg(0));
    // A brace list with no sized operand stays a `.concat` (§4.5.11 filter
    // coefficients spell their vector that way).
    const coeffs = try parseForTest(arena, "module m; real a; analog a = laplace_nd(1.0, {1,0}, {1,1}); endmodule");
    try std.testing.expectEqual(@as(usize, 0), coeffs.count());
}

test "§4.2.13 replication unrolls into the operand list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseForTest(arena,
        \\module m;
        \\  integer a, b, c;
        \\  analog begin
        \\    a = {4{2'b10}};
        \\    b = {1'b0, {3{1'b1, 1'b0}}};
        \\    c = {{0{1'b1}}, 4'b0101};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());

    const stmts = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .block => |blk| blk.body,
        else => return error.WrongTag,
    };
    // 4.2.13's own three worked cases: "{4{w}} yields the same value as
    // {w, w, w, w}" (8 bits, 10101010); "{b, {3{a, b}}} yields the same value
    // as {b, a, b, a, b, a, b}" (7 bits, 0101010); and a zero replication
    // "considered to have a size of zero and ignored", leaving 4'b0101 alone.
    const want = [_]i32{ 170, 42, 5 };
    for (stmts, want) |s, expect| {
        const rhs = switch (res.file.stmt(s)) {
            .assign => |a| a.value,
            else => return error.WrongTag,
        };
        try std.testing.expectEqual(expect, res.file.exprs.intValue(rhs));
    }

    // §3.3 Table 3-3: "multiplier ... can be nonconstant" for a string result,
    // so a non-literal count is NOT a parse error — it keeps its node and
    // lowering repeats the string.
    const nonconst = try parseForTest(arena, "module m; integer i; string s; analog s = {i{\"Hi\"}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), nonconst.count());

    // A.8.1's assignment-pattern replication, §4.2.14's own `'{5{0.0}}`, is a
    // different brace and a different meaning: five ELEMENTS, not five copies
    // of a bit pattern.
    const pat = try parseForTest(arena, "module m; parameter real d[0:4] = '{5{0.0}}; endmodule");
    try std.testing.expectEqual(@as(usize, 0), pat.count());
    try std.testing.expectEqual(@as(usize, 5), pat.file.exprs.args(pat.file.modules[0].params[0].default).len);
}

test "a resistor parses into ports, ranged parameters and a contribution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf) exclude 0;
        \\  real g;
        \\  analog begin : body
        \\    g = 1.0 / r;
        \\    if (V(p, n) > 0.0) g = g * 2;
        \\    I(p, n) <+ g * V(p, n) + ddt(V(p, n)) - $temperature;
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.modules.len);

    const m = res.file.modules[0];
    try std.testing.expectEqualStrings("res", res.file.str(m.name));
    try std.testing.expectEqual(@as(usize, 2), m.ports.len);
    try std.testing.expectEqual(Ast.Direction.inout, m.ports[0].direction);
    // `electrical p, n;` binds the discipline to the port, not a second net.
    try std.testing.expectEqualStrings("electrical", res.file.str(m.ports[1].discipline));
    try std.testing.expectEqual(@as(usize, 0), m.nets.len);

    // §3.4.2 ranges must survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 1), m.params.len);
    const p0 = m.params[0];
    try std.testing.expectEqual(Ast.Type.real, p0.ty);
    try std.testing.expectEqual(@as(f64, 1000.0), res.file.exprs.realValue(p0.default));
    try std.testing.expectEqual(@as(usize, 2), p0.ranges.len);
    try std.testing.expect(!p0.ranges[0].lo_inclusive);
    try std.testing.expectEqual(Ast.ExprTag.pos_inf, res.file.exprs.tag(p0.ranges[0].hi));
    try std.testing.expectEqual(Ast.ValueRange.Kind.exclude, p0.ranges[1].kind);

    try std.testing.expectEqual(@as(usize, 1), m.analog.len);
    const blk = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b,
        else => return error.WrongTag,
    };
    try std.testing.expectEqualStrings("body", res.file.str(blk.name));
    try std.testing.expectEqual(@as(usize, 3), blk.body.len);
    const contrib = switch (res.file.stmt(blk.body[2])) {
        .contribute => |c| c,
        else => return error.WrongTag,
    };
    // `I(p,n)` is a branch probe because `I` is a nature access name (§4.4.1).
    try std.testing.expectEqual(Ast.ExprTag.branch_access, res.file.exprs.tag(contrib.lhs));
    // §4.2.2: `a*b + f(x) - $t` parses as `(a*b + f(x)) - $t`.
    try std.testing.expectEqual(Ast.BinaryOp.sub, res.file.exprs.binOp(contrib.rhs));
}

test "A.1.8 connectrules: both item forms land in their typed slots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every optional slot of connect_insertion in one block, plus both
    // resolution targets. The AST shape is asserted here because no fixture
    // can see it: mode/params/overrides have no consumer until an insertion
    // phase exists (Ast.ConnectInsertion says so), so the parse into the
    // right slot is the whole of what there is to pin.
    const src =
        \\connectrules cr;
        \\  connect a2d;
        \\  connect a2d split #(.tt(3.5), .vcc(3.3)) input elec, output dig;
        \\  connect d2a merged elec, dig;
        \\  connect e18, e33 resolveto exclude;
        \\  connect x, y, a resolveto a;
        \\endconnectrules
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.connectrules.len);
    const cr = res.file.connectrules[0];
    try std.testing.expectEqualStrings("cr", res.file.str(cr.name));

    try std.testing.expectEqual(@as(usize, 3), cr.insertions.len);
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.unspecified, cr.insertions[0].mode);
    try std.testing.expectEqual(@as(?Ast.ConnectInsertion.PortOverrides, null), cr.insertions[0].overrides);
    const full = cr.insertions[1];
    try std.testing.expectEqual(Ast.ConnectInsertion.Mode.split, full.mode);
    try std.testing.expectEqual(@as(usize, 2), full.params.len);
    try std.testing.expectEqualStrings("tt", res.file.str(full.params[0].name));
    try std.testing.expectEqual(Ast.Direction.input, full.overrides.?.a_dir);
    try std.testing.expectEqual(Ast.Direction.output, full.overrides.?.b_dir);
    try std.testing.expectEqualStrings("dig", res.file.str(full.overrides.?.b));
    // The undirected override shape keeps both directions unspecified.
    try std.testing.expectEqual(Ast.Direction.unspecified, cr.insertions[2].overrides.?.a_dir);

    try std.testing.expectEqual(@as(usize, 2), cr.resolutions.len);
    try std.testing.expect(cr.resolutions[0].exclude);
    try std.testing.expectEqual(Ast.StrId.none, cr.resolutions[0].resolved);
    try std.testing.expectEqual(@as(usize, 3), cr.resolutions[1].disciplines.len);
    try std.testing.expect(!cr.resolutions[1].exclude);
    try std.testing.expectEqualStrings("a", res.file.str(cr.resolutions[1].resolved));

    // A.1.8's connect_port_overrides admits exactly four direction pairings;
    // `input _, input _` is not one, and `expect` names what the grammar
    // wanted (E0207).
    const bad = try parseForTest(arena,
        \\connectrules crx;
        \\  connect a2d input elec, input dig;
        \\endconnectrules
    );
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
}

test "A.2.5: `from` needs a bracket, and saying so is a diagnostic not an assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bare-expression range belongs to `exclude` alone. This used to be
    // `std.debug.assert(kind == .exclude)` — a panic on a checked build and
    // `unreachable` under ReleaseFast, reached from a source file.
    const bad = try parseForTest(arena, "module m; parameter real g = 1 from 5; endmodule");
    try std.testing.expectEqual(@as(usize, 1), bad.count());
    try std.testing.expectEqual(diag.Code.E0207, bad.code(0));
    try std.testing.expectEqualStrings("expected `(` or `[` — only `exclude` takes a bare value", bad.bag.at(0).point);

    // The sibling that IS in the grammar still parses.
    const ok = try parseForTest(arena, "module m; parameter real g = 1 exclude 5; endmodule");
    try std.testing.expectEqual(@as(usize, 0), ok.count());
}

test "Table 4-3 precedence: ?: is the ONLY right-associative operator (§4.2.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ 1 + 2 * 3 ** 2 ** 3 > 4 ? V(p) : 2 ? 3 : 4;
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    const e = &res.file.exprs;
    const rhs = switch (res.file.stmt(res.file.modules[0].analog[0].body)) {
        .contribute => |c| c.rhs,
        else => return error.WrongTag,
    };
    // `?:` is lowest and right-associative: cond ? V(p) : (2 ? 3 : 4)
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(rhs));
    try std.testing.expectEqual(Ast.ExprTag.ternary, e.tag(e.ternaryElse(rhs)));
    // §4.2.2: "All operators associate left to right with the exception of
    // the conditional operator which associates right to left." So the cond is
    // `(1 + (2 * ((3 ** 2) ** 3))) > 4` — `**` groups on the LEFT like every
    // other binary operator, and the nested pow hangs off `lhs`, not `rhs`.
    // Reading `**` as right-associative (the IEEE 1800 rule, not this one) made
    // `2**3**2` evaluate to 512 where §4.2.2 requires 64.
    const cond = e.lhs(rhs);
    try std.testing.expectEqual(Ast.BinaryOp.gt, e.binOp(cond));
    const add = e.lhs(cond);
    try std.testing.expectEqual(Ast.BinaryOp.add, e.binOp(add));
    const mul = e.rhs(add);
    try std.testing.expectEqual(Ast.BinaryOp.mul, e.binOp(mul));
    const pow = e.rhs(mul);
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(pow));
    try std.testing.expectEqual(Ast.BinaryOp.pow, e.binOp(e.lhs(pow)));
    try std.testing.expectEqual(Ast.ExprTag.int_literal, e.tag(e.rhs(pow)));
}

test "errors are collected with locations and parsing continues" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\module bad(p);
        \\  inout p;
        \\  electrical p;
        \\  child u(p);
        \\  always @(p) x = 1;
        \\  analog I(p) <+ V(p);
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    // `child u(p);` is a §6.2.2 module_instantiation and parses now; only the
    // digital `always` is outside annex C.
    try std.testing.expectEqual(@as(usize, 1), res.count());
    try std.testing.expectEqual(diag.Code.E0205, res.code(0));
    // Backticked now: `always` has its own `kw_always` tag, so the "found ..."
    // half is `Tag.quoted` rather than a slice of the source (see `found`).
    try std.testing.expectEqualStrings("found `always`", res.msg(0));
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].instances.len);

    // The span still points at the offending token, on line 5.
    const idx = try diag.LineIndex.build(arena, src);
    try std.testing.expectEqual(@as(u32, 5), idx.loc(res.bag.at(0).span.start).line);
    // Recovery kept going: the analog block after the bad items still parsed.
    try std.testing.expectEqual(@as(usize, 1), res.file.modules[0].analog.len);
}

test "annex C rejections keep their pinned wording" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { src: []const u8, code: diag.Code, point: []const u8 = "" }{
        // §2.9 "Nesting of attribute instances is disallowed. It shall be illegal
        // to specify the value of an attribute with a constant expression that
        // contains an attribute instance." The outer instance sits in a slot
        // Syntax 2-7 has, and A.8.3 gives the `+` its own attribute slot, so the
        // inner one is refused by this rule and not by the grammar — delete it and
        // the same file parses.
        .{
            .src = "module m(p); inout p; electrical p; (* o = (1 + (* i *) 2) *) parameter real x = 1.0; analog I(p) <+ x; endmodule",
            .code = .E0357,
        },
        // A.1.3 module_parameter_port_list. The header `#(parameter real a = 1)`
        // USED to be this row, pinning that it was unimplemented; it parses now.
        // What A.1.3 still refuses is the SystemVerilog shorthand that drops the
        // `parameter` keyword after the first declaration — Verilog-AMS spells
        // the production `# ( parameter_declaration { , parameter_declaration } )`
        // with no such elision, so a bare type ends the list at the `(`.
        .{ .src = "module m #(real a = 1) (p); endmodule", .code = .E0207, .point = "expected `)`" },
        // A.2.4 net_decl_assignment. §3.6.3 vector nets USED to be this row, then
        // the scalar nodeset spelling was; both parse now (`electrical [3:0] p;`
        // is four nodes, and `electrical p = 5.0;` takes the §3.6.3.2 initializer
        // and drops it). What is left unimplemented in the same production is the
        // clause's BUS form, `electrical [0:4] bus = '{2.3,4.5,,6.0}` — whose
        // "null value in the constant array indicates that no nodeset value is
        // being specified for this element" has no operand for A.8.3 to parse.
        .{
            .src = "module m(p); inout p; electrical [0:4] p = '{2.3,4.5,,6.0}; endmodule",
            .code = .E0209,
            .point = "",
        },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(c.code, res.code(0));
        // E0207's title is only "unexpected token": what was wanted rides on
        // the caret, so that is what the fixtures pin.
        if (c.point.len != 0)
            try std.testing.expectEqualStrings(c.point, res.bag.at(0).point);
    }
}

test "§6.6 generate: what does not nest, what may not be declared, what may share a name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; ";
    // `.code = null` = the parser must accept it. Those rows are the point of the
    // test: every rule here is a rule about POSITION, so the permitted position
    // has to be pinned beside the refused one or the gate is untestable.
    const cases = [_]struct { src: []const u8, code: ?diag.Code }{
        // §6.6 "Generate regions do not nest, and they may only occur directly
        // within a module" — both halves of the sentence, then the legal single
        // region.
        .{ .src = head ++ "generate generate if (1) ; endgenerate endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) begin generate if (1) ; endgenerate end endgenerate endmodule", .code = .E0228 },
        .{ .src = head ++ "generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6 a generate block "may not contain ... parameter declarations".
        // `localparam` in the same position is `module_or_generate_item`'s own
        // alternative, and a `parameter` back at module scope is untouched.
        .{ .src = head ++ "generate if (1) begin parameter real x = 1.0; end endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate parameter real x = 1.0; endgenerate endmodule", .code = .E0229 },
        .{ .src = head ++ "generate if (1) begin localparam real x = 1.0; end endgenerate endmodule", .code = null },
        .{ .src = head ++ "parameter real x = 1.0; generate if (1) ; endgenerate endmodule", .code = null },
        // §6.6.2 "Named generate blocks may not have the same name as any other
        // declaration in the same scope", and §6.6.1 the same for a loop
        // construct's instance array. The declaration may come after.
        .{ .src = head ++ "real g; generate if (1) begin end endgenerate endmodule", .code = null },
        .{ .src = head ++ "real g; generate if (1) begin : g end endgenerate endmodule", .code = .E0230 },
        .{ .src = head ++ "generate if (1) begin : g end endgenerate real g; endmodule", .code = .E0230 },
        .{ .src = head ++ "genvar i; real g; generate for (i=0;i<2;i=i+1) begin : g end endgenerate endmodule", .code = .E0230 },
        // §6.6.2 "... as blocks in any other generate construct in the same
        // scope, EVEN IF NOT SELECTED FOR INSTANTIATION" — hence `if (0)`.
        .{ .src = head ++ "generate if (1) begin : b end if (0) begin : b end endgenerate endmodule", .code = .E0230 },
        // ...against the permission in the preceding bullet: "more than one block
        // within a single conditional generate construct" may share a name, and
        // an `else if` chain is one construct by §6.6.2's direct nesting.
        .{ .src = head ++ "generate if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        .{ .src = head ++ "generate if (1) begin : b end else if (1) begin : b end else begin : b end endgenerate endmodule", .code = null },
        // Syntax 6-8 case_generate_construct: a label list, a `default`, and the
        // arms sharing one name (one construct). Outside a generate it is A.6.7's
        // statement keyword with no module-item production at all — E0205.
        .{ .src = head ++ "generate case (1) 1, 2: begin : b end default: begin : b end endcase endgenerate endmodule", .code = null },
        .{ .src = head ++ "case (1) 1: ; endcase endmodule", .code = .E0205 },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        if (c.code) |code| {
            try std.testing.expect(res.count() > 0);
            try std.testing.expectEqual(code, res.code(0));
        } else {
            try std.testing.expectEqual(@as(usize, 0), res.count());
        }
    }
}

test "4.7.1's bullet list and 4.7.2.2 are checked at the declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const head = "module m(p); inout p; electrical p; analog function real f; ";
    const cases = [_]struct { body: []const u8, code: diag.Code }{
        // "shall have at least one formal argument declared"
        .{ .body = "f = 1.0; endfunction", .code = .E0224 },
        // "all formal arguments shall have an associated block item
        // declaration specifying the data type of the argument" — the
        // direction alone is not one.
        .{ .body = "input x; f = x; endfunction", .code = .E0225 },
        // "shall not use named blocks"
        .{ .body = "input x; real x; begin : b f = x; end endfunction", .code = .E0226 },
        // 4.7.2.2 "shall specify an expression"
        .{ .body = "input x; real x; begin return; end endfunction", .code = .E0227 },
    };
    for (cases) |c| {
        const src = try std.mem.concat(arena, u8, &.{ head, c.body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(c.code, res.code(0));
    }

    // And the legal spellings still are: the type on the direction, the type in
    // a separate block item declaration, an UNNAMED block, and a `return` with
    // an expression. None of these may report anything.
    for ([_][]const u8{
        "input real x; f = x; endfunction",
        "input x; real x; f = x; endfunction",
        "input x; real x; begin f = x; end endfunction",
        "input x; real x; begin return x; end endfunction",
    }) |body| {
        const src = try std.mem.concat(arena, u8, &.{ head, body, " analog I(p) <+ f(1.0); endmodule" });
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "casex/casez and reduction xor PARSE, so lowering owns the annex C rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both used to die here — casex on E0209 "expected an expression" and `^b`
    // on E0215 "expected an operand". Those are recovery artifacts: they name
    // no rule, they fire for any token that cannot start an expression, and
    // they made annex C.7's E0416 and §4.2.10's E0320 unreachable. The grammar
    // is now accepted and the subset check happens where the meaning is known.
    for ([_][]const u8{
        "module m; integer s; analog casex (s) 0: s = 1; endcase endmodule",
        "module m; integer s; analog casez (s) 0: s = 1; endcase endmodule",
        "module m; integer b, q; analog q = ^b; endmodule",
        "module m; integer b, q; analog q = ~^b; endmodule",
    }) |src| {
        const res = try parseForTest(arena, src);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.4 has no null statement outside a conditional, case or event body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // annex G.2.2: the three survivors stay legal, the free-standing `;` does
    // not. `analog ;` is the A.6.2 form of the same mistake.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; analog begin ; I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; analog ; endmodule",
    }) |bad| {
        const res = try parseForTest(arena, bad);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0219, res.code(0));
    }
    for ([_][]const u8{
        "module m(p); inout p; electrical p; integer c; analog begin if (c) ; else I(p) <+ 1.0; end endmodule",
        "module m(p); inout p; electrical p; integer c; analog begin case (c) 0: ; default: I(p) <+ 1.0; endcase end endmodule",
        "module m(p); inout p; electrical p; analog begin @(initial_step) ; I(p) <+ 1.0; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "A.6.5 gives a step event no empty analysis list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try parseForTest(arena, "module m(p); inout p; electrical p; real x; analog begin @(final_step()) x = 0.0; I(p) <+ x; end endmodule");
    try std.testing.expect(bad.count() > 0);
    try std.testing.expectEqual(diag.Code.E0220, bad.code(0));

    // Both legal forms: the bare keyword, and a non-empty list.
    for ([_][]const u8{
        "module m(p); inout p; electrical p; real x; analog begin @(final_step) x = 0.0; I(p) <+ x; end endmodule",
        "module m(p); inout p; electrical p; real x; analog begin @(final_step(\"tran\")) x = 0.0; I(p) <+ x; end endmodule",
    }) |good| {
        const res = try parseForTest(arena, good);
        try std.testing.expectEqual(@as(usize, 0), res.count());
    }
}

test "a missing terminator suggests inserting it after the PREVIOUS token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The caret lands on `end`, one line after the mistake. What makes the
    // message actionable is the fix: a zero-width insertion at the end of the
    // contribution, which is where a person has to type the `;`.
    const src =
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(p, n) <+ V(p, n)
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(diag.Code.E0207, res.code(0));

    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = res.bag.notes(res.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    const fix = notes[0].fix orelse return error.TestExpectedFix;
    try std.testing.expectEqualStrings(";", fix.replacement);
    // Zero width: an insertion, not a replacement.
    try std.testing.expectEqual(fix.span.start, fix.span.end);
    // ...and it is anchored just past `)`, not at the `end` the caret is under.
    try std.testing.expectEqualStrings("V(p, n)", src[fix.span.start - 7 .. fix.span.start]);

    // A terminator is the only shape that earns an insertion: E0208 wants a
    // NAME, and no fix can invent one. The port branch `branch (<p>) b` used to
    // be this example and parses now (§3.12.1); a NUMBER where the
    // list_of_branch_identifiers goes is the same production still wanting a name.
    const named = try parseForTest(arena, "module m(p); inout p; electrical p; branch (p) 7; endmodule");
    try std.testing.expectEqual(diag.Code.E0208, named.code(0));
    try std.testing.expectEqual(@as(u32, 0), named.bag.at(0).n_notes);
}

test "§2.7 a string may not span lines, however it is continued" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The IEEE 1800 §5.9 continuation bsim4va's $strobe uses, and a plain
    // runaway. Both are E0138; only the first earns the SystemVerilog note.
    const cases = [_]struct { src: []const u8, notes: u32 }{
        .{ .src = "module m; analog $strobe(\"a\\\nb\"); endmodule", .notes = 2 },
        .{ .src = "module m; analog $strobe(\"a\nb\"); endmodule", .notes = 1 },
    };
    for (cases) |c| {
        const res = try parseForTest(arena, c.src);
        try std.testing.expect(res.count() > 0);
        try std.testing.expectEqual(diag.Code.E0138, res.code(0));
        try std.testing.expectEqualStrings(
            "this literal is still open at the end of the line",
            res.bag.at(0).point,
        );
        try std.testing.expectEqual(c.notes, res.bag.at(0).n_notes);
    }
}

test "analog functions, events, case and indirect contributions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\nature Voltage;
        \\  units = "V";
        \\  access = Pot;
        \\  abstol = 1e-6;
        \\endnature
        \\discipline el;
        \\  potential Voltage;
        \\  potential.abstol = 1e-9;
        \\  domain continuous;
        \\  max_voltage = 48.0;
        \\enddiscipline
        \\module m(p, n);
        \\  inout p, n;
        \\  el p, n;
        \\  branch (p, n) br;
        \\  real x[0:1];
        \\  integer k;
        \\  analog function real half;
        \\    input v;
        \\    real v;
        \\    half = v / 2.0;
        \\  endfunction
        \\  analog begin
        \\    @(initial_step("dc", "tran")) x[0] = 0.0;
        \\    @(cross(Pot(p, n), +1) or timer(1n, 1n)) x[1] = 1.0;
        \\    for (k = 0; k < 2; k = k + 1) x[0] = x[0] + half(Pot(br));
        \\    case (k)
        \\      0, 1: $strobe("k=%d", k);
        \\      default: ;
        \\    endcase
        \\    Pot(p, n) : Pot(p) == 2.0 * x[0];
        \\  end
        \\endmodule
    ;
    const res = try parseForTest(arena, src);
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 1), res.file.natures.len);
    try std.testing.expectEqual(@as(usize, 1), res.file.disciplines.len);
    const d = res.file.disciplines[0];
    try std.testing.expectEqualStrings("Voltage", res.file.str(d.potential));
    try std.testing.expectEqual(Ast.DisciplineDecl.Domain.continuous, d.domain);
    try std.testing.expectEqual(@as(usize, 1), d.overrides.len);
    // §3.6.2.7 a discipline's user-defined attribute, kept like a nature's.
    try std.testing.expectEqual(@as(usize, 1), d.attrs.len);
    try std.testing.expectEqualStrings("max_voltage", res.file.str(d.attrs[0].name));

    const m = res.file.modules[0];
    try std.testing.expectEqual(@as(usize, 1), m.branches.len);
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
    // `input v; real v;` types the argument and does not leave a local.
    try std.testing.expectEqual(@as(usize, 1), m.functions[0].args.len);
    try std.testing.expectEqual(Ast.Type.real, m.functions[0].args[0].ty);
    try std.testing.expectEqual(@as(usize, 0), m.functions[0].vars.len);

    const body = switch (res.file.stmt(m.analog[0].body)) {
        .block => |b| b.body,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(@as(usize, 5), body.len);
    const ev = switch (res.file.stmt(body[0])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    // §5.10.2: the argument list is analysis-name strings, not expressions.
    try std.testing.expectEqual(Ast.ExprTag.event_initial_step, res.file.exprs.tag(ev));
    try std.testing.expectEqual(@as(usize, 2), res.file.exprs.nameParts(ev).len);
    try std.testing.expectEqualStrings("dc", res.file.str(res.file.exprs.nameParts(ev)[0]));

    const ev2 = switch (res.file.stmt(body[1])) {
        .event_control => |c| c.event,
        else => return error.WrongTag,
    };
    try std.testing.expectEqual(Ast.ExprTag.event_or, res.file.exprs.tag(ev2));
    try std.testing.expectEqual(
        Ast.ExprTag.event_function,
        res.file.exprs.tag(res.file.exprs.lhs(ev2)),
    );
    // §5.6.7 indirect contribution survives parsing (lowering may reject it).
    switch (res.file.stmt(body[4])) {
        .indirect => |ind| try std.testing.expectEqual(
            Ast.ExprTag.branch_access,
            res.file.exprs.tag(ind.probe),
        ),
        else => return error.WrongTag,
    }
}

test "§2.6.1 AST preserves exact digital literals and known literal metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const res = try parseForTest(arena,
        \\module literals;
        \\  integer a, b, c, d;
        \\  initial begin
        \\    a = 85'hz3;
        \\    b = 8'shf;
        \\    c = 128'd18446744073709551617;
        \\    d = 'hx;
        \\    d = {4'b10xz, 4'hf};
        \\  end
        \\endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), res.count());
    try std.testing.expectEqual(@as(usize, 4), res.file.exprs.logic.items.len);
    try std.testing.expectEqual(@as(u32, 85), res.file.exprs.logic.items[0].width);
    try std.testing.expectEqual(@as(u64, 3), res.file.exprs.logic.items[0].values()[0]);
    try std.testing.expectEqual(@as(u32, 128), res.file.exprs.logic.items[1].width);
    try std.testing.expect(!res.file.exprs.logic.items[2].sized);
    try std.testing.expectEqual(@as(u32, 8), res.file.exprs.ints.items[0].width);
    try std.testing.expect(res.file.exprs.ints.items[0].signed);
    var copy: Ast.SourceFile = .empty;
    try copy.seedFrom(arena, &res.file);
    try std.testing.expect(copy.exprs.logic.items[0].planes.ptr != res.file.exprs.logic.items[0].planes.ptr);
    try std.testing.expectEqualSlices(u64, res.file.exprs.logic.items[0].planes, copy.exprs.logic.items[0].planes);
}
