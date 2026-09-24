//! Annex A.8.3 expressions (§4.1, §4.2 precedence climbing), and literals (§2.6 numbers, §2.7 strings, §2.8 identifiers).
//!
//! In: expression tokens. Out: `Ast.ExprId`s, with literal values decoded here, once.
//!
//! LRM clauses this file's code cites: §2.6.1, §2.6.2, §2.7, §3.2.2, §3.3, §4.1, §4.2, §4.2.2, §4.2.10, §4.2.12, §4.2.13, §6.7.
//!
//! Cut verbatim from `parser.zig`. Functions take `self: *Parser` and are called
//! directly, `parse_expr.f(self, ...)`; `parser.zig` aliases only what other modules call.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_stmt = @import("stmt.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;
const found = Parser.found;

// -----------------------------------------------------------------------
// A.8.3 expressions — LRM §4.1, §4.2 (precedence climbing)
// -----------------------------------------------------------------------

/// Full expression, conditional operator included. LRM §4.1, §4.2.
pub fn parseExpr(self: *Parser) Error!Ast.ExprId {
    return parseExprPrec(self, prec_ternary);
}

/// Precedence climbing over LRM Table 4-3 (§4.2.2).
pub fn parseExprPrec(self: *Parser, min_prec: u8) Error!Ast.ExprId {
    var lhs = try parseUnary(self);
    while (true) {
        const t = self.peek();
        // §4.2.12 conditional — lowest precedence, right associative.
        if (t == .question and min_prec <= prec_ternary) {
            const tok = self.pos;
            self.pos += 1;
            try self.skipAttributes();
            const then_e = try parseExpr(self);
            _ = try self.expect(.colon);
            const else_e = try parseExprPrec(self, prec_ternary);
            lhs = try self.file.exprs.add(self.arena, .{
                .tag = .ternary,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = then_e,
                .extra = @intFromEnum(else_e),
            });
            continue;
        }
        const op = binOp(t) orelse return lhs;
        const prec = binopPrec(op);
        if (prec < min_prec) return lhs;
        const tok = self.pos;
        self.pos += 1;
        try self.skipAttributes(); // A.8.3 `binary_operator { attribute_instance }`
        // §4.2.2: "All operators associate left to right with the exception
        // of the conditional operator which associates right to left."
        // There is no `**` carve-out — §4.2.12 names `?:` as the only
        // right-associative operator, and `?:` is handled above, not here.
        // `**` used to be excepted, which made `2**3**2` 512 instead of 64.
        const rhs = try parseExprPrec(self, prec + 1);
        lhs = try self.file.exprs.add(self.arena, .{
            .tag = .binary,
            .main_tok = tok,
            .lhs = lhs,
            .rhs = rhs,
            .extra = @intFromEnum(op),
        });
    }
}

/// A.8.6 unary_operator (§4.2.1, §4.2.7–§4.2.10). Unary binds tighter than
/// every binary operator (Table 4-3, top row).
pub fn parseUnary(self: *Parser) Error!Ast.ExprId {
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
        else => return parsePostfix(self), // else: not a unary operator, so a postfix/primary operand
    };
    self.pos += 1;
    try self.skipAttributes(); // A.8.3 `unary_operator { attribute_instance }`
    const operand = try parseUnary(self);
    return self.file.exprs.add(self.arena, .{
        .tag = .unary,
        .main_tok = tok,
        .lhs = operand,
        .extra = @intFromEnum(op),
    });
}

/// §3.2.2/§3.4.4 array and part selects: `base[i]`, `base[msb:lsb]`.
pub fn parsePostfix(self: *Parser) Error!Ast.ExprId {
    var e = try parsePrimary(self);
    while (self.peek() == .lbracket) {
        const tok = self.pos;
        self.pos += 1;
        var idx = try parseExpr(self);
        if (self.eat(.colon)) { // A.8.3 analog_range_expression
            const lsb = try parseExpr(self);
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
        .int_literal, .real_literal => return parseNumber(self),
        .string_literal => { // §2.7
            const s = try internString(self, tok);
            self.pos += 1;
            return self.file.exprs.add(self.arena, .{ .tag = .str_literal, .main_tok = tok, .str = s });
        },
        .lparen => {
            self.pos += 1;
            const e = try parseExpr(self);
            // IEEE 1364-2005 §5.3 / A.8.3 `mintypmax_expression ::= expression
            // | expression : expression : expression`, legal wherever an
            // expression is (a digital parse). The tool chooses one member of
            // each triple; this one takes the typical, the middle, whose
            // compound expressions then all read their middle members.
            if (self.digital and self.eat(.colon)) {
                const typ = try parseExpr(self);
                _ = try self.expect(.colon);
                _ = try parseExpr(self);
                _ = try self.expect(.rparen);
                return typ;
            }
            _ = try self.expect(.rparen);
            return e;
        },
        // §4.2.13 / A.8.1 analog_concatenation, analog_multiple_concatenation
        .lbrace => {
            var items: std.ArrayList(Ast.ExprId) = .empty;
            const count = try braceOperands(self, &items);
            if (count) |n| return multiConcat(self, tok, n, items.items);
            if (try foldBitConcat(self, tok, items.items)) |folded| return folded;
            const off = try self.file.exprs.addExprList(self.arena, items.items);
            return self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
        },
        // A.8.1 assignment_pattern `'{ ... }` (§3.4.4 array defaults,
        // §4.5.6 filter coefficient args)
        .apostrophe_lbrace => {
            self.pos += 1;
            var items: std.ArrayList(Ast.ExprId) = .empty;
            if (self.peek() != .rbrace) {
                // §3.6.3.2's bus nodeset, which prints its own hole:
                // `electrical [0:4] bus = '{2.3,4.5,,6.0};` — "a null value
                // in the constant array indicates that no nodeset value is
                // being specified for this element of the bus". A.8.1 has
                // no such alternative (A.8.3's
                // `constant_expression_or_null` is the shape a corrected
                // A.8.1 would use and nothing references it), so the clause
                // and its example are the authority. `.none` is what the
                // element list already carries for a cell the pattern does
                // not reach — `Lower.fillPattern` — so a hole needs no new
                // representation, only a spelling.
                const first = if (self.peek() == .comma) Ast.ExprId.none else try parseExpr(self);
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
                if (first != .none and self.peek() == .lbrace) {
                    var inner: std.ArrayList(Ast.ExprId) = .empty;
                    try braceGroup(self, &inner);
                    if (replCount(self, first)) |n| {
                        for (0..n) |_| try items.appendSlice(self.arena, inner.items);
                    } else {
                        // A constant_expression the parser cannot evaluate
                        // (`'{N{0.5}}`, N a localparam): lowering unrolls it
                        // with the folder in hand, `Lower.patternElems`.
                        const off = try self.file.exprs.addExprList(self.arena, inner.items);
                        const group = try self.file.exprs.add(self.arena, .{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
                        try items.append(self.arena, try self.file.exprs.add(self.arena, .{ .tag = .pattern_repl, .main_tok = tok, .lhs = first, .rhs = group }));
                    }
                } else {
                    try items.append(self.arena, first);
                    while (self.eat(.comma)) try items.append(
                        self.arena,
                        if (self.peek() == .comma or self.peek() == .rbrace) .none else try parseExpr(self),
                    );
                }
            }
            _ = try self.expect(.rbrace);
            const off = try self.file.exprs.addExprList(self.arena, items.items);
            return self.file.exprs.add(self.arena, .{ .tag = .assign_pattern, .main_tok = tok, .extra = off });
        },
        .identifier, .escaped_identifier => {
            // References and declaration names must use the same escaped
            // period normalization; raw text aliases hierarchy separators.
            const name = try self.internTok(tok);
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
                        else => try self.expectIdent(), // else: not a nature attribute keyword; `expectIdent` takes it or refuses it
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
                    const args = try parseCallArgs(self);
                    return addCall(self, .call, tok, flat, args);
                }
                const off = try self.file.exprs.addStrList(self.arena, parts.items);
                return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
            }
            if (self.peek() == .lparen) {
                // §4.4 branch probe vs §4.7 user function: only a declared
                // nature access name (§3.6.1.4) probes a branch.
                if (self.access_names.contains(self.file.str(name))) {
                    return parseAccess(self, name, tok);
                }
                const args = try parseCallArgs(self);
                return addCall(self, .call, tok, name, args);
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
            return parseAccess(self, name, tok);
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
                try parseCallArgs(self)
            else
                &.{};
            return addCall(self, .sys_call, tok, name, args);
        },
        // A.2.5 value_range_expression `inf` (only meaningful in §3.4.2).
        .kw_inf => {
            self.pos += 1;
            return self.file.exprs.add(self.arena, .{ .tag = .pos_inf, .main_tok = tok });
        },
        else => {}, // else: not one of the keyword primaries above; the identifier path follows
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
        return parse_stmt.parseEventTerm(self) // §5.10.2
    else
        return self.failAt(self.pos, .E0209, "found {s}", .{self.found(self.pos)});

    const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
    self.pos += 1;
    // §2.9: an attribute_instance "can appear as a suffix to ... a
    // Verilog-AMS function name in an expression". A.8.2 draws that slot only
    // for `analog_function_call`; VerA extends it to these keyword-named
    // calls so `ddt (* vera_lte = 0 *) (q)` can name one charge site.
    const mark = self.attrs.items.len;
    if (self.peek() == .attr_open) try self.skipAttributes();
    const lte = self.lteSince(mark);
    const args = try parseCallArgs(self);
    const id = try addCall(self, call_tag, tok, name, args);
    if (lte) |a| try self.file.lte_attrs.append(self.arena, .{ .expr = id, .value = a.value, .main_tok = a.main_tok });
    return id;
}

pub inline fn addCall(self: *Parser, tag: Ast.ExprTag, tok: u32, name: Ast.StrId, args: []const Ast.ExprId) Error!Ast.ExprId {
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
pub fn parseAccess(self: *Parser, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
    _ = try self.expect(.lparen);
    if (self.eat(.lt)) { // §5.4.3 port branch `I(<p>)`
        const port = try parseNetRef(self);
        _ = try self.expect(.gt);
        _ = try self.expect(.rparen);
        return self.file.exprs.add(self.arena, .{
            .tag = .port_access,
            .main_tok = tok,
            .lhs = port,
            .str = name,
        });
    }
    if (try parseHierBranchRef(self, name, tok)) |e| return e;
    const hi = try parseNetRef(self);
    var lo: Ast.ExprId = .none;
    if (self.eat(.comma)) lo = try parseNetRef(self);
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
pub fn parseHierBranchRef(self: *Parser, name: Ast.StrId, tok: u32) Error!?Ast.ExprId {
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
    const hi = try hierTerminal(self, parts.items, tok);
    var lo: Ast.ExprId = .none;
    if (self.eat(.comma)) lo = try hierTerminal(self, parts.items, tok);
    _ = try self.expect(.rparen);
    _ = try self.expect(.rparen);
    return try self.file.exprs.add(self.arena, .{
        .tag = .branch_access,
        .main_tok = tok,
        .lhs = hi,
        .rhs = lo,
        .str = name,
        // The rewrite above erases the spelling, and §5.6.8.1 vs §5.6.8.2 is
        // decided by it: mark the node (`Ast.branch_ref_hier_unnamed`).
        .extra = Ast.branch_ref_hier_unnamed,
    });
}

/// One `branch_terminal` of the production above, rewritten onto `prefix`.
pub fn hierTerminal(self: *Parser, prefix: []const Ast.StrId, tok: u32) Error!Ast.ExprId {
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
pub fn parseNetRef(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    const name = if (self.peek() == .system_identifier and self.tags[self.pos + 1] == .dot) blk: {
        const root = try self.internTok(self.pos);
        self.pos += 1;
        break :blk root;
    } else try self.expectIdent();
    const base = if (self.peek() == .dot) hier: {
        var parts: std.ArrayList(Ast.StrId) = .empty;
        try parts.append(self.arena, name);
        while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
        const off = try self.file.exprs.addStrList(self.arena, parts.items);
        // §6.7 + §5.5.2: `V(u.v[1])`, one element of a child's vector net —
        // the select below applies to the whole path.
        break :hier try self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
    } else try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    if (self.peek() != .lbracket) return base;
    self.pos += 1;
    const idx = try parseExpr(self);
    _ = try self.expect(.rbracket);
    return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
}

/// A.8.2 / A.6.9 argument list. An omitted argument (`f(a, , c)`, and the
/// empty filter/task slots the grammar allows) becomes `.none`, so lowering
/// can apply the per-function defaults instead of guessing arity.
pub fn parseCallArgs(self: *Parser) Error![]const Ast.ExprId {
    _ = try self.expect(.lparen);
    var items: std.ArrayList(Ast.ExprId) = .empty;
    if (self.peek() != .rparen) {
        while (true) {
            if (self.peek() == .comma or self.peek() == .rparen) {
                try items.append(self.arena, .none);
            } else {
                try items.append(self.arena, try parseExpr(self));
            }
            if (!self.eat(.comma)) break;
        }
    }
    _ = try self.expect(.rparen);
    return items.items;
}

/// Operator precedence. LRM §4.2.2 Table 4-3, highest binds tightest.
pub fn binopPrec(op: Ast.BinaryOp) u8 {
    return switch (op) {
        .pow => 12,
        .mul, .div, .mod => 11,
        .add, .sub => 10,
        .shl, .shr, .ashl, .ashr => 9,
        .lt, .le, .gt, .ge => 8,
        .eq, .neq, .case_eq, .case_neq => 7,
        .bit_and => 6,
        .bit_xor, .bit_xnor => 5,
        .bit_or => 4,
        .logical_and => 3,
        .logical_or => 2,
    };
}

/// §4.2.12 `?:` sits below every binary operator (Table 4-3, last row).
pub const prec_ternary: u8 = 1;

/// A.8.6 binary_operator → `Ast.BinaryOp`, null for a token that is not one.
/// `===`/`!==`/`<<<`/`>>>` are mapped, not rejected: annex C.5 rejection is
/// lowering's message.
pub fn binOp(tag: token.Tag) ?Ast.BinaryOp {
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
        else => null, // else: not a binary operator token
    };
}

// -----------------------------------------------------------------------
// Literals — LRM §2.6 numbers, §2.7 strings, §2.8 identifiers
// -----------------------------------------------------------------------

/// §2.6.1 integer (incl. sized/based) and §2.6.2 real (exponent + SI scale
/// factor) literals. Values are computed here because the token stream
/// stores only {tag,start}.
pub fn parseNumber(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    self.pos += 1;

    if (self.tags[tok] == .int_literal) {
        const text = gluedNumberText(self, tok);
        const lit = @import("../integer.zig").parse(self.arena, text) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
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

    const text = tokenText(self, tok);
    // §2.6.2 decoding — `_` removal and the Table 2-1 scale factor — lives
    // in `lexer.parseReal` for the same reason §2.6.1 lives in `integer.parse`:
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

/// The span `integer.parse` has to see to name a MALFORMED §2.6.1 second
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
pub fn gluedNumberText(self: *const Parser, tok: u32) []const u8 {
    const text = tokenText(self, tok);
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
        .identifier => for (tokenText(self, tok + 1)) |c| {
            if (!lexer.isBasedDigit(c, 16)) return text;
        },
        // Only an apostrophe: a stray backtick is the preprocessor's, and
        // gluing it would decode as a bad digit and say so (E0133).
        .invalid => if (self.src[next] != '\'') return text,
        else => return text, // else: nothing else can be the glued remainder of a based number
    }
    return self.src[start .. next + tokenText(self, tok + 1).len];
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
pub fn braceOperands(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!?Ast.ExprId {
    _ = try self.expect(.lbrace);
    if (self.eat(.rbrace)) return null;

    if (self.digital or self.peek() != .lbrace) {
        const first = try parseExpr(self);
        if (self.peek() == .lbrace) {
            var inner: std.ArrayList(Ast.ExprId) = .empty;
            try braceGroup(self, &inner);
            _ = try self.expect(.rbrace);
            if (self.digital) {
                // Preserve the multiplier and grouping: zero replication
                // still evaluates its operands and has contextual legality.
                try items.appendSlice(self.arena, inner.items);
                return first;
            }
            const n = concatReplCount(self, first) orelse {
                try items.appendSlice(self.arena, inner.items);
                return first;
            };
            // §4.2.13 "When a replication expression is evaluated, the
            // operands shall be evaluated exactly once, even if the
            // replication constant is zero." A literal has nothing to
            // evaluate, so only a zero group over something else is kept —
            // as a `.multi_concat` `foldBitConcat` gives no width.
            if (n == 0) for (inner.items) |it| switch (self.file.exprs.tag(it)) {
                .int_literal, .real_literal, .str_literal, .logic_literal => {},
                else => { // else: anything but a literal may have an effect to evaluate
                    try items.appendSlice(self.arena, inner.items);
                    return first;
                },
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
            try braceGroup(self, items);
        } else try items.append(self.arena, try parseExpr(self));
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rbrace);
    return null;
}

/// `braceOperands` for the positions that cannot pass a count upwards: a
/// nonconstant replication stays ONE operand instead of being returned.
pub fn braceGroup(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!void {
    const at = self.pos;
    var g: std.ArrayList(Ast.ExprId) = .empty;
    if (try braceOperands(self, &g)) |c| {
        try items.append(self.arena, try multiConcat(self, at, c, g.items));
    } else if (self.digital) {
        const off = try self.file.exprs.addExprList(self.arena, g.items);
        try items.append(self.arena, try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = at, .extra = off }));
    } else try items.appendSlice(self.arena, g.items);
}

/// `{count{items}}` kept unexpanded for lowering (§3.3's nonconstant
/// multiplier). `rhs` is the inner `.concat`, exactly as `Ast.ExprTag`
/// documents the tag.
pub fn multiConcat(self: *Parser, tok: u32, count: Ast.ExprId, items: []const Ast.ExprId) Error!Ast.ExprId {
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
pub fn replCount(self: *const Parser, e: Ast.ExprId) ?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .int_literal) return null;
    const v = ex.intValue(e);
    if (v < 0 or v > 4096) return null;
    return @intCast(v);
}

/// `replCount` for a CONCATENATION's count, which §4.2.1 also lets be real:
/// "If a real expression is used for the replication factor of a
/// concatenation, the expression will first be converted to an integer value
/// using the rules described in 4.2.1.1" — round to nearest, ties away from
/// zero, which is `@round`. So `{2.5{4'd3}}` is `{3{4'd3}}`.
///
/// Only a concatenation's: an A.8.1 assignment pattern is not one, and keeps
/// `replCount`. A negative real is a unary minus, not a literal, so it
/// reaches `lowerConcat` exactly as `{-5{a}}` does.
pub fn concatReplCount(self: *const Parser, e: Ast.ExprId) ?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .real_literal) return replCount(self, e);
    const r = @round(ex.realValue(e));
    if (!(r >= 0 and r <= 4096)) return null;
    return @intFromFloat(r);
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
pub fn foldBitConcat(self: *Parser, tok: u32, items: []const Ast.ExprId) Error!?Ast.ExprId {
    if (self.digital) return null;
    const ex = &self.file.exprs;
    var any_sized = false;
    var effects: std.ArrayList(Ast.ExprId) = .empty;
    for (items) |it| {
        if (ex.tag(it) == .logic_literal) return null;
        // A zero group `braceOperands` kept for §4.2.13's "evaluated exactly
        // once": "considered to have a size of zero and is ignored".
        if (ex.tag(it) == .multi_concat and concatReplCount(self, ex.lhs(it)) == 0) {
            try effects.append(self.arena, it);
            continue;
        }
        if (ex.tag(it) != .int_literal) continue;
        if (ex.intLiteral(it).width != 0) any_sized = true;
    }
    if (!any_sized) return null;

    var acc: u64 = 0;
    var total: u64 = 0;
    for (items) |it| {
        if (std.mem.indexOfScalar(Ast.ExprId, effects.items, it) != null) continue;
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
    const folded = try ex.addIntLiteral(self.arena, tok, .{ .value = @bitCast(acc), .width = @intCast(total), .signed = false });
    if (effects.items.len == 0) return folded;
    // The zero groups first, the value last: `Lower.lowerConcat` evaluates
    // each group's operands once and answers the folded literal.
    try effects.append(self.arena, folded);
    const off = try ex.addExprList(self.arena, effects.items);
    return try ex.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
}

/// §2.7 string literal contents, with escapes processed, then §3.3's
/// literal→string conversion applied. Only allocates when the literal
/// actually contains a backslash.
///
/// The escape decode is `lexer.stringContents` and not a copy of it: a
/// second decoder here is what left `\ddd` (§2.7 Table 2-2) undecoded on
/// the live path, so `"\0"` became the character `0` while the lexer's
/// tested decoder had it right all along.
pub fn internString(self: *Parser, tok: u32) Error!Ast.StrId {
    const raw = tokenText(self, tok);
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
pub fn tokenText(self: *const Parser, i: u32) []const u8 {
    const lx: lexer.Lexer = .{ .src = self.src };
    const text = lx.tokenText(self.starts[i]);
    // §2.8.1: the `\` opens the identifier but is not part of the name.
    // The terminator is not in the span, so only the head is stripped.
    return if (self.tags[i] == .escaped_identifier) text[1..] else text;
}
