//! Expressions and literals: annex A.8.3 expression tokens -> `Ast.ExprId`s,
//! by precedence climbing (§4.1, §4.2.2), with §2.6 number, §2.7 string and
//! §2.8 identifier values decoded here, once.
//!
//! LRM clauses cited: §2.6.1, §2.6.2, §2.7, §3.2.2, §3.3, §4.1, §4.2, §4.2.2,
//! §4.2.10, §4.2.12, §4.2.13, §6.7.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_stmt = @import("stmt.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.8.3 expressions: LRM §4.1, §4.2 (precedence climbing)
// -----------------------------------------------------------------------

/// Parses a full expression, conditional operator included (§4.1, §4.2).
/// Fails with E0241 past `max_depth` nesting.
pub fn parseExpr(self: *Parser) Error!Ast.ExprId {
    return parseExprPrec(self, prec_ternary);
}

/// Precedence climbing over LRM Table 4-3 (§4.2.2).
fn parseExprPrec(self: *Parser, min_prec: u8) Error!Ast.ExprId {
    var lhs = try parseUnary(self);
    // Each operator folded into `lhs` makes its tree one level deeper, and
    // every later walk recurses down that spine: it counts against E0241.
    const base = self.depth;
    defer self.depth = base;
    while (true) {
        const t = self.peek();
        // §4.2.12 conditional: lowest precedence, right associative.
        if (t == .question and min_prec <= prec_ternary) {
            const tok = self.pos;
            try self.enter();
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
        // IEEE 1364-2005 A.8.3 `+:` / `-:` end an indexed part-select's base.
        if ((t == .plus or t == .minus) and self.peekAt(1) == .colon) return lhs;
        const op = binOp(t) orelse return lhs;
        const prec = binopPrec(op);
        if (prec < min_prec) return lhs;
        const tok = self.pos;
        try self.enter();
        self.pos += 1;
        try self.skipAttributes(); // A.8.3 `binary_operator { attribute_instance }`
        // §4.2.2: "All operators associate left to right with the exception
        // of the conditional operator". No `**` carve-out, so `2**3**2` is 64.
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

/// A.8.6 unary_operator (§4.2.1, §4.2.7 to §4.2.10). Unary binds tighter than
/// every binary operator (Table 4-3, top row).
pub fn parseUnary(self: *Parser) Error!Ast.ExprId {
    // Every expression recursion (parentheses, unary chains, `?:`) passes here.
    try self.enter();
    defer self.depth -= 1;
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
        // §4.2.10 reduction xor. Parsed like its siblings; lowering refuses it
        // with E0320, which names the subset rule.
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

/// Parses a primary followed by any §3.2.2/§3.4.4 selects: `base[i]`,
/// `base[msb:lsb]`.
pub fn parsePostfix(self: *Parser) Error!Ast.ExprId {
    var e = try parsePrimary(self);
    while (self.peek() == .lbracket) e = try parseSelect(self, e);
    return e;
}

/// One select on `base`, `[i]`, `[msb:lsb]` or IEEE 1364-2005 §5.2.1's
/// `[base +: width]` / `[base -: width]`, the cursor on the `[`.
pub fn parseSelect(self: *Parser, base: Ast.ExprId) Error!Ast.ExprId {
    const tok = try self.expect(.lbracket);
    var idx = try parseExpr(self);
    if (self.eat(.colon)) { // A.8.3 analog_range_expression
        const lsb = try parseExpr(self);
        idx = try self.file.exprs.add(self.arena, .{ .tag = .range, .main_tok = tok, .lhs = idx, .rhs = lsb });
    } else if (self.peek() == .plus or self.peek() == .minus) {
        const down = self.peek() == .minus;
        self.pos += 2; // `+:` or `-:`, which `parseExprPrec` stopped at
        const width = try parseExpr(self);
        idx = try self.file.exprs.add(self.arena, .{ .tag = .indexed_range, .main_tok = tok, .lhs = idx, .rhs = width, .extra = @intFromBool(down) });
    }
    _ = try self.expect(.rbracket);
    return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
}

/// Parses an A.8.4 analog_primary: a literal, parenthesized expression,
/// concatenation, assignment pattern, name, call or branch probe.
/// IEEE 1364-2005 §5.3 / A.8.3 `mintypmax_expression ::= expression
/// | expression : expression : expression`, in a digital parse: in
/// parentheses wherever an expression is, and bare where A.2.2.3, A.2.4 and
/// A.7.4 write one (a `delay3` element, a specparam, a path delay). The tool
/// chooses one member of each triple; this one takes the typical, the
/// middle, whose compound expressions then all read their middle members.
pub fn parseMinTypMax(self: *Parser) Error!Ast.ExprId {
    const e = try parseExpr(self);
    if (!self.digital or !self.eat(.colon)) return e;
    const typ = try parseExpr(self);
    _ = try self.expect(.colon);
    _ = try parseExpr(self);
    return typ;
}

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
            const e = try parseMinTypMax(self);
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
                // §3.6.3.2's bus nodeset admits a hole,
                // `electrical [0:4] bus = '{2.3,4.5,,6.0};`: "a null value in
                // the constant array indicates that no nodeset value is being
                // specified for this element". A.8.1 has no such alternative;
                // the clause's example governs. A hole is `.none`, which is
                // also what `Lower.fillPattern` gives a cell nothing reaches.
                const first = if (self.peek() == .comma) Ast.ExprId.none else try parseExpr(self);
                // A.8.1's second alternative:
                //
                //   assignment_pattern ::= '{ expression { , expression } }
                //                        | '{ constant_expression
                //                             { expression { , expression } } }
                //
                // one replication filling the whole pattern, as §4.2.14's
                // `'{ 5{0.0} }`. Nothing but `}` may follow the inner group.
                // The inner braces are plain `{`; a `'{` there is a row of a
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
            // (Example 7: `add (* mode = "cla" *) (b, c)`), and A.8.2 gives
            // `analog_function_call` the slot. Only a call has it, so the skip
            // is rolled back when no `(` follows: the attribute is then a
            // prefix on whatever comes next.
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
            // A dotted name: a §6.8 hierarchical name, or a §5.5.3 Syntax 5-4
            // `nature_attribute_reference ::= net_identifier .
            // potential_or_flow . nature_attribute_identifier`. Both land in
            // `.hier_ident`; lowering tells them apart by resolving the parts.
            if (self.peek() == .dot) {
                var parts: std.ArrayList(Ast.StrId) = .empty;
                try parts.append(self.arena, name);
                while (self.eat(.dot)) {
                    // Syntax 5-4's middle and last parts are annex B keywords
                    // (`potential`/`flow` and the §3.6.1.2 attribute names),
                    // the same list `parseNatureAttr` admits.
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
                // §6.7.1: "Analog user defined functions can be accessed
                // hierarchically." A dotted name with an argument list becomes
                // `.call` under the joined name, which is the flat name
                // elaboration gives the child's function because
                // `Elaborate.sep` is the same `.`. This join and
                // `Lower.flatName` must change together.
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
        // §4.4: "the generic potential and flow access functions are also
        // supported" (§5.5.1 Syntax 5-3). Parsed as `V(...)`/`I(...)` are;
        // lowering skips only the §3.6.1.4 name match. The words are annex B
        // keywords, so they arrive as their own tags and `real potential;`
        // cannot shadow them (§3.13.2).
        .kw_potential, .kw_flow => {
            const name = try self.file.intern(self.arena, token.Tag.lexeme(t).?);
            self.pos += 1;
            return parseAccess(self, name, tok);
        },
        // §2.8.3 / A.8.2 analog_system_function_call. `$name` with no
        // argument list is the same tag with an empty list.
        .system_identifier => {
            const name = try self.internTok(tok);
            self.pos += 1;
            // §6.2.1/§6.7 Syntax 6-9 `hierarchical_identifier ::= [ $root . ]
            // { identifier [ [ constant_expression ] ] . } identifier`. `$root`
            // anchors the path at the top of the instantiation tree; it rides
            // along as part 0 and `Lower.flatName`, which knows the root, strips it.
            if (self.eat(.dot)) return hierTerminal(self, &.{name}, tok);
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

    // Keyword-named calls. The groups are disjoint (token.zig's annex
    // A.8.2/A.6.5 test) and map one to one onto `ExprTag`.
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
    // calls so `ddt (* vera_lte = 0 *) (q)` can name one charge site, and
    // `absdelay (* vera_interp = 2 *) (x, td)` one delay.
    const mark = self.attrs.items.len;
    if (self.peek() == .attr_open) try self.skipAttributes();
    const lte = self.lteSince(mark);
    const args = try parseCallArgs(self);
    const id = try addCall(self, call_tag, tok, name, args);
    try self.keepLte(lte, .none, id);
    return id;
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
/// §5.6.8.2's spelling for a branch a child instance already owns,
/// `V(top.drv.branch(x,y)) <+ 1.2;`, as against §5.6.8.1's
/// `V(top.drv.x, top.drv.y)`, which creates a new branch in the writer.
/// Returns null, consuming nothing, when the lookahead is not that form.
///
/// The terminals are rewritten onto the instance path (`drv.x`, `drv.y`), so
/// everything downstream sees an ordinary terminal pair; the node is marked
/// `Ast.branch_ref_hier_unnamed` to keep the distinction.
///
/// ponytail: the rewrite makes the two spellings one branch. That is right for
/// a flow contribution (§5.6.1.2 sums them) and short of §5.6.8.2 for a
/// potential one, which should also discard what the child retained. The
/// upgrade is to attribute the contribution to the child's
/// `Ast.AnalogBlock.unit`, which `Lower.discardOpposite` already keys on.
/// The production's `( < port_identifier > )` alternatives are not parsed.
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

/// `prefix . id { . id }` as one `.hier_ident`, the cursor on the first `id`:
/// a `branch_terminal` of the production above, or any dotted name whose head
/// is already read.
fn hierTerminal(self: *Parser, prefix: []const Ast.StrId, tok: u32) Error!Ast.ExprId {
    var parts: std.ArrayList(Ast.StrId) = .empty;
    try parts.appendSlice(self.arena, prefix);
    try parts.append(self.arena, try self.expectIdent());
    while (self.eat(.dot)) try parts.append(self.arena, try self.expectIdent());
    const off = try self.file.exprs.addStrList(self.arena, parts.items);
    return self.file.exprs.add(self.arena, .{ .tag = .hier_ident, .main_tok = tok, .extra = off });
}

/// Parses an A.8.9 / A.2.1.3 branch terminal: a net or branch name, optionally
/// with a §5.5.2 bit select (`V(in[1])`).
///
/// The index is any expression: §5.5.2's "constant" admits a genvar, which is
/// constant only part-way through elaboration, so lowering folds it (E0352).
/// A §6.7.1 hierarchical terminal (`V(drv.a)`, `V($root.global_supply.vdd)`)
/// becomes a `.hier_ident`, `$root` included as part 0, as in `parsePrimary`.
///
/// ponytail: no index inside a path (`u[0].a`); adding one needs a
/// resolution rule, and `hier_ident` is already the shape it would use.
pub fn parseNetRef(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    const name = if (self.peek() == .system_identifier and self.tags[self.pos + 1] == .dot) blk: {
        const root = try self.internTok(self.pos);
        self.pos += 1;
        break :blk root;
    } else try self.expectIdent();
    // §6.7 + §5.5.2: in `V(u.v[1])` the select applies to the whole path.
    const base = if (self.eat(.dot))
        try hierTerminal(self, &.{name}, tok)
    else
        try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    if (self.peek() != .lbracket) return base;
    self.pos += 1;
    const idx = try parseExpr(self);
    _ = try self.expect(.rbracket);
    return self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = tok, .lhs = base, .rhs = idx });
}

/// Parses an A.8.2 / A.6.9 argument list, cursor on the `(`. An omitted
/// argument (`f(a, , c)`) becomes `.none`, so lowering can apply the
/// per-function defaults instead of guessing arity. The slice is arena-owned.
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
fn binopPrec(op: Ast.BinaryOp) u8 {
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
const prec_ternary: u8 = 1;

/// A.8.6 binary_operator → `Ast.BinaryOp`, null for a token that is not one.
/// `===`/`!==`/`<<<`/`>>>` are mapped, not rejected: lowering owns the annex
/// C.5 refusal.
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
// Literals: LRM §2.6 numbers, §2.7 strings, §2.8 identifiers
// -----------------------------------------------------------------------

/// §2.6.1 integer (incl. sized/based) and §2.6.2 real (exponent + SI scale
/// factor) literals. Values are computed here because the token stream
/// stores only {tag,start}.
fn parseNumber(self: *Parser) Error!Ast.ExprId {
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

    const text = self.tokenText(tok);
    // §2.6.2 decoding (`_` removal, the Table 2-1 scale factor) has one home,
    // `lexer.parseReal`. It applies the scale to the text and rounds once;
    // `mantissa * scale` would round twice and can be off by 1 ulp.
    const v = lexer.parseReal(text) catch |e| return switch (e) {
        error.LiteralTooLong => self.failAt(tok, .E0134, "", .{}),
        else => self.failAt(tok, .E0133, "`{s}`", .{text}),
    };
    return self.file.exprs.addReal(self.arena, tok, v);
}

/// The text `integer.parse` must see to name a malformed §2.6.1 number:
/// normally the token, or the token plus the one glued to it.
///
/// The lexer stops a number where §2.6.1 does, so the forms the clause calls
/// illegal (`4' h5`, `8'y11`, Example 1's `4af`) arrive as a literal plus a
/// separate token. When that token begins exactly where this one ends, the
/// user wrote one number, and the decoder names the rule it broke instead of
/// the parser asking for a `;` mid-number. `4 af` is not adjacent and keeps
/// that message. `.apostrophe_lbrace` is excluded: `2'{1}` is §4.2.14's
/// assignment pattern.
fn gluedNumberText(self: *const Parser, tok: u32) []const u8 {
    const text = self.tokenText(tok);
    const start = self.starts[tok];
    const next = self.starts[tok + 1]; // the stream always ends in `.eof`
    if (next != start + text.len) return text;
    switch (self.tags[tok + 1]) {
        // Only when the glued text is all hex digits, which makes it a number
        // with the base format left out. `1g` is not: §2.6.2's scale factors
        // have no `g`, so it is an integer followed by an identifier (E0207).
        .identifier => for (self.tokenText(tok + 1)) |c| {
            if (!lexer.isBasedDigit(c, 16)) return text;
        },
        // Only an apostrophe: a stray backtick is the preprocessor's, and
        // gluing it would decode as a bad digit and say so (E0133).
        .invalid => if (self.src[next] != '\'') return text,
        else => return text, // else: nothing else can be the glued remainder of a based number
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
/// Consumes `{ ... }` at the cursor and appends the group's operands to
/// `items`, flattened. Returns the count of a replication it cannot unroll
/// (a non-literal count, or any count in digital mode); `items` then holds
/// one copy of the inner operands.
///
/// The forms are told apart by the token after the first expression: a `{`
/// there opens a replication's inner concatenation (`{2+1{a}}` versus
/// `{2+1}`). In analog mode, literal counts are unrolled for §4.2.13 because
/// `foldBitConcat` needs every sized operand: `{4{2'b10}}` arrives as four
/// operands and `{{0{a}}, b}` as `{b}`. A nonconstant count stays a
/// `.multi_concat` (§3.3 Table 3-3 allows one for a string, `{i{"Hi"}}`).
/// Digital mode keeps every group and count unflattened.
fn braceOperands(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!?Ast.ExprId {
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
            // evaluate, so only a zero group over something else is kept, as
            // a `.multi_concat` that `foldBitConcat` gives no width.
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

/// `braceOperands` for positions that cannot pass a count upwards: a
/// nonconstant replication stays one operand instead of being returned.
fn braceGroup(self: *Parser, items: *std.ArrayList(Ast.ExprId)) Error!void {
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
fn multiConcat(self: *Parser, tok: u32, count: Ast.ExprId, items: []const Ast.ExprId) Error!Ast.ExprId {
    const off = try self.file.exprs.addExprList(self.arena, items);
    const inner = try self.file.exprs.add(self.arena, .{ .tag = .concat, .main_tok = tok, .extra = off });
    return self.file.exprs.add(self.arena, .{ .tag = .multi_concat, .main_tok = tok, .lhs = count, .rhs = inner });
}

/// Returns a replication count when it is an integer literal in 0..4096, else
/// null. §4.2.13 wants a "non-negative, non-x and non-z constant expression";
/// a literal is the only constant the parser can evaluate.
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

/// `replCount` for a concatenation's count, which §4.2.1 also lets be real:
/// "If a real expression is used for the replication factor of a
/// concatenation, the expression will first be converted to an integer value
/// using the rules described in 4.2.1.1": round to nearest, ties away from
/// zero, which is `@round`. So `{2.5{4'd3}}` is `{3{4'd3}}`.
///
/// Only a concatenation's: an A.8.1 assignment pattern is not one, and keeps
/// `replCount`. A negative real is a unary minus, not a literal, so it
/// reaches `lowerConcat` exactly as `{-5{a}}` does.
fn concatReplCount(self: *const Parser, e: Ast.ExprId) ?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .real_literal) return replCount(self, e);
    const r = @round(ex.realValue(e));
    if (!(r >= 0 and r <= 4096)) return null;
    return @intFromFloat(r);
}

/// Folds an analog §4.2.13 integer concatenation of sized literals into one
/// literal with the joined width. "Unsized constant numbers shall not be
/// allowed in concatenations", and in Verilog-A only a §2.6.1 sized constant
/// carries a width. Reports E0216 for an unsized operand and E0217 past 32
/// bits (§3.2.1).
///
/// Returns null in digital mode, when an operand is a logic literal (x/z or
/// wider than 64 bits), or when no operand is sized: `{a, b}` stays a
/// `.concat` for §4.5.11 filter coefficients, §3.2.2 array assignment and the
/// §3.3 Table 3-3 string form, which lowering handles.
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
        // §3.2.1: the result is a 32-bit integer; wider is diagnosed, not wrapped.
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

/// Interns token `tok`'s §2.7 string contents, escapes decoded by
/// `lexer.stringContents`, then (outside digital mode) §3.3's literal to
/// string conversion applied. Allocates only when the literal contains a
/// backslash.
pub fn internString(self: *Parser, tok: u32) Error!Ast.StrId {
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
    // the rest is kept, so `"hello\0world"` is `helloworld`, not a C-style
    // truncation at the NUL.
    var n: usize = 0;
    for (decoded) |c| {
        if (c == 0) continue;
        decoded[n] = c;
        n += 1;
    }
    return self.file.intern(self.arena, decoded[0..n]);
}
