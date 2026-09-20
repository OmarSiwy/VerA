//! Annex E.2 — reading SPICE `.MODEL` and `.SUBCKT` STATEMENTS.
//!
//! E.1.1 is one implication: "IF a simulator which supports Verilog-AMS HDL is
//! also able to read SPICE netlists of a particular flavor, THEN certain objects
//! defined in that flavor of SPICE netlist can be referenced from within a
//! Verilog-AMS HDL structural description." This file is what makes the
//! antecedent TRUE for one subset of one flavor, so that the consequent — E.2's
//! "the subcircuits and models contained within the SPICE netlist are treated as
//! module definitions" — has objects to range over.
//!
//! WHAT IT IS NOT. It is not a netlist parser and does not become one. There is
//! no device card, no `.TRAN`/`.DC`/`.OP`, no `.INCLUDE`/`.LIB`, no `.PARAM`
//! expression evaluator and no dialect tokenizer. E.2's noun phrase is
//! "subcircuits and models ... treated as module definitions", and a module
//! definition is an INTERFACE plus a body; the two cards this reads are exactly
//! the two that declare an interface. Everything else on the line is SKIPPED
//! silently rather than diagnosed, because a netlist VerA only mines for
//! declarations is not a netlist VerA claims to simulate — refusing a `.TRAN`
//! would be claiming jurisdiction this file does not have.
//!
//! WHY IT SYNTHESIZES TEXT instead of building declarations. Same argument as
//! `Preprocessor.spice_primitives`, which this extends and which is worth reading
//! first: E.2 says SPICE objects "shall be treated in the same manner in
//! Verilog-AMS HDL as built-in primitives", the manner is instantiation, and a
//! module that arrives as prepended SOURCE gets §6.3 overrides, §6.5.5 named
//! connection, §6.2.2 elaboration, §6.7.1 hierarchical access and every
//! diagnostic in those clauses from the code that already implements them. A
//! side-table of names gets none of them and has to reimplement each.
//!
//! EVERYTHING IS LOWER-CASED AT INGEST. SPICE is case-insensitive (E.2.1 first
//! sentence), so the netlist's own spelling carries no information and keeping it
//! would only invite an exact match to succeed by luck. One canonical case at the
//! door is what lets E.2.1's second sentence — "if no exact match is found, the
//! mixed-case name shall match the same name defined within SPICE regardless of
//! the case" — be a single ASCII-case-insensitive compare in
//! `elaborate.findModule`, and it makes the rule apply to PORT spellings too:
//! `.SUBCKT ECPOSC (OUT GND)` is reachable as `osc1.out` because the port is
//! named `out` by the time the parser sees it.
//!
//! A NAME THAT IS A KEYWORD IS SPELLED §2.8.1. SPICE has no reserved words, so
//! `.SUBCKT AMP (INPUT OUTPUT)` and `.MODEL WIRE NPN` are ordinary cards while
//! `input`, `output` and `wire` are annex B keywords. Synthesizing them bare
//! puts an E0208 on a line the user never wrote, which contradicts the premise
//! above — so `spell` writes them as escaped identifiers, which §2.8.2 says are
//! never keywords. It is a spelling and not a rename: §2.8.1 makes neither the
//! backslash nor the terminating white space part of the identifier, so the
//! name is unchanged for `elaborate.findModule` and for §6.7.1, and E.3
//! connects the ports by ORDER, so the escape never has to be typed to make a
//! connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");

/// Prelude text plus how many module declarations it holds. The count is what
/// `Ast.SourceFile.netlist_modules` records; it cannot be derived at comptime the
/// way `Preprocessor.spice_module_count` is, because the text depends on the
/// netlist the caller supplied.
pub const Synthesized = struct {
    text: []const u8 = "",
    modules: u32 = 0,
};

/// E.2.2.1: ".MODEL statements can be accessed in Verilog-AMS HDL ... The ports
/// and parameters of the bjt are determined by the bjt primitive itself and not
/// by the model statement." So a model card contributes a NAME and a primitive
/// TYPE, and the interface comes from Table E.1's row for that type — which is
/// why the port lists live here as text rather than being read off the card.
///
/// The rows are the SPICE model-type letters, mapped to the Table E.1 primitive
/// each names. Absent types (`sw`, `ltra`, `core`, ...) are skipped cards, not
/// errors: E.1.2's first bullet makes the recognised flavor "solely determined by
/// the authors of the simulator".
///
/// `ports` is pre-joined in Table E.1's order, which E.3 makes normative for
/// connection by order. A test below pins each row against
/// `Preprocessor.spice_primitives`, so this table cannot drift from the modules
/// it names.
const model_types = [_]struct { type_: []const u8, prim: []const u8, ports: []const u8 }{
    .{ .type_ = "npn", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "pnp", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "d", .prim = "diode", .ports = "a, c" },
    .{ .type_ = "nmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "pmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "njf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "pjf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "nmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "pmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "r", .prim = "resistor", .ports = "p, n" },
    .{ .type_ = "c", .prim = "capacitor", .ports = "p, n" },
    .{ .type_ = "l", .prim = "inductor", .ports = "p, n" },
};

/// Read `netlist` and return Verilog-AMS module text for every `.MODEL` and
/// `.SUBCKT` card in it. Never fails on malformed input — a line this does not
/// understand contributes nothing.
pub fn synthesize(arena: Allocator, netlist: []const u8) Allocator.Error!Synthesized {
    if (netlist.len == 0) return .{};

    // One lowered copy up front (E.2.1: SPICE is case-insensitive), so every
    // slice below is already canonical and nothing has to remember to fold.
    // ponytail: ASCII folding is the ceiling; use a different fold only for a new dialect.
    const lower = try std.ascii.allocLowerString(arena, netlist);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\// Annex E.2 — synthesized from the `//! spice` cards of this compilation;
        \\// see `spice_cards.synthesize` for what of a netlist is read and what is not.
        \\
        \\
    );
    var count: u32 = 0;
    // Emitted names, so a netlist that repeats a card does not declare the same
    // module twice — a shape whose meaning nothing here defines, and which would
    // be a defect reported against a file the user did not write. First card
    // wins; which one a real SPICE keeps is dialect-dependent, and E.1.2's first
    // bullet leaves that to "the authors of the simulator".
    var seen: std.ArrayList([]const u8) = .empty;

    // `+` continuations make a card longer than a line, so the cards are
    // assembled first and read second.
    var cards: std.ArrayList([]const u8) = .empty;
    var logical: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, lower, '\n');
    while (lines.next()) |raw| {
        const line = strip(raw);
        if (line.len == 0) continue;
        if (line[0] == '+') {
            // Joins the card under construction. A `+` with nothing above it has
            // nothing to continue and is dropped.
            if (logical.items.len != 0) {
                try logical.append(arena, ' ');
                try logical.appendSlice(arena, std.mem.trim(u8, line[1..], " \t"));
            }
            continue;
        }
        if (logical.items.len != 0) try cards.append(arena, try arena.dupe(u8, logical.items));
        logical.clearRetainingCapacity();
        try logical.appendSlice(arena, line);
    }
    if (logical.items.len != 0) try cards.append(arena, logical.items);

    for (cards.items) |card| {
        if (try emitCard(arena, &out, card, &seen)) count += 1;
    }

    if (count == 0) return .{};
    return .{ .text = out.items, .modules = count };
}

/// One physical line with its comments removed: `*` is a full-line comment, `;`
/// and `$` start a trailing one.
fn strip(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len != 0 and line[0] == '*') return "";
    if (std.mem.indexOfAny(u8, line, ";$")) |at| line = std.mem.trim(u8, line[0..at], " \t");
    return line;
}

/// One complete card. Returns true if it produced a module.
fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: []const u8,
    seen: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    // `(` `)` and `,` are noise in a SPICE port list: E.2.2.2's own example
    // writes `.SUBCKT ECPOSC (OUT GND)` with parentheses that carry no meaning.
    var it = std.mem.tokenizeAny(u8, card, " \t(),");
    const kw = it.next() orelse return false;
    const is_model = std.mem.eql(u8, kw, ".model");
    if (!is_model and !std.mem.eql(u8, kw, ".subckt")) return false; // a device card, .tran, .include, ...

    const name = it.next() orelse return false;
    if (!isSpiceName(name)) return false;
    for (seen.items) |s| if (std.mem.eql(u8, s, name)) return false;
    // `seen` keeps the bare name — the escape is a spelling of it, not another
    // name, so two cards named `wire` are still a repeat.
    const decl = try spell(arena, name);

    if (is_model) {
        const type_ = it.next() orelse return false;
        const row = for (model_types) |r| {
            if (std.mem.eql(u8, r.type_, type_)) break r;
        } else return false;
        // E.2.2.1: the interface is the primitive's. The body INSTANTIATES the
        // primitive, so whatever Table E.1's Behavior column gives that row is
        // what the model gives too — an empty column (bjt, mosfet, diode, ...)
        // simply gives nothing, which E.2 already says is implementation
        // dependent. The card's `BF=80 IS=1E-18` parameters are NOT passed: Table
        // E.1 declares none of them, and E.1.2's fourth axis of incompatibility
        // is that "the mathematical description of the built-in primitives can
        // differ", so there is no equation here for them to enter.
        // ponytail: model parameters are read and dropped; binding them needs
        // per-type parameter equations the annex does not write down.
        try out.print(arena,
            \\module {s}({s});
            \\   inout {s};
            \\   electrical {s};
            \\   {s} prim({s});
            \\endmodule
            \\
            \\
        , .{ decl, row.ports, row.ports, row.ports, row.prim, row.ports });
    } else {
        // `.SUBCKT name p1 p2 ... [params: k=v]` — ports up to the first thing
        // that is not a node name. NUMERIC nodes are the SPICE default (`1`,
        // `2`, `0`), so a digit does not end the list — only a parameter does.
        var ports: std.ArrayList([]const u8) = .empty;
        while (it.next()) |t| {
            if (!isSpiceName(t)) break; // `params:`, `k=v`
            try ports.append(arena, try spell(arena, t));
        }
        // A.1.2 makes the port list optional, so a portless `.SUBCKT` is a legal
        // module — and an empty `electrical ;` would not be.
        if (ports.items.len == 0) {
            try out.print(arena, "module {s};\nendmodule\n\n", .{decl});
        } else {
            const list = try std.mem.join(arena, ", ", ports.items);
            // EMPTY BODY. The subcircuit's contents are device cards written in
            // SPICE, which this reader does not read (see the file docstring), so
            // the module contributes no equations: under `//! solve` an instance
            // of it is an open circuit. What it does carry is the thing E.2 calls
            // for — the interface, in order, so §6.5.4 ordered connection and
            // §6.7.1 hierarchical access both work on it.
            try out.print(arena,
                \\module {s}({s});
                \\   inout {s};
                \\   electrical {s};
                \\endmodule
                \\
                \\
            , .{ decl, list, list, list });
        }
    }
    try seen.append(arena, name);
    return true;
}

/// Is `t` usable BARE as a Verilog-AMS identifier (§2.7) after lowering? `$` is
/// not admitted even though §2.7 allows it in an identifier: `strip` has
/// already treated it as a comment opener, so it cannot reach here.
fn isIdent(t: []const u8) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isAlphabetic(t[0]) and t[0] != '_') return false;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Is `t` a SPICE name at all — a model/subcircuit name or a node? SPICE names
/// routinely LEAD WITH DIGITS (`2N2222`, `1N4148`), and bare numbers are the
/// default node spelling, so §2.7 shape is not the test: anything printable
/// that is not a parameter (`k=v`, `params:`) qualifies, and `spell` below
/// decides how it has to be written. Rejecting these silently dropped the card
/// (a later E0904 then blamed the USER's instantiation line) or truncated a
/// `.SUBCKT F A 1 B` port list to one port — a silently WRONG ordered binding.
fn isSpiceName(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| if (c < 33 or c > 126 or c == '=' or c == ':') return false;
    return true;
}

/// How `t` has to be WRITTEN to declare it here. `isIdent` above is §2.7 SHAPE
/// only, and shape is not enough in either direction: a SPICE netlist has no
/// reserved words, so a perfectly ordinary card can name a node `INPUT` or a
/// model `WIRE` — and no §2.7 shape rule either, so a model is `2N2222` and a
/// node is `1`. The keyword spellings become keywords the moment they are
/// lowered into Verilog-AMS text, the digit-leading ones are not simple
/// identifiers at all, and either way the diagnostic lands on a synthesized
/// line with no author.
///
/// §2.8.1's escape is the LRM's own answer, and it is the whole fix: an escaped
/// identifier "can include any printable ASCII character", §2.8.2 lists what is
/// a keyword and an escaped identifier is not among them, and neither the
/// leading `\` nor the terminating white space is part of the NAME — so
/// `elaborate.findModule`, §6.5.4's connection by order and §6.7.1's dotted
/// probe all still see `wire`, `input`, `2n2222` and `1`. The trailing space is
/// the §2.8.1 terminator and is load-bearing: `,` and `)` are printable ASCII
/// and would otherwise be scanned INTO the identifier.
fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    // ponytail: share the lexer's keyword lookup; extend the common table for new keywords.
    if (isIdent(t) and token.lookupKeyword(t) == null) return t;
    return std.fmt.allocPrint(arena, "\\{s} ", .{t});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "model_types names a real Table E.1 module with the ports it lists" {
    // The one thing this file can get wrong silently: a row whose primitive or
    // port order does not match the prelude it claims to transcribe.
    const prelude = @import("preprocessor.zig").spice_primitives;
    for (model_types) |r| {
        const header = try std.fmt.allocPrint(
            std.testing.allocator,
            "module {s}({s});",
            .{ r.prim, r.ports },
        );
        defer std.testing.allocator.free(header);
        try std.testing.expect(std.mem.indexOf(u8, prelude, header) != null);
    }
}

test "a .MODEL card becomes a module with the primitive's ports, a .SUBCKT with its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\* a comment line
        \\.MODEL VERTNPN NPN BF=80 IS=1E-18 RB=100 VAF=50
        \\+ CJE=3PF CJC=2PF ; trailing comment
        \\.SUBCKT ECPOSC (OUT GND)
        \\VA VCC GND 5
        \\R1 B1 GND 10K
        \\.ENDS ECPOSC
        \\.TRAN 1N 100N $ skipped, not diagnosed
    );
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // E.2.2.1: ports from the bjt primitive, in Table E.1's order.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module vertnpn(c, b, e, s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bjt prim(c, b, e, s);") != null);
    // E.2.2.2: ports from the card, lowered, parentheses dropped, no body.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module ecposc(out, gnd);") != null);
    // The card's model parameters are not passed, and the device cards inside the
    // subcircuit contribute nothing.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bf") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "vcc") == null);
}

test "a card naming a keyword is declared as a §2.8.1 escaped identifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT AMP (INPUT OUTPUT)
        \\.ENDS AMP
        \\.MODEL WIRE NPN BF=80
    );
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // The terminator is the point: `\input,` would scan the comma into the
    // name (§2.8.1 ends at white space, and `,` is printable ASCII).
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module amp(\\input , \\output );") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "electrical \\input , \\output ;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module \\wire (c, b, e, s);") != null);
    // A name that is not a keyword is not escaped — the escape is for the
    // collision, not for every synthesized name.
    const plain = try synthesize(arena, ".SUBCKT PAD IN OUT\n.ENDS\n");
    try std.testing.expect(std.mem.indexOf(u8, plain.text, "module pad(in, out);") != null);
}

test "a digit-leading name and a numeric node are spelled §2.8.1, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL 2N2222 NPN BF=200
        \\.SUBCKT FLT A 1 B
        \\.ENDS FLT
    );
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // E.2 treats the model as a module definition; `2N2222` used to fail the
    // §2.7 shape test and the card contributed NOTHING (the later E0904 then
    // blamed the user's instantiation line).
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module \\2n2222 (c, b, e, s);") != null);
    // The numeric node is the SPICE default and is a PORT, not the end of the
    // list: three ports, in card order, or §6.5.4's ordered binding is wrong.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module flt(a, \\1 , b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "electrical a, \\1 , b;") != null);
    // A parameter assignment still ends the port list.
    const p = try synthesize(arena, ".SUBCKT X N1 N2 PARAMS: W=2\n.ENDS\n");
    try std.testing.expect(std.mem.indexOf(u8, p.text, "module x(n1, n2);") != null);
}

test "an unrecognised model type, a repeat and an empty netlist all contribute nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "")).modules);
    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, ".MODEL SW1 SW RON=1\n")).modules);
    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "R1 a b 1k\n.TRAN 1n 1u\n")).modules);
    const dup = try synthesize(arena, ".MODEL M1 NPN\n.MODEL M1 PNP\n");
    try std.testing.expectEqual(@as(u32, 1), dup.modules);
    // A portless .SUBCKT is A.1.2's `module identifier ;`, not `electrical ;`.
    const bare = try synthesize(arena, ".SUBCKT PAD\n.ENDS\n");
    try std.testing.expectEqual(@as(u32, 1), bare.modules);
    try std.testing.expect(std.mem.indexOf(u8, bare.text, "electrical") == null);
}
