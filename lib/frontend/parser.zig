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
    /// Inside the body of an `initial` or `always` block (§7.2.2's discrete
    /// context). A.6.2/A.6.5 give that body the digital statement forms — a
    /// `#` delay, `wait`, a nonblocking `<=`, an intra-assignment timing
    /// control — in ANY module, analog or not. So those four are admitted by
    /// position here, not by file extension; an `analog` block still has none
    /// of them (A.6.4). See `discreteGrammar`.
    in_discrete: bool = false,
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

    // Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations, A.5 UDPs — parser/source.zig
    const parse_source = @import("parser/source.zig");
    pub const parseSourceFile = parse_source.parseSourceFile;

    // Annex A.1.2 module_declaration and A.1.4 module_item (LRM §6.2, Clause 3) — parser/module.zig
    const parse_module = @import("parser/module.zig");

    // Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1) — parser/specify.zig
    const parse_specify = @import("parser/specify.zig");

    // Annex A.4.2 generate constructs (LRM §6.6) — parser/generate.zig
    const parse_generate = @import("parser/generate.zig");

    // Annex A.2.1.1 parameters (§3.4), A.2.6 analog functions (§4.7.1), A.1.6/A.1.7 natures and disciplines (§3.6) — parser/decl.zig
    const parse_decl = @import("parser/decl.zig");

    // Annex A.6.4 analog_statement (LRM Clause 5) — parser/stmt.zig
    const parse_stmt = @import("parser/stmt.zig");

    // Annex A.8.3 expressions (§4.1, §4.2 precedence climbing), and literals (§2.6 numbers, §2.7 strings, §2.8 identifiers) — parser/expr.zig
    const parse_expr = @import("parser/expr.zig");

    // -----------------------------------------------------------------------
    // Token access — LRM §2.2 (the stream), §2.8 (identifiers)
    // -----------------------------------------------------------------------

    /// The A.6.5 statement forms an analog statement does not have — `#`,
    /// `wait`, `<=`, intra-assignment timing — are grammar here: a digital
    /// source, or the body of an `initial`/`always` block anywhere.
    pub fn discreteGrammar(self: *const Parser) bool {
        return self.digital or self.in_discrete;
    }

    pub fn peek(self: *const Parser) token.Tag {
        return self.tags[self.pos];
    }

    pub fn peekAt(self: *const Parser, n: u32) token.Tag {
        const i = self.pos + n;
        return self.tags[@min(i, self.tags.len - 1)];
    }

    pub fn eat(self: *Parser, t: token.Tag) bool {
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
        return self.starts[i] + backslash + @as(u32, @intCast(parse_expr.tokenText(self, i).len));
    }

    pub fn expect(self: *Parser, t: token.Tag) Error!u32 {
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
    pub fn identLike(self: *const Parser, i: u32) bool {
        const j = @min(i, self.tags.len - 1);
        return switch (self.tags[j]) {
            .identifier, .escaped_identifier => true,
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != token.default_keyword_set and // else: a keyword is an identifier only when the keyword set frees it
                token.isKeyword(t) and
                !token.isReserved(parse_expr.tokenText(self, j), self.kw_set),
        };
    }

    /// §2.8/§2.8.1 identifier or escaped identifier, interned.
    pub fn expectIdent(self: *Parser) Error!Ast.StrId {
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
    pub fn internTok(self: *Parser, i: u32) Error!Ast.StrId {
        // The two bytes are spelled out rather than imported from `ir/`, for the
        // same reason `parseDottedName`'s `.` is: the frontend owns the source
        // half of a two-sided convention and does not depend on the IR.
        const text = parse_expr.tokenText(self, i);
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
    pub fn skipAttributes(self: *Parser) error{OutOfMemory}!void {
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
                else => {}, // else: any other token is inside the attribute being skipped
            };
        };
    }

    /// The last `vera_lte` spec in `self.attrs[mark..]` (§2.9: "the last
    /// attribute value shall be used"), as the value and its token.
    pub fn lteSince(self: *const Parser, mark: usize) ?Ast.NatureAttr {
        var out: ?Ast.NatureAttr = null;
        for (self.attrs.items[mark..]) |a| {
            if (std.mem.eql(u8, self.file.str(a.name), "vera_lte")) out = a;
        }
        return out;
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
                    try parse_expr.parseExpr(self)
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
    pub inline fn recoverStatement(self: *Parser, before: u32) void {
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
            else => {}, // else: any other token is inside the statement being skipped
        };
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    /// `failAt` for a site that reports and carries on: the file is refused
    /// (`failed`) and parsing continues, but running out of memory still
    /// aborts. `failAt(..) catch {}` swallowed that OOM along with ParseError.
    pub fn report(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        switch (self.failAt(tok, code, fmt, args)) {
            error.ParseError => {},
            error.OutOfMemory => |e| return e,
        }
    }

    pub fn failAt(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
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
    pub fn failWith(self: *Parser, tok: u32, code: diag.Code) diag.Builder {
        self.failed = true;
        return self.bag.build(.parse, code, lexer.tokenSpan(self.src, self.starts, tok));
    }

    /// Human name of the token at `i`, for the "found ..." half of a message.
    pub fn found(self: *const Parser, i: u32) []const u8 {
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
            => parse_expr.tokenText(self, i),
            else => |t| tagDesc(t), // else: every other tag implies its own text
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
        else => token.Tag.quoted(t) orelse @tagName(t), // else: every other tag implies its own text
    };
}

/// Tokens that CLOSE something: when one is missing, the place to type it is
/// the end of the construct before it, not the token the parser choked on.
/// Drives the machine-applicable insertion in `expect`.
fn isTerminator(t: token.Tag) bool {
    return switch (t) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace => true,
        else => false, // else: not a list or statement terminator
    };
}

// Parser self-checks: the real lexer drives the real parser — parser/test.zig
const parse_test = @import("parser/test.zig");

test {
    _ = Parser.parse_source;
    _ = Parser.parse_module;
    _ = Parser.parse_specify;
    _ = Parser.parse_generate;
    _ = Parser.parse_decl;
    _ = Parser.parse_stmt;
    _ = Parser.parse_expr;
    _ = parse_test;
}
