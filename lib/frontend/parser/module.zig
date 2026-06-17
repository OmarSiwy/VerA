//! Annex A.1.2 module_declaration, A.1.4 module_item, A.1.8 connectrules and
//! A.1.9 paramset: tokens from `module` to `endmodule` in, one `Ast.ModuleDecl`
//! (ports, declarations, instances, analog and digital blocks) out; likewise
//! one `Ast.ParamsetDecl` or `Ast.ConnectRulesDecl`.
//! LRM clauses cited: §2.9, §3.4, §3.7, §5.10.4, §6.2, §6.3.1, §6.4, §6.4.1,
//! §6.4.3, §6.5, §6.6, §7.7, §7.7.1, §9.18.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_generate = @import("generate.zig");
const parse_source = @import("source.zig");
const parse_inst = @import("inst.zig");
const parse_specify = @import("specify.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.1.2 module_declaration, LRM §6.2
// -----------------------------------------------------------------------

/// Parses one `module`, `macromodule` or `connectmodule` through `endmodule`
/// (LRM §6.2): the header's parameter port list and ports (§6.5), then the
/// module items.
///
/// Takes every attribute in `self.attrs`, including those collected before
/// the `module` keyword, and clears the list.
pub fn parseModule(self: *Parser) Error!Ast.ModuleDecl {
    const main_tok = self.pos;
    const is_connect = self.peek() == .kw_connectmodule;
    self.pos += 1; // 'module' | 'macromodule' | 'connectmodule'
    const name = try self.expectIdent();

    const saved_connect = self.in_connect_module;
    self.in_connect_module = is_connect;
    defer self.in_connect_module = saved_connect;

    var b: Body = .{};
    // A.1.3 `module_parameter_port_list ::= # ( parameter_declaration
    // { , parameter_declaration } )`. §6.2: "The optional list of parameter
    // definitions shall specify an ordered list of the parameters for the
    // module." A header parameter is an ordinary §3.4 parameter, so it goes
    // into the append-only `b.params` ahead of the body's, in source order.
    //
    // `parseParamDecl` already consumes the commas inside one declaration
    // (`parameter real a = 1, b = 2`) and A.1.3 separates declarations with
    // the same comma, so keep reading while `parameter` or `localparam`
    // follows the comma the inner loop stopped at.
    if (self.peek() == .hash) {
        self.pos += 1;
        _ = try self.expect(.lparen);
        while (self.peek() == .kw_parameter or self.peek() == .kw_localparam) {
            try parse_decl.parseParamDecl(self, &b.params);
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
    }
    const header_params = b.params.items.len;
    if (self.peek() == .lparen) try parsePortList(self, &b);
    _ = try self.expect(.semicolon);
    try parseModuleItems(self, &b, .kw_endmodule);
    _ = try self.expect(.kw_endmodule);
    // IEEE 1364-2005 §4.10.1, inherited by §1.1: "If any param_assignments
    // appear in a module_parameter_port_list, then any param_assignments that
    // appear in the module become local parameters and shall not be
    // overridden by any method." §3.4.5's localparam is exactly that.
    if (header_params != 0) for (b.params.items[header_params..]) |*p| {
        p.is_local = true;
    };
    try parse_generate.checkGenBlockNames(self, &b);
    try parse_generate.nameGenBlocks(self, &b);
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
        .event_toks = b.event_toks.items,
        .functions = b.functions.items,
        .analog = b.analog.items,
        .discrete = b.discrete.items,
        .assigns = b.assigns.items,
        .gates = b.gates.items,
        .pulls = b.pulls.items,
        .tasks = b.tasks.items,
        .switches = b.switches.items,
        .paths = b.paths.items,
        .timing_checks = b.timing_checks.items,
        // §2.9: every attr_spec seen since the last module. Attributes
        // before the `module` keyword (Syntax 2-7 puts a slot there) were
        // collected by `parseSource` and belong to this module too, which is
        // why the list is cleared at the end and not at the start.
        .attrs = attrs,
        .is_connect = is_connect,
    };
}

/// Parses one A.1.9 paramset_declaration (LRM §6.4):
///
///     paramset paramset_identifier module_or_paramset_identifier ;
///         { paramset_item_declaration } { paramset_statement }
///     endparamset
///
/// §6.4: "The paramset itself contains no behavioral code; all of the
/// behavior is determined by the associated module". The result holds the
/// paramset's own declarations and its `.name = expr;` overrides of the
/// module's parameters. Clears `self.attrs`.
pub fn parseParamset(self: *Parser) Error!Ast.ParamsetDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'paramset'
    const name = try self.expectIdent();
    const target = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var params: std.ArrayList(Ast.ParamDecl) = .empty;
    var aliasparams: std.ArrayList(Ast.AliasParam) = .empty;
    var vars: std.ArrayList(Ast.VarDecl) = .empty;
    var overrides: std.ArrayList(Ast.ParamsetOverride) = .empty;

    // ponytail: A.1.9's other two statement forms are read and dropped:
    // `paramset_local_identifier = expr ;` (§6.4.3's output variables, whose
    // value a host reports for the instance) and `analog_function_statement`.
    // Nothing downstream has an operating-point reporting path for them
    // (ch06_hierarchy/paramset_output_unsupported.va). The upgrade is an
    // output-variable table on the emitted device, parsed in this loop.
    while (true) {
        const mark = self.attrs.items.len;
        try self.skipAttributes();
        try parse_source.outsideDesignElement(self, "paramset");
        switch (self.peek()) {
            .eof, .kw_endparamset => break,
            .kw_parameter, .kw_localparam => {
                try parse_decl.parseParamDecl(self, &params);
                _ = try self.expect(.semicolon);
            },
            .kw_aliasparam => try aliasparams.append(self.arena, try parse_decl.parseAliasparam(self)),
            .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
                const first = vars.items.len;
                try parse_decl.parseVarDecl(self, &vars);
                _ = try self.expect(.semicolon);
                // §6.4.3 "Integer or real variables in the paramset declared
                // with descriptions are considered output variables".
                const described = for (self.attrs.items[mark..]) |a| {
                    if (std.mem.eql(u8, self.file.str(a.name), "desc")) break true;
                } else false;
                for (vars.items[first..]) |*v| v.desc = described;
            },
            // A.1.9 `paramset_statement ::= . module_parameter_identifier =
            // paramset_constant_expression ;` and its `. system_parameter_-
            // identifier` sibling (§9.18's `$mfactor` and friends), told
            // apart by the one token that spells a system name.
            .dot => {
                const tok = self.pos;
                self.pos += 1;
                const is_sys = self.peek() == .system_identifier;
                const pname = try self.expectIdentOrSys();
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
                _ = try self.expect(.semicolon);
                try overrides.append(self.arena, .{
                    .kind = if (is_sys) .system_param else .module_param,
                    .name = pname,
                    .value = value,
                    .main_tok = tok,
                });
            },
            // The two dropped statement forms, and only those. They are
            // skipped by tokens, not parsed: an output assignment's
            // right-hand side may use §6.4.3's `.module_output_variable`
            // spelling, which is not an expression anywhere else. The skip
            // is limited to what A.1.9 admits here, a variable assignment
            // (`ft = 3.0 * .gm;`: an identifier, then `=` or `[`) or a
            // §6.4.1 statement wrapping such assignments, so a misspelled
            // `paramter real rr;` is still refused.
            else => { // else: every other paramset statement, gated to what A.1.9 admits just below
                const legal = (self.identLike(self.pos) and
                    (self.peekAt(1) == .assign_eq or self.peekAt(1) == .lbracket)) or
                    switch (self.peek()) {
                        .kw_if, .kw_case, .kw_for, .kw_while, .kw_repeat, .kw_begin => true,
                        else => false, // else: not a statement keyword A.1.9 admits here
                    };
                if (!legal) try self.report(
                    self.pos,
                    .E0205,
                    "found {s} in a paramset body",
                    .{self.found(self.pos)},
                );
                try skipParamsetStatement(self);
            },
        }
    }
    _ = try self.expect(.kw_endparamset);
    // §2.9 attributes inside a paramset decorate its declarations, and
    // `NatureAttr` collection is per design element, so drop them with the
    // element.
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

/// Parses one A.1.8 connectrules_declaration (LRM §7.7):
///
///     connectrules connectrules_identifier ;
///         { connectrules_item }
///     endconnectrules
///     connectrules_item ::= connect_insertion | connect_resolution
///
/// Names are not resolved: the connect module of a §7.7.1 insertion and
/// the disciplines of a §7.7.2 resolution may be declared after the block
/// (A.1.2 puts no order on descriptions), so elaboration checks them
/// (`elaborate/resolve.zig`, `checkConnectRules`).
pub fn parseConnectRules(self: *Parser) Error!Ast.ConnectRulesDecl {
    const main_tok = self.pos;
    self.pos += 1; // 'connectrules'
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);

    var insertions: std.ArrayList(Ast.ConnectInsertion) = .empty;
    var resolutions: std.ArrayList(Ast.ConnectResolution) = .empty;
    while (!self.eat(.kw_endconnectrules)) {
        try parse_source.outsideDesignElement(self, "connectrules");
        const item_tok = try self.expect(.kw_connect);
        const first = try self.expectIdent();
        // Both item forms open with `connect identifier`. A `,` or
        // `resolveto` after it can only continue a connect_resolution: an
        // insertion puts a mode keyword, `#`, a direction, an identifier or
        // `;` there.
        if (self.peek() == .comma or self.peek() == .kw_resolveto) {
            // A.1.8 connect_resolution, §7.7.2.
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
            // A.1.8 connect_insertion, §7.7.1, with §7.7.4's mode and
            // §7.7.3's parameter list in their grammar slots.
            var ins: Ast.ConnectInsertion = .{ .module = first, .main_tok = item_tok };
            if (self.eat(.kw_merged)) {
                ins.mode = .merged;
            } else if (self.eat(.kw_split)) {
                ins.mode = .split;
            }
            ins.params = try parse_inst.parseParamValueAssignment(self);
            if (self.peek() != .semicolon) {
                // A.1.8 connect_port_overrides admits four direction
                // pairs (none/none, input/output, output/input,
                // inout/inout), so the first direction fixes the second.
                const a_dir: Ast.Direction = switch (self.peek()) {
                    .kw_input => .input,
                    .kw_output => .output,
                    .kw_inout => .inout,
                    else => .unspecified, // else: no direction keyword
                };
                if (a_dir != .unspecified) self.pos += 1;
                const a_tok = self.pos;
                const a = try self.expectIdent();
                // §7.8.3 connect_mode "can be one of two predefined values,
                // split or merged": a lone word in its slot, with no second
                // discipline after it, is a mode that is neither, not an
                // override that lost its comma.
                if (a_dir == .unspecified and self.peek() == .semicolon)
                    return self.failAt(a_tok, .E0207, "found {s}: a connect_mode is `merged` or `split`", .{self.found(a_tok)});
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

/// Skips one A.1.9 paramset statement by tokens: to the `;` that ends it,
/// balancing `(...)` (a `for` header holds two semicolons), `begin`/`end`
/// and `case`/`endcase`, and continuing over `else`, so a dropped
/// `if (c) begin ft = 1.0; end else ft = 2.0;` is one skip. A statement
/// that is a block ends at its `end`/`endcase`, which has no `;`.
///
/// Still reports E0237 for what §6.4.1 forbids a paramset: "Shall not use
/// access functions. Shall not use contribution statements or event control
/// statements. Shall not use named blocks." Skipping them silently would
/// accept them.
fn skipParamsetStatement(self: *Parser) Error!void {
    var depth: u32 = 0;
    while (true) : (self.pos += 1) {
        const what: ?[]const u8 = switch (self.peek()) {
            .kw_potential, .kw_flow => if (self.peekAt(1) == .lparen) "an access function" else null,
            .identifier => if (self.peekAt(1) == .lparen and self.access_names.contains(self.tokenText(self.pos))) "an access function" else null,
            .kw_begin => if (self.peekAt(1) == .colon) "a named block" else null,
            .contribute => "a contribution statement",
            .at => "an event control",
            else => null, // else: every other token is legal in a paramset statement
        };
        if (what) |w| try self.report(self.pos, .E0237, "{s}: found {s}", .{ w, self.found(self.pos) });
        switch (self.peek()) {
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
            else => {}, // else: any other token is inside the statement being skipped
        }
    }
}

/// Accumulators for one module body. Arena-owned; each list's `.items`
/// becomes a `ModuleDecl` slice, in source order.
pub const Body = struct {
    ports: std.ArrayList(Ast.Port) = .empty,
    /// The header is A.1.3's `list_of_port_declarations`, whose ports "shall
    /// not be redeclared within the body of the module" (§6.2).
    ansi: bool = false,
    params: std.ArrayList(Ast.ParamDecl) = .empty,
    aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
    vars: std.ArrayList(Ast.VarDecl) = .empty,
    nets: std.ArrayList(Ast.NetDecl) = .empty,
    branches: std.ArrayList(Ast.BranchDecl) = .empty,
    instances: std.ArrayList(Ast.Instance) = .empty, // §6.2.2
    defparams: std.ArrayList(Ast.Defparam) = .empty, // §6.3.1
    genvars: std.ArrayList(Ast.StrId) = .empty,
    events: std.ArrayList(Ast.StrId) = .empty, // §5.10.4
    event_toks: std.ArrayList(u32) = .empty,
    functions: std.ArrayList(Ast.FuncDecl) = .empty,
    analog: std.ArrayList(Ast.AnalogBlock) = .empty,
    discrete: std.ArrayList(Ast.DiscreteBlock) = .empty, // A.6.2, §7.2.2
    assigns: std.ArrayList(Ast.ContAssign) = .empty, // A.6.1
    gates: std.ArrayList(Ast.GateInst) = .empty, // A.3.1
    pulls: std.ArrayList(Ast.PullInst) = .empty, // A.3.1, §7.8
    tasks: std.ArrayList(Ast.Subroutine) = .empty, // IEEE 1364-2005 §10
    switches: std.ArrayList(Ast.SwitchInst) = .empty, // A.3.1, §7.6
    paths: std.ArrayList(Ast.SpecPath) = .empty, // A.7.2
    timing_checks: std.ArrayList(Ast.TimingCheck) = .empty, // A.7.5
    /// §6.6.1/§6.6.2 every named generate block of the module, with the
    /// generate construct it belongs to. Not part of `ModuleDecl`: nothing
    /// downstream reaches a generate scope by name (§6.6.3 hierarchical
    /// names are unimplemented), so only `checkGenBlockNames` reads it.
    gen_blocks: std.ArrayList(GenBlock) = .empty,
    /// A.4.2 every loop generate's index variable, checked to be a genvar
    /// at the end of the module, when every `genvar` declaration (hoisted
    /// out of nested blocks) is in `genvars`.
    gen_loops: std.ArrayList(GenBlock) = .empty,
    /// §6.6.3 "Each generate construct in a given scope is assigned a number.
    /// The number is 1 for the construct that appears textually first in that
    /// scope and increases by 1 for each subsequent construct." This scope's
    /// count so far; a generate block's own `Body` starts again at zero.
    gen_count: u32 = 0,
    /// The unnamed generate blocks of this scope still waiting for their
    /// `genblk<n>`: the clash rule needs every declaration of the scope, and a
    /// declaration may follow the construct (`parse_generate.nameGenBlocks`).
    gen_auto: std.ArrayList(GenAuto) = .empty,
};

/// One unnamed generate block and the number of its construct.
pub const GenAuto = struct { stmt: Ast.StmtId, n: u32 };

/// One `begin : name` from the `generate_block` production, whose name
/// declares a scope rather than a §5.3.2 statement label. Collected here
/// because no later stage can tell the two `begin`s apart.
pub const GenBlock = struct {
    name: Ast.StrId,
    tok: u32,
    /// `Parser.gen_construct` at the time: the outermost enclosing
    /// construct, so two arms of one `if`/`case` share it.
    construct: u32,
};

/// Parses A.1.3 list_of_ports or list_of_port_declarations (§6.5) into
/// `b.ports`. Both styles fall out of one loop: a direction keyword starts a
/// new declaration whose direction, discipline and range stick to the
/// following comma-separated names.
///
/// A.1.3 `port_expression ::= port_reference | { port_reference
/// { , port_reference } }` (§6.5.1: a port may be "a vector net formed as a
/// result of the concatenation operator") appends one `Ast.Port` per
/// port_reference.
fn parsePortList(self: *Parser, b: *Body) Error!void {
    _ = try self.expect(.lparen);
    if (self.eat(.rparen)) return;
    var dir: Ast.Direction = .unspecified;
    var disc: Ast.StrId = .none;
    var range: ?Ast.Dim = null;
    var signed = false;
    var var_storage: ?@FieldType(Ast.VarDecl, "storage") = null;
    // A list_of_ports entry has been read: the list is not A.1.3's
    // list_of_port_declarations, so no port_declaration may follow.
    var plain = false;
    while (true) {
        try self.skipAttributes();
        if (portDirection(self.peek())) |d| {
            if (plain) return self.failAt(self.pos, .E0207, "found {s}: a port_declaration cannot follow a list_of_ports port (A.1.3)", .{self.found(self.pos)});
            dir = d;
            b.ansi = true;
            self.pos += 1;
            var kind: Ast.NetKind = .wire;
            disc = try optPortType(self, &kind, &signed);
            // IEEE 1364-2005 §12.3.4: "The same syntax for input, inout, and
            // output declarations is used in the module header", so
            // A.2.1.2's variable arms (`output reg q`) are legal here too.
            var_storage = try parse_decl.optVarStorage(self, dir);
            if (var_storage != null) signed = self.eat(.kw_signed);
            // A.1.3 `inout [ range ] port_identifier {, port_identifier}`:
            // the range belongs to the declaration (§6.5.2
            // "electrical [3:0] a, b" declares two 4-bit ports).
            range = try parse_decl.optDim(self);
        }
        // A.1.3 `port ::= [ port_expression ] | ...`: an empty port_expression
        // is a null port, a header position nothing inside connects to (a
        // digital parse only; the analog pipeline has no such terminal).
        if (self.digital and dir == .unspecified and (self.peek() == .comma or self.peek() == .rparen)) {
            try b.ports.append(self.arena, .{ .name = .none, .main_tok = self.pos });
            plain = true;
            if (!self.eat(.comma)) break;
            continue;
        }
        // A.1.3 `port ::= [ port_expression ] | . port_identifier (
        // [ port_expression ] )`. The second alternative gives the port an
        // external name distinct from the internal nets it connects to.
        var external: Ast.StrId = .none;
        var close_named = false;
        if (self.eat(.dot)) {
            external = try self.expectIdent();
            _ = try self.expect(.lparen);
            close_named = true;
        }
        // ponytail: a concatenated port becomes N terminals, not one N-bit
        // terminal, the same model §3.6.3 vector ports get (`electrical
        // [1:0] p` is two terminals). The consecutive entries carry the
        // external port's width and member order.
        const concat = self.eat(.lbrace);
        const first = b.ports.items.len;
        while (true) {
            const tok = self.pos;
            const name = try self.expectIdent();
            if (var_storage) |storage| try parse_decl.varPort(self, b, storage, name, range, signed, tok);
            // A.1.3 `port_reference ::= port_identifier [ [
            // constant_range_expression ] ]`, a list_of_ports form (a digital
            // parse only; the analog pipeline has no partial terminal).
            var select: ?Ast.Dim = null;
            if (self.digital and dir == .unspecified and self.eat(.lbracket)) {
                const msb = try parse_expr.parseExpr(self);
                const lsb = if (self.eat(.colon)) try parse_expr.parseExpr(self) else msb;
                _ = try self.expect(.rbracket);
                select = .{ .msb = msb, .lsb = lsb };
            }
            try b.ports.append(self.arena, .{
                .select = select,
                .name = name,
                .direction = dir,
                .discipline = disc,
                .range = range,
                .external_name = external,
                .concat_rest = b.ports.items.len != first,
                .is_signed = signed,
                .main_tok = tok,
            });
            if (!concat or !self.eat(.comma)) break;
        }
        if (concat) _ = try self.expect(.rbrace);
        if (close_named) _ = try self.expect(.rparen);
        if (dir == .unspecified) plain = true;
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.rparen);
}

/// Returns the `Ast.Direction` of an A.2.1.2 port direction keyword, or null
/// for any other token.
pub fn portDirection(tag: token.Tag) ?Ast.Direction {
    return switch (tag) {
        .kw_input => .input,
        .kw_output => .output,
        .kw_inout => .inout,
        else => null, // else: not a port_direction keyword
    };
}

/// Parses the A.2.1.2 `[ discipline_identifier ] [ net_type | wreal ]
/// [ signed ]` prefix of a port declaration and returns the discipline, or
/// `.none`. The net type and `signed` are consumed and dropped.
pub fn optDiscipline(self: *Parser) Error!Ast.StrId {
    var kind: Ast.NetKind = .wire;
    var signed = false;
    return optPortType(self, &kind, &signed);
}

/// Same as `optDiscipline`, also storing the net type in `kind` (unchanged
/// when absent) and whether `signed` was present in `signed`. A discipline
/// is an identifier followed by another identifier (the first name), so one
/// token of lookahead decides.
pub fn optPortType(self: *Parser, kind: *Ast.NetKind, signed: *bool) Error!Ast.StrId {
    var disc: Ast.StrId = .none;
    if (self.peek() == .identifier and self.identLike(self.pos + 1)) {
        disc = try self.internTok(self.pos);
        self.pos += 1;
    }
    if (parse_decl.netKind(self.peek())) |k| {
        kind.* = k;
        self.pos += 1;
    } else if (self.reservedIs(self.pos, "wreal")) {
        // A.2.1.2's `[ net_type | wreal ]`: `wreal` is not an A.2.2.1
        // net_type, so `netKind` does not know it. Annex C.4/C.8 remove it
        // from the Verilog-A subset only; in Verilog-AMS §6.5.3 makes a wreal
        // port the way a real value crosses a module boundary.
        kind.* = .wreal;
        self.pos += 1;
    }
    signed.* = self.eat(.kw_signed);
    return disc;
}

// -----------------------------------------------------------------------
// A.1.4 module_item, LRM §6.2 and Clause 3
// -----------------------------------------------------------------------

/// Parses module items into `b` until `end`, `endmodule` or end of file,
/// recovering at the next statement after each failed item.
fn parseModuleItems(self: *Parser, b: *Body, end: token.Tag) Error!void {
    while (true) {
        try self.skipAttributes();
        const t = self.peek();
        if (t == end or t == .eof or t == .kw_endmodule) return;
        const before = self.pos;
        parseModuleItem(self, b) catch |e| {
            if (e == error.OutOfMemory) return e;
            self.recoverStatement(before);
        };
    }
}

/// Parses one A.1.4 module_item into `b`. A token that begins no item is
/// E0240.
pub fn parseModuleItem(self: *Parser, b: *Body) Error!void {
    try self.refuseAms();
    switch (self.peek()) {
        // §10.6: "can only be specified outside of a design element".
        .dir_begin_keywords, .dir_end_keywords => return self.failAt(
            self.pos,
            .E0202,
            "{s} inside a module",
            .{token.Tag.lexeme(self.peek()).?},
        ),
        // IEEE 1364 §19.6: "It shall be illegal for the `resetall directive
        // to be specified within a module or UDP declaration."
        .dir_resetall => return self.failAt(self.pos, .E0236, "", .{}),
        // A.4.2 loop_generate_construct / conditional_generate_construct.
        // §6.6: "Use of generate regions is optional. There is no semantic
        // difference in the module when a generate region is used", and the
        // clause's rcline2 example writes a bare `for` at module scope, so
        // these are not gated on having seen `generate`. Syntax 6-8 makes
        // the body a generate_block of module items, not statements, so
        // they do not go through `parseStmt`.
        .kw_for => try parse_generate.parseGenerate(self, b, .kw_for),
        .kw_if => try parse_generate.parseGenerate(self, b, .kw_if),
        // Syntax 6-8 case_generate_construct, like `for` and `if` above: a
        // statement is no module item, so a `case` here is a generate
        // construct inside a generate region or not (IEEE 1364-2005 A.1.4).
        .kw_case => try parse_generate.parseGenerate(self, b, .kw_case),
        // Not an item: a generate_block is only ever the body of the two
        // above (E0221). Kept as its own arm so the diagnostic can cite
        // Syntax 6-8 rather than blaming the analog subset.
        .kw_begin => return self.failAt(self.pos, .E0221, "", .{}),
        // §3.4 parameter / localparam (A.2.1.1)
        .kw_parameter, .kw_localparam => {
            // §6.6: a generate block "may not contain port declarations,
            // parameter declarations, specify blocks, or specparam
            // declarations", and Syntax 6-8's `module_or_generate_item`
            // admits `local_parameter_declaration` only. `localparam` is
            // therefore not gated: it carries no override the elaborator
            // would need before the block exists (§6.3).
            if (self.gen_depth > 0 and self.peek() == .kw_parameter)
                return self.failAt(self.pos, .E0229, "", .{});
            try parse_decl.parseParamDecl(self, &b.params);
            _ = try self.expect(.semicolon);
        },
        // §6.3.1 parameter_override (A.1.4). `defparam
        // list_of_defparam_assignments ;`, each assignment a hierarchical
        // parameter identifier and a constant expression.
        //
        // Nothing is resolved here: the path names a parameter of an
        // instance, which does not exist until elaboration, and §6.3.1's
        // "shall be a constant expression" is over the declaring module's
        // parameters. `ir/elaborate.zig` checks both, and reports a path
        // that names nothing (E0907).
        .kw_defparam => {
            self.pos += 1;
            while (true) {
                const tok = self.pos;
                // `true`: A.9.3 admits `u[0].g`, the parameter of one
                // element of an instance array, a flat name elaboration
                // mints.
                const path = try parse_decl.parseDottedName(self, true);
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
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
        .kw_aliasparam => try b.aliasparams.append(self.arena, try parse_decl.parseAliasparam(self)),
        // §3.2/§3.3 variable declarations (A.2.1.3)
        .kw_integer, .kw_real, .kw_string, .kw_realtime, .kw_time => {
            try parse_decl.parseVarDecl(self, &b.vars);
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
        // (§5.10.4). Named events are part of the Verilog-A subset: §5.10
        // lists them as one of the three kinds of analog event, and annex
        // C.7 excludes only digital behavior and events.
        .kw_event => {
            self.pos += 1;
            while (true) {
                try b.event_toks.append(self.arena, self.pos);
                try b.events.append(self.arena, try self.expectIdent());
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        // §3.12 branch declaration (A.2.1.3)
        .kw_branch => try parse_decl.parseBranchDecl(self, b),
        // §3.6.4 ground declaration (A.2.1.3 net_declaration)
        .kw_ground => {
            self.pos += 1;
            const disc = try optDiscipline(self);
            try parse_decl.parseNetNames(self, b, disc, .wire, true, .{}, false);
        },
        // §6.5.2 non-ANSI port declarations
        .kw_input, .kw_output, .kw_inout => try parse_decl.parsePortDecl(self, b),
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
            const kind = parse_decl.netKind(self.peek()).?;
            self.pos += 1;
            // A.2.1.3 puts an optional bracket right after the net type:
            // `charge_strength` on the `trireg` arms (§3.8 default
            // `medium`), `drive_strength` on the
            // list_of_net_decl_assignments arms. A.2.2.2's drive strengths
            // are all pairs and A.2.2.1's charge strengths one word, so a
            // comma after the first strength word tells them apart.
            // Anything else goes to `parseChargeStrength`, whose
            // diagnostics say what went wrong.
            //
            // IEEE 1364-2005 §7.10: "the strengths default to strong1 and
            // strong0", so no bracket reads the same as
            // `(strong1, strong0)` and needs no flag.
            var st: Ast.NetStrength = .{};
            if (self.peek() == .lparen) {
                if (parse_decl.strengthWord(self, self.pos + 1) != null and self.peekAt(2) == .comma) {
                    try parse_decl.parseDriveStrength(self, &st.strength0, &st.strength1);
                    st.drive = true;
                } else st.charge = try parse_decl.parseChargeStrength(self, kind);
            }
            // IEEE 1364-2005 §4.3.2's advisory `vectored | scalared`, which
            // Syntax 4-1 admits only in the alternatives that carry a range.
            const advisory = self.pos;
            const advised = self.eat(.kw_scalared) or self.eat(.kw_vectored);
            var signed = false;
            var ignored: Ast.NetKind = .wire;
            const disc = try optPortType(self, &ignored, &signed);
            if (advised and self.peek() != .lbracket)
                return self.failAt(advisory, .E0207, "§4.3.2: scalared and vectored are only legal on a vector net, which declares a range", .{});
            try parse_decl.parseNetNames(self, b, disc, kind, false, st, signed);
        },
        // A.6.1 `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
        // list_of_net_assignments ;`, a module item of every module (A.1.4).
        // Whether the net it drives can be executed is lowering's question
        // (`Lower.checkDiscreteContext`), not the grammar's.
        .kw_assign => {
            self.pos += 1;
            // A.8.5 `net_lvalue` begins with an identifier or a `{`, never a
            // `(`, so the parenthesis is unambiguously A.2.2.2's.
            var s0: Ast.Strength = .strong;
            var s1: Ast.Strength = .strong;
            if (self.peek() == .lparen) try parse_decl.parseDriveStrength(self, &s0, &s1);
            const delay: Ast.Delay3 = if (self.peek() == .hash) try parse_decl.parseDelay3(self) else .{};
            while (true) {
                const tok = self.pos;
                const target = try parse_expr.parseExpr(self);
                _ = try self.expect(.assign_eq);
                const value = try parse_expr.parseExpr(self);
                try b.assigns.append(self.arena, .{ .target = target, .value = value, .strength0 = s0, .strength1 = s1, .delay = delay, .main_tok = tok });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.semicolon);
        },
        .kw_reg => try parse_decl.parseRegDecl(self, &b.vars),
        // A.3.1 `gate_instantiation ::= … | pass_switchtype
        // pass_switch_instance { , pass_switch_instance } ;`: the two
        // A.3.4 switch spellings with tags of their own. The other eight
        // reach `parseSwitch` through the `.kw_reserved` arm below.
        .kw_tran, .kw_rtran => try parse_inst.parseSwitch(self, b),
        // A.3.1 `gate_instantiation`: the twelve A.3.4 gate types that
        // compute a logic value.
        .kw_and, .kw_nand, .kw_or, .kw_nor, .kw_xor, .kw_xnor, .kw_buf, .kw_not, .kw_bufif0, .kw_bufif1, .kw_notif0, .kw_notif1 => try parse_inst.parseGates(self, b),
        // A.6.2 `initial_construct` / `always_construct`, §7.2.2's discrete
        // context.
        .kw_initial, .kw_always => try parse_inst.parseDiscrete(self, b),
        // §5.2 analog construct / §4.7.1 analog function
        .kw_analog => try parse_decl.parseAnalog(self, b),
        // §4.7: "Each function can be an analog user-defined function or a
        // digital function (as defined in IEEE Std 1364 Verilog)." So a bare
        // `function` is a legal module item in any module; what §7.3.7
        // forbids is the call from the analog context, which `lowerUserCall`
        // refuses (E0436).
        //
        // A digital parse reads the 1364 declaration itself (packed ranges,
        // `automatic`, `reg` formals), which the analog function grammar
        // cannot carry.
        .kw_function => if (self.digital) try parse_decl.parseSubroutine(self, b, true) else try parse_decl.parseFuncDecl(self, b, self.pos, false),
        // A.4.2 generate_region, transparent per §6.6's "there is no
        // semantic difference": the items inside are plain module items and
        // the region introduces no scope. §6.6: "Generate regions do not
        // nest, and they may only occur directly within a module".
        // `gen_depth` counts construct bodies too, so a `generate` inside an
        // if-generate's block is refused by the same test (E0228).
        .kw_generate => {
            // Reported, then parsed anyway: the region has no scope, so
            // reading the inner one as if the keywords were absent is exact
            // recovery and keeps the stray `endgenerate` from becoming a
            // second error.
            if (self.gen_depth > 0) try self.report(self.pos, .E0228, "", .{});
            self.pos += 1;
            self.gen_depth += 1;
            defer self.gen_depth -= 1;
            try parseModuleItems(self, b, .kw_endgenerate);
            _ = try self.expect(.kw_endgenerate);
        },
        // A.2.1.3 `discipline_identifier list_of_net_identifiers ;`
        // vs A.4.1 module_instantiation: both start with an identifier.
        .identifier, .escaped_identifier => {
            // A `#` can only be a parameter_value_assignment, and
            // `identifier identifier` followed by `(` or `[` can only be a
            // module_instance: A.2.1.3's net declaration puts its optional
            // range before the name list (`electrical [0:3] bus;`, which is
            // the `lbracket` case one line below), never after it, so no net
            // declaration reaches a `[` in that position.
            //
            // `#` followed by anything but `(` is A.5.4's `delay2` (`#5`),
            // which A.4.1's `parameter_value_assignment ::= # ( … )` never is.
            if ((self.peekAt(1) == .hash and self.peekAt(2) == .lparen) or
                (self.identLike(self.pos + 1) and
                    (self.peekAt(2) == .lparen or self.peekAt(2) == .lbracket)))
                return parse_inst.parseInstantiation(self, b);
            if (self.peekAt(1) == .hash) return parse_source.parseUdpInst(self, b);
            // A.5.4 `udp_instantiation`, whose `udp_instance` makes
            // `name_of_udp_instance` optional where A.4.1's `module_instance
            // ::= name_of_module_instance ( … )` does not. So an identifier
            // followed directly by `(` derives from A.5.4 and from nothing
            // else at module scope, and one token settles it.
            if (self.peekAt(1) == .lparen) return parse_source.parseUdpInst(self, b);
            // `discipline [range] names ;`. A range after the name is
            // refused by the name list ("expected identifier").
            if (!self.identLike(self.pos + 1) and self.peekAt(1) != .lbracket) {
                return parse_inst.notAModuleItem(self);
            }
            const disc = try self.internTok(self.pos);
            self.pos += 1;
            try parse_decl.parseNetNames(self, b, disc, .wire, false, .{}, false);
        },
        // Annex B reserves 1364 spellings that have no tag of their own:
        // `specify`, `specparam`, `primitive`, `pulldown` and the rest all
        // lex to `.kw_reserved`, which keeps them unusable as identifiers.
        // The spelling is therefore the dispatch.
        .kw_reserved => {
            const w = self.tokenText(self.pos);
            if (std.mem.eql(u8, w, "specify")) return parse_specify.parseSpecifyBlock(self, b);
            // A.2.1.1 `specparam_declaration ::= specparam [ range ]
            // list_of_specparam_assignments ;`, reached both as a module
            // item (Syntax 6-1's `non_port_module_item`) and as an A.7.1
            // `specify_item`. This is the module-item half.
            if (std.mem.eql(u8, w, "specparam")) return parse_specify.parseSpecparamDecl(self, &b.params);
            // A.2.7 `task_declaration`, IEEE 1364-2005 §10.2: a module item
            // of every module (A.1.4), enabled only from §7.2.2's discrete
            // context (A.6.4 has no analog `task_enable`), so its body is
            // parsed with that context's statement forms. The mixed-signal
            // kernel runs it; the analog compile only reads what it writes.
            if (std.mem.eql(u8, w, "task")) {
                const saved = self.in_discrete;
                self.in_discrete = true;
                defer self.in_discrete = saved;
                return parse_decl.parseSubroutine(self, b, false);
            }
            // A.3.1's last two arms. They have no tags of their own because
            // A.3.2 gives them a strength set no other gate takes.
            if (std.mem.eql(u8, w, "pulldown") or std.mem.eql(u8, w, "pullup"))
                return parse_inst.parsePullGate(self, b);
            // A.3.1's cmos/mos/pass-enable switch arms: A.3.4's eight
            // remaining `*_switchtype` spellings.
            if (parse_inst.switch_arms.has(w)) return parse_inst.parseSwitch(self, b);
            // A.2.1.3's two `wreal` arms: §3.7's real net, which the annex
            // gives arms of its own rather than a `net_type`.
            if (std.mem.eql(u8, w, "wreal")) return parseWrealDecl(self, b);
            return parse_inst.unsupportedItem(self);
        },
        else => return parse_inst.notAModuleItem(self), // else: begins no A.1.4 module_item: E0240
    }
}

/// Parses A.2.1.3's two `wreal` alternatives, §3.7's real net, into
/// `b.nets`:
///
///     | wreal [ discipline_identifier ] [ range ] list_of_net_identifiers ;
///     | wreal [ discipline_identifier ] [ range ] list_of_net_decl_assignments ;
///
/// `wreal` is not an A.2.2.1 `net_type`, so it takes no strength bracket and
/// no `vectored`/`scalared`. Annex C.4 removes it from the Verilog-A subset
/// only; in Verilog-AMS §3.7 lets the analog block read one.
pub fn parseWrealDecl(self: *Parser, b: *Body) Error!void {
    self.pos += 1;
    // `[ discipline_identifier ]`: an identifier followed by another
    // identifier, `optPortType`'s lookahead.
    var ignored: Ast.NetKind = .wire;
    var signed = false;
    const disc = try optPortType(self, &ignored, &signed);
    try parse_decl.parseNetNames(self, b, disc, .wreal, false, .{}, signed);
}
