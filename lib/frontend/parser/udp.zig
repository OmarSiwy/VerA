//! Annex A.5 user-defined primitives (IEEE 1364-2005 Clause 8, inherited
//! through LRM §1.1): a `primitive … endprimitive` declaration in, one
//! `Ast.UdpDecl` with its table rows checked against A.5.3's alphabets out;
//! and A.5.4 UDP instances at module scope, kept for a digital parse only.
//! An analog compile has no event queue to run a table on, so an instance
//! warns W0252 there.
//!
//! LRM clauses cited: §1.1, §8.5.3; IEEE 1364-2005 §8, §8.1.2, §8.1.4, §8.4,
//! §8.8, Table 8-1.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_inst = @import("inst.zig");
const parse_module = @import("module.zig");
const parse_net = @import("net.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

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
    // E1017 refuses past `max_udp_inputs` inputs once the list is read, so
    // the ports past the array are counted, not kept.
    var ports: [max_udp_inputs + 1]Ast.StrId = undefined;
    var n_ports: usize = 0;
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
            _ = try parse_net.optDiscipline(self);
            if (self.eat(.kw_reg)) has_reg = true;
        }
        const port = try self.expectIdent();
        if (n_ports < ports.len) ports[n_ports] = port;
        n_ports += 1;
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
    if (n_ports - 1 > max_udp_inputs)
        return self.failAt(main_tok, .E1017, "`{s}` has {d} inputs", .{ self.file.str(name), n_ports - 1 });
    const port_ids = try self.arena.dupe(Ast.StrId, ports[0..n_ports]);
    // A.5.2's separate declarations, the first arm's. A.5.1 requires one or
    // more, but the second arm has none, so the count is not checked.
    while (true) {
        try self.skipAttributes();
        if (self.peek() != .kw_output and self.peek() != .kw_input and self.peek() != .kw_reg) break;
        const kw = self.peek();
        self.pos += 1;
        _ = try parse_net.optDiscipline(self);
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
    try checkUdpConflicts(self, name, rows.items, n_ports - 1, sequential, main_tok);
    if (!self.reservedIs(self.pos, "endprimitive"))
        return self.failAt(self.pos, .E0207, "found {s}: no `endprimitive` closes the declaration", .{self.found(self.pos)});
    self.pos += 1;
    return .{
        .name = name,
        .ports = port_ids,
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
fn parseUdpTable(self: *Parser, rows: *std.ArrayList(Ast.UdpRow)) Error!bool {
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
fn parseUdpEntry(self: *Parser, sequential: *?bool, rows: *std.ArrayList(Ast.UdpRow)) Error!void {
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

/// One input field of an entry as the concrete values it covers: a level
/// symbol as a set over {0, 1, x} (bit 0, 1, 2), an edge as a set over the
/// (from, to) transitions, bit `3 * from + to` (Table 8-1).
const UdpField = union(enum) { level: u3, edge: u9 };

fn udpLevelSet(c: u8) u3 {
    return switch (std.ascii.toLower(c)) {
        '0' => 0b001,
        '1' => 0b010,
        'x' => 0b100,
        'b' => 0b011,
        else => 0b111, // `?`: the alphabet check left nothing else
    };
}

/// Table 8-1's transitions between two level sets, a change only.
fn udpEdgeSet(from: u3, to: u3) u9 {
    var set: u9 = 0;
    for (0..3) |f| for (0..3) |t| {
        if (f != t and from & (@as(u3, 1) << @intCast(f)) != 0 and to & (@as(u3, 1) << @intCast(t)) != 0)
            set |= @as(u9, 1) << @intCast(3 * f + t);
    };
    return set;
}

/// Splits an entry's input characters into `out`, one field per input;
/// returns the field count, which may differ from the port count
/// (elaboration diagnoses that).
fn udpFields(inputs: []const u8, out: []UdpField) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < inputs.len) : (i += 1) {
        const f: UdpField = switch (std.ascii.toLower(inputs[i])) {
            '(' => blk: {
                if (i + 3 >= inputs.len) return out.len + 1;
                defer i += 3;
                break :blk .{ .edge = udpEdgeSet(udpLevelSet(inputs[i + 1]), udpLevelSet(inputs[i + 2])) };
            },
            'r' => .{ .edge = udpEdgeSet(0b001, 0b010) },
            'f' => .{ .edge = udpEdgeSet(0b010, 0b001) },
            // (01) (0x) (x1), and (10) (1x) (x0).
            'p' => .{ .edge = udpEdgeSet(0b001, 0b110) | udpEdgeSet(0b100, 0b010) },
            'n' => .{ .edge = udpEdgeSet(0b010, 0b101) | udpEdgeSet(0b100, 0b001) },
            '*' => .{ .edge = udpEdgeSet(0b111, 0b111) },
            else => .{ .level = udpLevelSet(inputs[i]) },
        };
        if (n == out.len) return n + 1;
        out[n] = f;
        n += 1;
    }
    return n;
}

/// IEEE 1364-2005 §8.1.4: "It is illegal to have the same combination of
/// inputs, including edges, specified for different outputs." Two entries
/// overlap where every field (and a sequential entry's current state)
/// covers a common value; they conflict where, on that overlap, their next
/// states differ, `-` reading as the current state. A level entry and an
/// edge entry never conflict: §8.8 lets the level entry dominate. Neither
/// do edge entries on different inputs, which one event cannot both match.
fn checkUdpConflicts(self: *Parser, name: Ast.StrId, rows: []const Ast.UdpRow, inputs: usize, sequential: bool, main_tok: u32) Error!void {
    var a_buf: [max_udp_inputs]UdpField = undefined;
    var b_buf: [max_udp_inputs]UdpField = undefined;
    for (rows, 0..) |a, i| {
        if (udpFields(a.inputs, &a_buf) != inputs) continue;
        for (rows[i + 1 ..], i + 1..) |b, j| {
            if (udpFields(b.inputs, &b_buf) != inputs) continue;
            const overlap = for (a_buf[0..inputs], b_buf[0..inputs]) |fa, fb| {
                const meet = switch (fa) {
                    .level => |la| switch (fb) {
                        .level => |lb| la & lb != 0,
                        .edge => false,
                    },
                    .edge => |ea| switch (fb) {
                        .level => false,
                        .edge => |eb| ea & eb != 0,
                    },
                };
                if (!meet) break false;
            } else true;
            if (!overlap) continue;
            const states: u3 = if (sequential) udpLevelSet(a.state) & udpLevelSet(b.state) else 0b001;
            for (0..3) |s| {
                if (states & (@as(u3, 1) << @intCast(s)) == 0) continue;
                const cur = "01x"[s];
                const out_a = if (a.output == '-') cur else std.ascii.toLower(a.output);
                const out_b = if (b.output == '-') cur else std.ascii.toLower(b.output);
                if (out_a == out_b) continue;
                try self.report(main_tok, .E0248, "`{s}`: entries {d} and {d} share an input combination and give it {c} and {c}", .{
                    self.file.str(name), i + 1, j + 1, out_a, out_b,
                });
                break;
            }
        }
    }
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
    const module_tok = self.pos;
    const module = try self.internTok(self.pos);
    self.pos += 1; // the udp_identifier
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_net.strengthWord(self, self.pos + 1) != null) try parse_net.parseDriveStrength(self, &s0, &s1);
    // A.2.2.3 `delay2` is a `delay3` that stops at two values.
    const delay_tok = self.pos;
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_net.parseDelay3(self) else .{};
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
        try ports.append(self.arena, .{ .expr = try parse_expr.parseNetLvalue(self), .main_tok = out_tok }); // A.3.3 output_terminal ::= net_lvalue
        while (self.eat(.comma)) {
            const in_tok = self.pos;
            try ports.append(self.arena, .{ .expr = try parse_expr.parseExpr(self), .main_tok = in_tok }); // input_terminal ::= expression
        }
        // A.5.4's unnamed instance is a UDP's, with an output and at least
        // one input terminal; anything else with no name is a module
        // instance missing A.4.1's name_of_module_instance (`child(s);`).
        if (name == .none and ports.items.len < 2)
            return self.failAt(module_tok, .E0293, "`{s}`, with one terminal", .{self.file.str(module)});
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
