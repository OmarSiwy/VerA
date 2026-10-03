//! Parser: token stream -> `Ast.SourceFile` (SoA stores addressed by u32 handles),
//! by recursive descent with precedence climbing for expressions.
//! LRM annex A (grammar), §4.2.2 (precedence), §6.8 (scopes).
//!
//! The grammar is split across `parser/*.zig`; each sub-file holds free functions
//! taking `self: *Parser`. This file owns the cursor, token text and diagnostics.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const diag = @import("diag");

/// `ParseError` unwinds to the nearest recovery point (module item, statement or
/// top-level declaration); its diagnostic is already in the bag.
pub const Error = error{ OutOfMemory, ParseError };

/// E0241's nesting limit. A Debug build overflows an 8 MB stack somewhere
/// between 3000 and 5000 nested parentheses, and later tree walks recurse too.
pub const max_depth = 1024;

/// Parser state for one token stream. Every allocation comes from `arena`;
/// `src`, `tags` and `starts` are borrowed and must outlive the produced
/// `Ast.SourceFile`, because every interned name is a slice of `src`.
pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tags: []const token.Tag,
    starts: []const u32,
    pos: u32 = 0,
    /// Open `enter` calls: expression, statement and generate-block nesting.
    depth: u16 = 0,
    file: Ast.SourceFile = .empty,
    /// Shared collector. The cap, the dedupe and the rendering all live there.
    bag: *diag.Bag,
    /// Whether this parse reported an error. The bag is shared across stages and
    /// drops entries at its cap and dedupe set, so its length cannot answer.
    failed: bool = false,
    /// §3.6.1.4 nature `access` names. `name(...)` is a branch probe (§4.4.1)
    /// iff the name is in here, otherwise it is a user function call (§4.7).
    /// Seeded with V/I (disciplines.vams, annex D) and grown by every
    /// `access = X;` nature attribute parsed ahead of the module.
    access_names: std.StringHashMapUnmanaged(void) = .empty,
    /// §10.6 reserved-keyword set in effect, and the sets saved by each open
    /// `begin_keywords directive. See `keywordsDirective` and `identLike`.
    kw_set: token.KeywordSet = token.default_keyword_set,
    kw_stack: std.ArrayList(token.KeywordSet) = .empty,
    /// The language this parse accepts (`vera --std=`), which is also §10.6's
    /// "implementation's default set of reserved keywords". Unlike `kw_set` it
    /// changes what parses: under a 1364 set a Verilog-AMS construct is E0242,
    /// because IEEE 1364-2005 annex A has no production for it. Set it with
    /// `setLanguage`.
    language: token.KeywordSet = token.default_keyword_set,
    /// Inside an `analog function` body (§4.7.1). Two of that clause's bullets
    /// restrict statements the ordinary statement parser also accepts at
    /// module scope, so only the position tells them apart (E0226, E0227).
    in_analog_fn: bool = false,
    /// Parsing for the digital executor (`--run`): admits the digital-only
    /// forms everywhere and keeps digital expression shapes unfolded.
    digital: bool = false,
    /// Inside the body of an `initial` or `always` block (§7.2.2's discrete
    /// context). A.6.2/A.6.5 give that body the digital statement forms (a `#`
    /// delay, `wait`, a nonblocking `<=`, intra-assignment timing) in any
    /// module, so they are admitted by position, not by file extension. An
    /// `analog` block has none of them (A.6.4). See `discreteGrammar`.
    in_discrete: bool = false,
    /// §2.6.2 forbids scale factors in digital delay expressions. Kept while
    /// parsing delay_control, delay2/delay3 and path_delay_expression so even
    /// a discarded min/max arm is checked before expression folding.
    in_digital_delay: bool = false,
    /// Inside a §7.6 `connectmodule` body. `parseEventTerm` reads it: A.6.5's
    /// `driver_update` is a digital event, and §9.22 paragraph 3 puts the
    /// driver family inside a connect module.
    in_connect_module: bool = false,
    /// §6.6 nesting depth of generate regions and generate construct bodies,
    /// counted together because both gates it feeds only ask "below a
    /// `generate`?". Syntax 6-8's `module_or_generate_item` has no
    /// `generate_region` ("Generate regions do not nest") and no
    /// `parameter_declaration`, so a nonzero depth refuses both (E0228, E0229).
    gen_depth: u32 = 0,
    /// How many generate constructs (loop/if/case, not regions) enclose the
    /// cursor, and an identity for the outermost one. Together they key §6.6.2's
    /// block name space; see `checkGenBlockNames`.
    gen_construct_depth: u32 = 0,
    gen_construct: u32 = 0,
    /// Set by a loop generate for the one `parseGenerateBlock` call that reads
    /// its body. §6.6.2's direct nesting applies to conditional constructs only,
    /// so a loop body is a scope even when it is one bare `if`.
    gen_loop_body: bool = false,
    /// Every §2.9 `attr_spec` of the module being parsed, flattened. Moved into
    /// the `ModuleDecl` at `endmodule` and cleared; see `parseAttributes`.
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,
    /// Nonzero inside an attribute value, where §2.9 bans a nested attribute
    /// instance (E0357).
    attr_depth: u32 = 0,

    /// Asserts `tags` and `starts` have equal length and end in `.eof`.
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

    /// The state a parse of a leading run of tokens leaves behind, so a parse
    /// of a longer stream that begins with that run can resume instead of
    /// redoing it. Built once per process for the annex D/E prelude by
    /// `Preprocessor.preludeAst`, which asserts that every field not listed
    /// here is back at its `init` value when the prefix parse ends.
    ///
    /// A new `Parser` field that a prefix parse can leave dirty must be added
    /// here too; the prelude AST equivalence test in `pp/test.zig` catches the
    /// omission.
    pub const Seed = struct {
        /// Stores and decl lists. See `Ast.SourceFile.seedFrom` for which half
        /// is copied and which is borrowed, and why the borrow is sound.
        file: Ast.SourceFile,
        /// §3.6.1.4 access names in effect at the seam. A list, not the map:
        /// re-inserting a handful of keys is cheaper than cloning a hash map.
        access_names: []const []const u8,
        /// Token index the prefix parse stopped on: its `.eof`, which is the
        /// first token of the resumed parse.
        pos: u32,
        /// §6.6.2 outermost-construct identity, monotonic over the whole file.
        gen_construct: u32,
    };

    /// `init`, then resumes from `seed`. A null `seed` is exactly `init` (the
    /// `--no-std-defs` path). Precondition: `tags` begins with the token run
    /// `seed` was parsed from.
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
        // `root.zig` guarantees the shared prefix: the same `Prelude` seeded the lexer.
        std.debug.assert(s.pos < tags.len);
        p.pos = s.pos;
        p.gen_construct = s.gen_construct;
        try p.file.seedFrom(arena, &s.file);
        for (s.access_names) |n| try p.access_names.put(arena, n, {});
        return p;
    }

    /// Parses as `set`'s language: it becomes the §10.6 default keyword set and
    /// the ceiling on `begin_keywords` and on Verilog-AMS constructs (E0242).
    pub fn setLanguage(self: *Parser, set: token.KeywordSet) void {
        self.language = set;
        self.kw_set = set;
    }

    /// Reports E0242 if the token at `pos` opens a Verilog-AMS design element
    /// or module item and `language` is a 1364 set. Called where a description
    /// or a module item is dispatched, which is where every AMS construct
    /// starts; below that, such a keyword can only be an identifier. The
    /// construct is then parsed anyway, so the one error is the only one.
    pub fn refuseAms(self: *Parser) error{OutOfMemory}!void {
        const t = self.peek();
        if (@backingInt(self.language) >= @backingInt(token.KeywordSet.vams_2_3) or !token.isKeyword(t)) return;
        const w = self.tokenText(self.pos);
        if (token.isReserved(w, self.language)) return;
        try self.report(self.pos, .E0242, "`{s}` under \"{s}\"", .{ w, self.language.specifier() });
    }

    // Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations, A.5 UDPs
    const parse_source = @import("parser/source.zig");
    /// Parses the whole stream. Returns `error.ParseError` at the end if anything
    /// was reported; the AST is then partial and must not be lowered.
    pub const parseSourceFile = parse_source.parseSourceFile;

    // Annex A.1.2 module_declaration and A.1.4 module_item (LRM §6.2, Clause 3)
    const parse_module = @import("parser/module.zig");

    // Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1)
    const parse_specify = @import("parser/specify.zig");

    // Annex A.4.1 module instantiation (LRM §6.2.2), A.3 gates and switches, A.6.2 initial/always
    const parse_inst = @import("parser/inst.zig");

    // Annex A.4.2 generate constructs (LRM §6.6)
    const parse_generate = @import("parser/generate.zig");

    // Annex A.2.1.1 parameters (§3.4), A.2.1.3 variables and events, A.2.5 dimensions
    const parse_decl = @import("parser/decl.zig");

    // Annex A.2.6 analog functions (§4.7.1), IEEE 1364-2005 A.2.6/A.2.7 digital functions and tasks
    const parse_function = @import("parser/function.zig");

    // Annex A.1.6/A.1.7 natures and disciplines (§3.6)
    const parse_discipline = @import("parser/discipline.zig");

    // Annex A.2.1.2/A.2.1.3/A.2.2 port, net and branch declarations, strengths and delays
    const parse_net = @import("parser/net.zig");

    // §6.7 / A.9.3 hierarchical names in declaration positions
    const parse_hier = @import("parser/hier.zig");

    // Annex A.6.4 analog_statement (LRM Clause 5)
    const parse_stmt = @import("parser/stmt.zig");

    // Annex A.8.3 expressions (§4.1, §4.2 precedence climbing), and literals (§2.6 numbers, §2.7 strings, §2.8 identifiers)
    const parse_expr = @import("parser/expr.zig");

    // -----------------------------------------------------------------------
    // Token access: LRM §2.2 (the stream), §2.8 (identifiers)
    // -----------------------------------------------------------------------

    /// Whether the A.6.5 forms an analog statement lacks (`#`, `wait`, `<=`,
    /// intra-assignment timing) parse here: in a digital source, or in the
    /// body of an `initial`/`always` block anywhere.
    pub fn discreteGrammar(self: *const Parser) bool {
        return self.digital or self.in_discrete;
    }

    /// Returns the tag at the cursor without consuming it.
    pub fn peek(self: *const Parser) token.Tag {
        return self.tags[self.pos];
    }

    /// Returns the tag `n` tokens ahead, clamped to the final `.eof`.
    pub fn peekAt(self: *const Parser, n: u32) token.Tag {
        const i = self.pos + n;
        return self.tags[@min(i, self.tags.len - 1)];
    }

    /// Consumes the next token if it is `t`; returns whether it did.
    pub fn eat(self: *Parser, t: token.Tag) bool {
        if (self.peek() != t) return false;
        self.pos += 1;
        return true;
    }

    /// Returns the source text of token `i`, without the leading `\` of an
    /// escaped identifier. Tokens store no length, so the lexer re-scans the
    /// lexeme from its start; that is exact because the lexer's `next()` is a
    /// pure function of (src, pos). Cost: one token scan per call.
    pub fn tokenText(self: *const Parser, i: u32) []const u8 {
        const lx: lexer.Lexer = .{ .src = self.src };
        const text = lx.tokenText(self.starts[i]);
        // §2.8.1: the `\` opens the identifier but is not part of the name.
        // The terminator is not in the span, so only the head is stripped.
        return if (self.tags[i] == .escaped_identifier) text[1..] else text;
    }

    /// Whether token `i` is the reserved spelling `w`. Annex B's out-of-subset
    /// keywords share the `.kw_reserved` tag, so a grammar that needs one of
    /// them by name asks here.
    pub fn reservedIs(self: *const Parser, i: u32, w: []const u8) bool {
        return self.tags[i] == .kw_reserved and std.mem.eql(u8, self.tokenText(i), w);
    }

    /// Consumes `w` if it is the next token; one of A.7's `=>`, `*>` and `&&&`.
    /// The lexer tags them `.invalid` because outside a specify block none is
    /// an operator, so the spelling is the test.
    pub fn eatSymbol(self: *Parser, w: []const u8) bool {
        if (self.peek() != .invalid or !std.mem.eql(u8, self.tokenText(self.pos), w)) return false;
        self.pos += 1;
        return true;
    }

    /// Byte just past the previous token: where a missing terminator has to be
    /// typed, and so where `expect`'s insertion fix is anchored. `tokenText`
    /// strips an escaped identifier's `\` though it is in the source span,
    /// and `.eof` has no text.
    fn endOfPrev(self: *const Parser) u32 {
        if (self.pos == 0) return self.starts[0];
        const i = self.pos - 1;
        if (self.tags[i] == .eof) return self.starts[i];
        const backslash: u32 = @intFromBool(self.tags[i] == .escaped_identifier);
        return self.starts[i] + backslash + @as(u32, @intCast(self.tokenText(i).len));
    }

    /// Consumes a `t` token and returns its index. Otherwise reports E0207,
    /// with an insertion fix when `t` is a terminator, and returns
    /// `error.ParseError` with the cursor unmoved.
    pub fn expect(self: *Parser, t: token.Tag) Error!u32 {
        if (self.peek() != t) {
            // The title is only "unexpected token", so the caret carries what
            // the grammar wanted here.
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected {s}", .{tagDesc(t)});
            // A missing terminator belongs after the previous construct, but
            // the caret lands on whatever came next, often on the next line.
            // The fix points at the column where it has to be typed.
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

    /// Whether token `i` can stand where the grammar wants an identifier.
    ///
    /// §2.8/§2.8.1 identifiers always can, and so can a keyword the active
    /// §10.6 set does not reserve: under `begin_keywords "1364-2005",
    /// `input sin;` is "OK since sin is not a keyword in 1364-2005". §10.6
    /// also says the directive does "not affect the ... tokens", which is why
    /// this is a parser rule: `analog` stays `kw_analog` in the same module.
    pub fn identLike(self: *const Parser, i: u32) bool {
        const j = @min(i, self.tags.len - 1);
        return switch (self.tags[j]) {
            .identifier, .escaped_identifier => true,
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != token.default_keyword_set and // else: a keyword is an identifier only when the keyword set frees it
                token.isKeyword(t) and
                !token.isReserved(self.tokenText(j), self.kw_set),
        };
    }

    /// Consumes a §2.8/§2.8.1 identifier (or a keyword `identLike` frees) and
    /// returns it interned. Reports E0208 otherwise.
    pub fn expectIdent(self: *Parser) Error!Ast.StrId {
        if (!self.identLike(self.pos))
            return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)});
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// `expectIdent`, or a §9.18 system name (`$mfactor`) where the grammar
    /// admits one as a parameter identifier.
    pub fn expectIdentOrSys(self: *Parser) Error!Ast.StrId {
        if (self.peek() != .system_identifier) return self.expectIdent();
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// Interns token `i`'s text as a name. Each period in an escaped identifier
    /// (§2.8.1: `\x.y ` is the identifier `x.y`) becomes a space, so that after
    /// this point a period in a name always means a hierarchy separator
    /// (`Elaborate.sep`). Without it, `\x.y` inside instance `u` and net `y`
    /// inside `u.x` would flatten to the same `u.x.y`. A space cannot occur in
    /// an identifier, so the mapping is injective; `naming.sanitize` later
    /// spells it `Z20`. Allocates only for an escaped name with a period.
    pub fn internTok(self: *Parser, i: u32) Error!Ast.StrId {
        // The bytes are spelled out, not imported from `ir/`: the frontend owns
        // the source half of this convention and does not depend on the IR.
        const text = self.tokenText(i);
        if (self.tags[i] != .escaped_identifier) return self.file.intern(self.arena, text);
        // IEEE 1364-2005 §3.7.3: a system task or function "shall not be
        // escaped", so `\$display` keeps its `\` and names no system task.
        if (text[0] == '$') return self.file.intern(self.arena, (lexer.Lexer{ .src = self.src }).tokenText(self.starts[i]));
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
    /// Parses any attribute instances at the cursor and appends every spec to
    /// `self.attrs`, which `parseModule` hands to the enclosing module for
    /// validation. Also binds this prefix to the following declaration;
    /// statement and expression callers refine that parsed owner below.
    ///
    /// A malformed attribute is reported and the cursor resynchronized past its
    /// `*)`, so the caller always lands past the instance. Only OOM propagates.
    pub fn skipAttributes(self: *Parser) error{OutOfMemory}!void {
        const mark = self.attrs.items.len;
        self.parseAttributes() catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // Already reported. Resynchronize past the closing `*)` so one bad
            // attribute does not also cost the decorated declaration a diagnostic.
            while (true) : (self.pos += 1) switch (self.peek()) {
                .eof => return,
                .attr_close => {
                    self.pos += 1;
                    return;
                },
                else => {}, // else: any other token is inside the attribute being skipped
            };
        };
        if (self.attrs.items.len != mark) try self.file.attributes.append(self.arena, .{
            .owner = .{ .kind = .declaration, .tok = self.pos },
            .specs = try self.arena.dupe(Ast.NatureAttr, self.attrs.items[mark..]),
        });
    }

    /// Parse a suffix or statement prefix, retaining its actual owner.
    pub fn ownedAttributes(self: *Parser, owner: Ast.AttributeOwner) error{OutOfMemory}!void {
        const first = self.file.attributes.items.len;
        try self.skipAttributes();
        // §2.9/IEEE §3.8 prohibit attributes inside an attribute value;
        // attr_depth diagnoses them. A successful run adds only this one
        // prefix binding, whose specs include every adjacent instance.
        std.debug.assert(self.file.attributes.items.len <= first + 1);
        for (self.file.attributes.items[first..]) |*a| a.owner = owner;
    }

    /// A declaration list gives every declared name the prefix's specs.
    pub fn copyAttributes(self: *Parser, from: u32, to: u32) error{OutOfMemory}!void {
        if (from == to) return;
        const count = self.file.attributes.items.len;
        for (0..count) |i| {
            const a = self.file.attributes.items[i];
            if (a.owner.kind != .declaration or a.owner.tok != from) continue;
            const exists = for (self.file.attributes.items) |b| {
                if (b.owner.kind == .declaration and b.owner.tok == to and b.specs.ptr == a.specs.ptr) break true;
            } else false;
            if (!exists) try self.file.attributes.append(self.arena, .{ .owner = .{ .kind = .declaration, .tok = to }, .specs = a.specs });
        }
    }

    /// Lookahead may have consumed a body statement's prefix already.
    pub fn statementAttributes(self: *Parser, tok: u32) void {
        for (self.file.attributes.items) |*a| if (a.owner.kind == .declaration and a.owner.tok == tok) {
            a.owner.kind = .statement;
        };
    }

    /// The last spec of each VerA attribute in `self.attrs[mark..]` (§2.9:
    /// "the last attribute value shall be used"), in `lte_kinds` order.
    pub fn lteSince(self: *const Parser, mark: usize) [lte_kinds.len]?Ast.NatureAttr {
        var out: [lte_kinds.len]?Ast.NatureAttr = @splat(null);
        for (self.attrs.items[mark..]) |a| for (&out, lte_kinds) |*o, k| {
            if (std.mem.eql(u8, self.file.str(a.name), @tagName(k))) o.* = a;
        };
        return out;
    }

    /// Records `lteSince`'s finds against statement `stmt` or call `expr`.
    pub fn keepLte(self: *Parser, specs: [lte_kinds.len]?Ast.NatureAttr, stmt: Ast.StmtId, expr: Ast.ExprId) error{OutOfMemory}!void {
        for (specs, lte_kinds) |f, k| if (f) |a| try self.file.lte_attrs.append(
            self.arena,
            .{ .kind = k, .stmt = stmt, .expr = expr, .value = a.value, .main_tok = a.main_tok },
        );
    }
    const lte_kinds = std.enums.values(@FieldType(Ast.LteAttr, "kind"));

    fn parseAttributes(self: *Parser) Error!void {
        while (self.peek() == .attr_open) {
            // §2.9: "Nesting of attribute instances is disallowed." An attribute
            // value is a full `parseExpr`, and A.8.3 gives an operator its own
            // `{ attribute_instance }` slot, so without this check
            // `(* outer = (1 + (* inner *) 2) *)` would parse cleanly.
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
                // annex B keyword (`kw_units`). No keyword means anything else
                // here, so every keyword is taken as a name.
                if (!self.identLike(tok) and !token.isKeyword(self.peek()))
                    return self.failAt(tok, .E0208, "found {s}", .{self.found(tok)});
                const name = try self.internTok(tok);
                self.pos += 1;
                // §2.9: "If the value is not specified, then ... the default
                // value is 1." `.none` stands for that default.
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
    /// (`failed`) and parsing continues. Only OOM propagates.
    pub fn report(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        switch (self.failAt(tok, code, fmt, args)) {
            error.ParseError => {},
            error.OutOfMemory => |e| return e,
        }
    }

    /// Opens one level of nesting; the caller pairs it with
    /// `defer self.depth -= 1`. Fails with E0241 past `max_depth`, so nested
    /// source is refused before it overflows the native stack.
    pub fn enter(self: *Parser) Error!void {
        if (self.depth == max_depth) return self.failAt(self.pos, .E0241, "", .{});
        self.depth += 1;
    }

    /// Marks the parse failed, adds `code` at token `tok` to the bag, and returns
    /// `error.ParseError` for the caller to propagate (`error.OutOfMemory` if the
    /// bag cannot grow). An unterminated string at `tok` is reported as E0138
    /// instead of `code`.
    pub fn failAt(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        self.failed = true;
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        if (tok < self.tags.len and self.tags[tok] == .invalid) {
            if (try self.failRunawayString(span)) return error.ParseError;
        }
        try self.bag.add(.parse, code, span, fmt, args);
        return error.ParseError;
    }

    /// Reports E0138 when the `.invalid` token at `span` is a §2.7 string that
    /// runs off its line, which would otherwise read only "found invalid token".
    /// Checked here in the funnel because the token is reachable from both
    /// statement and module-item position. Returns whether it emitted.
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

    /// `failAt`'s diagnostic, opened for labels, notes and suggestions. Marks
    /// the parse failed; the caller must `emit` and then return
    /// `error.ParseError` itself.
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
            => self.tokenText(i),
            else => |t| tagDesc(t), // else: every other tag implies its own text
        };
    }
};

/// Name of an expected token in a diagnostic. Punctuation is spelled as the
/// character to type, in backticks (from `token.Tag.quoted`); categories with
/// no fixed spelling stay prose.
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

/// Tokens that close something: when one is missing, the place to type it is
/// the end of the construct before it. Drives the insertion fix in `expect`.
fn isTerminator(t: token.Tag) bool {
    return switch (t) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace => true,
        else => false, // else: not a list or statement terminator
    };
}

// Parser self-checks: the real lexer drives the real parser.
const parse_test = @import("parser/test.zig");

test {
    _ = Parser.parse_source;
    _ = Parser.parse_module;
    _ = Parser.parse_specify;
    _ = Parser.parse_generate;
    _ = Parser.parse_inst;
    _ = Parser.parse_decl;
    _ = Parser.parse_function;
    _ = Parser.parse_discipline;
    _ = Parser.parse_net;
    _ = Parser.parse_hier;
    _ = Parser.parse_stmt;
    _ = Parser.parse_expr;
    _ = parse_test;
}
