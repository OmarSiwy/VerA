//! Annex A.4.1 module instantiation (LRM §6.2.2, §6.3), A.3 gate and switch
//! instances, and A.6.2 initial/always constructs.
//!
//! In: instance, gate, switch, `initial` and `always` tokens. Out: rows of
//! `parse_module.Body`.
//!
//! LRM clauses this file's code cites: §1.1, §2.9, §6.2.2, §6.3, §6.3.6, §7.1.5, §7.2, §7.2.2, §7.6, §7.7.3, §7.8, §7.12, §7.14, §8.5.3.5, §9.18.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

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
pub fn parseInstantiation(self: *Parser, b: *parse_module.Body) Error!void {
    const module = try self.internTok(self.pos);
    self.pos += 1;
    const params = try parseParamValueAssignment(self);

    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        const range: ?Ast.Dim = try parse_decl.optDim(self);
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
                    const e = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseExpr(self);
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
                        try parse_expr.parseExpr(self);
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
pub fn parseParamValueAssignment(self: *Parser) Error![]const Ast.ParamOverride {
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
                    const pname = try self.expectIdentOrSys();
                    _ = try self.expect(.lparen);
                    const v = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseExpr(self);
                    _ = try self.expect(.rparen);
                    try params.append(self.arena, .{ .name = pname, .value = v, .main_tok = tok });
                } else {
                    try params.append(self.arena, .{ .value = try parse_expr.parseExpr(self), .main_tok = tok });
                }
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
    }
    return params.items;
}

/// One shared diagnostic for what VerA leaves out at module scope although
/// A.1.4 derives it: an annex B spelling with no production here, a digital
/// `task` in an analog parse, a generate-case with no region above it …
pub fn unsupportedItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0205, "found {s}", .{self.found(self.pos)});
}

/// A.1.4: text no `module_item` alternative derives — a syntax error, not a
/// missing feature, so it is not E0205.
pub fn notAModuleItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0240, "found {s}", .{self.found(self.pos)});
}

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
pub fn parseGates(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
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
        else => unreachable, // else: the caller dispatched on exactly these
    };
    self.pos += 1;
    // Unlike `assign`, a `(` here is ambiguous: A.3.1 makes the instance
    // NAME optional, so `and (w, a, b);` opens a terminal list with the
    // same token A.2.2.2's drive strength opens. The word inside settles
    // it — A.2.2.2's alternatives all begin with a strength keyword, and no
    // terminal can, since those spellings are reserved words.
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_decl.strengthWord(self, self.pos + 1) != null) try parse_decl.parseDriveStrength(self, &s0, &s1);
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_decl.parseDelay3(self) else .{};
    while (true) {
        const tok = self.pos;
        // A.3.1 makes `name_of_gate_instance` optional; `(` after the name
        // tells the two apart, as in `parsePassSwitch`. A.3.1's
        // `name_of_gate_instance ::= gate_instance_identifier [ range ]` is
        // §7.1.5's instance array.
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            self.pos += 1;
            range = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        var terms: std.ArrayList(Ast.ExprId) = .empty;
        while (true) {
            try terms.append(self.arena, try parse_expr.parseExpr(self));
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
        // A.3.3 `output_terminal ::= net_lvalue`: a gate drives its outputs,
        // so each must be a net it can drive. buf/not lead with every
        // terminal but the last as an output; every other gate with one.
        const n_out = switch (kind) {
            .g_buf, .g_not => terms.items.len -| 1,
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => @min(terms.items.len, 1),
        };
        for (terms.items[0..n_out]) |out| if (!isNetLvalue(self, out)) return self.failAt(
            self.file.exprs.mainTok(out),
            .E0207,
            "found {s}: a gate's output terminal is a net_lvalue (A.3.3), a net the gate can drive",
            .{self.found(self.file.exprs.mainTok(out))},
        );
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
                    }, .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal , enable_terminal )`
            .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
                if (terms.items.len != 3) return self.failAt(tok, .E0209, "an enable gate takes an output, a data input and an enable", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal { , input_terminal } )`
            // — one input is enough, and IEEE 1364-2005 §7.2 says so in words:
            // "These six logic gates shall have one output and one or more
            // inputs."
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => {
                if (terms.items.len < 2) return self.failAt(tok, .E0209, "an n-input gate takes an output and at least one input", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .main_tok = tok });
            },
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.8.5 `net_lvalue`: a (hierarchical) net name with optional selects, or a
/// concatenation of net_lvalues.
fn isNetLvalue(self: *const Parser, e: Ast.ExprId) bool {
    const x = &self.file.exprs;
    return switch (x.tag(e)) {
        .ident, .hier_ident => true,
        .index => isNetLvalue(self, x.lhs(e)),
        .concat => for (x.args(e)) |a| {
            if (!isNetLvalue(self, a)) break false;
        } else true,
        else => false, // else: a literal, operator, call, access or pattern names no net; a new name form would be a new arm above
    };
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
pub fn gateNotModelled(self: *Parser) Error!void {
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
/// modelled by nothing (W0252). Each instance is recorded on `b.pulls`,
/// which the digital engine executes and an analog compile never reads.
pub fn parsePullGate(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
    // A.3.2's `strength0`/`strength1` name the side the gate pulls toward:
    // 0 for `pulldown`, 1 for `pullup`, which is also `StrengthWord.side`.
    const side: u8 = if (parse_module.reservedIs(self, self.pos, "pulldown")) 0 else 1;
    const main_tok = self.pos;
    self.pos += 1;
    // §7.8: "pull strength in the absence of a strength specification", and
    // only the strength on the side the source pulls toward is kept.
    var strength: Ast.Strength = .pull;
    if (self.peek() == .lparen and parse_decl.strengthWord(self, self.pos + 1) != null) {
        const tok = self.pos + 1;
        if (self.peekAt(2) == .comma) {
            var s0: Ast.Strength = .strong;
            var s1: Ast.Strength = .strong;
            try parse_decl.parseDriveStrength(self, &s0, &s1);
            strength = if (side == 1) s1 else s0;
        } else {
            self.pos += 1;
            const w = parse_decl.strengthWord(self, self.pos).?;
            self.pos += 1;
            _ = try self.expect(.rparen);
            if (w.side != side) return self.failAt(
                tok,
                .E0207,
                "a single-strength bracket on this gate is A.3.2's `( strength{d} )`",
                .{side},
            );
            strength = w.level;
        }
    }
    while (true) {
        // A.3.1 makes `name_of_gate_instance` optional here too; `(` after
        // the name tells the two apart, as in `parseGates`.
        if (self.identLike(self.pos)) self.pos += 1;
        _ = try self.expect(.lparen);
        const out = try parse_expr.parseNetRef(self); // A.3.3 output_terminal ::= net_lvalue
        try b.pulls.append(self.arena, .{ .out = out, .one = side == 1, .strength = strength, .main_tok = main_tok });
        _ = try self.expect(.rparen);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// The shape of one A.3.1 switch arm, which is all four of them differ by:
/// how many terminals an instance takes, how many of those are A.3.3
/// `net_lvalue`s (everything after them is an `expression`), and whether a
/// delay bracket precedes the instance list. `shape` is the A.3.4 class and
/// its instance's terminal list in words, for the diagnostic when an
/// instance closes its list early.
pub const SwitchArm = struct { terminals: u8, lvalues: u8, delay: bool, shape: []const u8 };

const cmos_shape = "a cmos switch (A.3.4 cmos_switchtype) takes an output, an input, an ncontrol and a pcontrol terminal";
const mos_shape = "a mos switch (A.3.4 mos_switchtype) takes an output, an input and an enable terminal";
const pass_shape = "a pass switch (A.3.4 pass_switchtype) takes two inout terminals";
const pass_en_shape = "a pass-enable switch (A.3.4 pass_en_switchtype) takes two inout terminals and an enable";

/// A.3.4's ten switch spellings, keyed the way annex B reserves them — by
/// SPELLING. Eight of the ten share `.kw_reserved` (`tran` and `rtran` are
/// the two with tags, because A.4.1 needed them before this did), so a tag
/// dispatch would have to be two dispatches; this is one.
pub const switch_arms = std.StaticStringMap(SwitchArm).initComptime(.{
    // `cmos_switchtype [delay3] ( output , input , ncontrol , pcontrol )`
    .{ "cmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true, .shape = cmos_shape } },
    .{ "rcmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true, .shape = cmos_shape } },
    // `mos_switchtype [delay3] ( output , input , enable )`
    .{ "nmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "pmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "rnmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "rpmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    // `pass_switchtype ( inout , inout )` — the one arm with no delay
    // bracket at all, which is why A.4.1 prints it on its own.
    .{ "tran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false, .shape = pass_shape } },
    .{ "rtran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false, .shape = pass_shape } },
    // `pass_en_switchtype [delay2] ( inout , inout , enable )`. `delay2` is
    // a `delay3` that stops at two values, which `parseDelay3` already
    // returns for a two-value list.
    .{ "tranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "tranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "rtranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "rtranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
});

/// A.3.1's four switch arms — the primitives whose output is a CONDUCTION
/// PATH rather than a computed value:
///
///     | cmos_switchtype    [delay3] cmos_switch_instance         { , … } ;
///     | mos_switchtype     [delay3] mos_switch_instance          { , … } ;
///     | pass_en_switchtype [delay2] pass_enable_switch_instance  { , … } ;
///     | pass_switchtype            pass_switch_instance          { , … } ;
///
///     cmos_switch_instance ::= [ name_of_gate_instance ] ( output_terminal ,
///             input_terminal , ncontrol_terminal , pcontrol_terminal )
///     mos_switch_instance ::= [ name_of_gate_instance ]
///             ( output_terminal , input_terminal , enable_terminal )
///     pass_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal )
///     pass_enable_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal , enable_terminal )
///
/// Only `tran`/`rtran` reached a production before this; the other eight
/// A.3.4 spellings were `E0205: unsupported module item`, which says "this
/// text is not derivable" about text the annex above derives — the same
/// wrong answer `gateNotModelled`'s docstring retired for A.3.1's computing
/// arms. §1.1 ("Verilog-AMS HDL consists of the complete IEEE Std 1364
/// Verilog specification") is what makes the grammar VerA's to read.
///
/// Every instance is recorded (`ModuleDecl.switches`) — not as an
/// `Ast.GateKind`: §7.12's strength REDUCTION and §7.6's bidirectional
/// conduction are neither of them a function of input bits. §8.5.3.5 puts
/// switch processing in the discrete simulation cycle, so the digital engine
/// runs it (under `--run`, and as a mixed module's discrete half); a compiled
/// analog device has no equation to stamp, and lowering says so (W0250) when
/// the module has no discrete half to carry it.
pub fn parseSwitch(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const spelling = parse_expr.tokenText(self, main_tok);
    const arm = switch_arms.get(spelling).?; // the caller dispatched on exactly these
    const kind = std.meta.stringToEnum(Ast.SwitchKind, spelling).?;
    self.pos += 1;
    const delay: Ast.Delay3 = if (arm.delay and self.peek() == .hash) try parse_decl.parseDelay3(self) else .{};
    while (true) {
        const inst_tok = self.pos;
        // A.3.1 makes `name_of_gate_instance ::= gate_instance_identifier
        // [ range ]` optional, and the fixture's `tran (a, b);` uses that
        // arm. `(` after the name tells the two apart, as in `parseGates`.
        if (self.identLike(self.pos)) {
            self.pos += 1;
            _ = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        const terms = try self.arena.alloc(Ast.ExprId, arm.terminals);
        for (terms, 0..) |*t, i| {
            // A list closed early is short by A.3.4's class, not by one
            // token: say which class and what its instance takes, as
            // `parseGates` does for the enable gates, rather than the bare
            // "unexpected `)`" `expect(.comma)` would give.
            if (i != 0 and self.peek() == .rparen) return self.failAt(inst_tok, .E0209, "{s}", .{arm.shape});
            if (i != 0) _ = try self.expect(.comma);
            // A.3.3: `output_terminal` and `inout_terminal` are
            // `net_lvalue`s and lead; `input_terminal`, `enable_terminal`,
            // `ncontrol_terminal` and `pcontrol_terminal` are all
            // `expression`, so `cmos (o, d, ~g, g)` is derivable and
            // `cmos (~o, d, ng, g)` is not.
            t.* = if (i < arm.lvalues) try parse_expr.parseNetRef(self) else try parse_expr.parseExpr(self);
        }
        _ = try self.expect(.rparen);
        try b.switches.append(self.arena, .{ .kind = kind, .terms = terms, .delay = delay, .main_tok = inst_tok });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.6.2 `initial_construct ::= initial statement` /
/// `always_construct ::= always statement` — §7.2.2's DISCRETE context.
///
/// Both keywords are module items of every module (A.1.4), and the body is
/// A.6.4's `statement`, whose digital forms (`#`, `wait`, `<=`, intra-
/// assignment timing) are admitted by `in_discrete` whatever the file's
/// extension. Whether a given discrete process can be EXECUTED is not a
/// grammar question: lowering answers it (`Lower.checkDiscreteContext`), with
/// the clause that decides it.
pub fn parseDiscrete(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const is_always = self.peek() == .kw_always;
    self.pos += 1;
    const saved = self.in_discrete;
    self.in_discrete = true;
    defer self.in_discrete = saved;
    const body = try parse_stmt.parseStmtNoNull(self);
    try b.discrete.append(self.arena, .{
        .is_always = is_always,
        .body = body,
        .main_tok = main_tok,
    });
}
