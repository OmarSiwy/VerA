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
const Ast = @import("../ast.zig");
const parse_hier = @import("hier.zig");
const parse_concat = @import("concat.zig");
const parse_literal = @import("literal.zig");
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
            try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
            const then_e = try parseExpr(self);
            _ = try self.expect(.colon);
            const else_e = try parseExprPrec(self, prec_ternary);
            lhs = try self.file.exprs.add(self.arena, .{
                .tag = .ternary,
                .main_tok = tok,
                .lhs = lhs,
                .rhs = then_e,
                .extra = @backingInt(else_e),
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
        try self.ownedAttributes(.{ .kind = .expression, .tok = tok }); // A.8.3 binary suffix
        // §4.2.2: "All operators associate left to right with the exception
        // of the conditional operator". No `**` carve-out, so `2**3**2` is 64.
        const rhs = try parseExprPrec(self, prec + 1);
        lhs = try self.file.exprs.add(self.arena, .{
            .tag = .binary,
            .main_tok = tok,
            .lhs = lhs,
            .rhs = rhs,
            .extra = @backingInt(op),
        });
    }
}

/// A.8.6 unary_operator (§4.2.1, §4.2.7 to §4.2.10). Unary binds tighter than
/// every binary operator (Table 4-3, top row).
fn parseUnary(self: *Parser) Error!Ast.ExprId {
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
    try self.ownedAttributes(.{ .kind = .expression, .tok = tok }); // A.8.3 unary suffix
    const operand = try parseUnary(self);
    return self.file.exprs.add(self.arena, .{
        .tag = .unary,
        .main_tok = tok,
        .lhs = operand,
        .extra = @backingInt(op),
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

/// Parses IEEE 1364-2005 §5.3 / A.8.3 `mintypmax_expression ::= expression
/// | expression : expression : expression`, in a digital parse: in
/// parentheses wherever an expression is, and bare where A.2.2.3, A.2.4 and
/// A.7.4 write one (a `delay3` element, a specparam, a path delay). The tool
/// chooses one member of each triple; this one takes the typical, the
/// middle, whose compound expressions then all read their middle members.
/// An analog parse reads a plain expression and leaves any `:` unconsumed.
pub fn parseMinTypMax(self: *Parser) Error!Ast.ExprId {
    const e = try parseExpr(self);
    if (!self.digital or !self.eat(.colon)) return e;
    const typ = try parseExpr(self);
    _ = try self.expect(.colon);
    _ = try parseExpr(self);
    return typ;
}

/// Parses an A.8.4 analog_primary: a literal, parenthesized expression,
/// concatenation, assignment pattern, name, call or branch probe. A token
/// that begins none of them is E0209.
pub fn parsePrimary(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    // §10.6: a keyword the active set does not reserve is just a name, so
    // `sin` under "1364-2005" reads as a variable, not as §4.3.2's builtin.
    // (`tokenText` still switches on the real tag, so the spelling is exact.)
    const t = if (self.identLike(tok)) token.Tag.identifier else self.peek();
    switch (t) {
        .int_literal, .real_literal => return parse_literal.parseNumber(self),
        .string_literal => { // §2.7
            const s = try parse_literal.internString(self, tok);
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
        .lbrace => return parse_concat.parseConcat(self, tok),
        // A.8.1 assignment_pattern `'{ ... }` (§3.4.4 array defaults,
        // §4.5.6 filter coefficient args)
        .apostrophe_lbrace => return parse_concat.parseAssignPattern(self, tok),
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
                const binding_mark = self.file.attributes.items.len;
                try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
                if (self.peek() != .lparen) {
                    self.pos = before_attrs;
                    // The specs come with the cursor: this instance belongs
                    // to whatever follows and will be collected there.
                    self.attrs.shrinkRetainingCapacity(attr_mark);
                    self.file.attributes.shrinkRetainingCapacity(binding_mark);
                }
            }
            // A dotted name: a §6.8 hierarchical name, or a §5.5.3 Syntax 5-4
            // `nature_attribute_reference ::= net_identifier .
            // potential_or_flow . nature_attribute_identifier`. Both land in
            // `.hier_ident`; lowering tells them apart by resolving the parts.
            // IEEE 1364-2005 §12.5 an instance select, `g[0].l.x`: the part
            // is spelled `g[0]`, the name the digital engine registers.
            const head = if (parse_hier.instanceSelectAhead(self)) try parse_hier.parseInstanceSelect(self, name) else name;
            if (self.peek() == .dot) {
                var parts: std.ArrayList(Ast.StrId) = .empty;
                try parts.append(self.arena, head);
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
                    try parts.append(self.arena, if (parse_hier.instanceSelectAhead(self)) try parse_hier.parseInstanceSelect(self, part) else part);
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
    if (self.peek() == .attr_open) try self.ownedAttributes(.{ .kind = .expression, .tok = tok });
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
fn parseAccess(self: *Parser, name: Ast.StrId, tok: u32) Error!Ast.ExprId {
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
fn binOp(tag: token.Tag) ?Ast.BinaryOp {
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
