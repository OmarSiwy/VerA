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
//! WHAT IT IS NOT. It is not a general netlist simulator and does not become
//! one. There is no `.TRAN`/`.DC`/`.OP`, no `.INCLUDE`/`.LIB`, no `.PARAM`
//! expression evaluator and no dialect tokenizer. E.2's noun phrase is
//! "subcircuits and models ... treated as module definitions", and a module
//! definition is an INTERFACE plus a BODY — so the cards read here are the two
//! that declare an interface, plus, INSIDE a `.SUBCKT`, the device cards that
//! are its body (`emitBody`). Everything else on the line is SKIPPED silently
//! rather than diagnosed, because a netlist VerA only mines for declarations is
//! not a netlist VerA claims to simulate — refusing a `.TRAN` would be claiming
//! jurisdiction this file does not have.
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

    // INDEX-BASED, because a `.SUBCKT` header is not the whole card it reads:
    // E.2 makes it a module DEFINITION, and a definition runs to its `.ENDS`.
    // The body is consumed with the header whether or not anything is emitted,
    // so a repeated `.SUBCKT`'s cards are not read a second time at top level.
    var i: usize = 0;
    while (i < cards.items.len) {
        const body = subcktBody(cards.items[i..]);
        if (try emitCard(arena, &out, cards.items[i], body, &seen)) count += 1;
        i += 1 + body.len;
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

/// The cards `rest[0]` OWNS, exclusive of the `.ENDS` that terminates them:
/// empty for anything that is not a `.SUBCKT` header. E.2 makes a subcircuit a
/// module definition and E.2.2.2 shows what the definition contains — eleven
/// device cards it calls an oscillator — so these cards are the body, not
/// top-level netlist.
///
/// ponytail: the FIRST `.ENDS` ends it, so a nested `.SUBCKT` would close the
/// outer one early. The SPEC puts multi-level netlists out of scope; make this a
/// depth counter when one comes in.
fn subcktBody(rest: []const []const u8) []const []const u8 {
    if (!std.mem.startsWith(u8, rest[0], ".subckt")) return &.{};
    for (rest[1..], 1..) |card, i| {
        if (std.mem.startsWith(u8, card, ".ends")) return rest[1..i];
    }
    return rest[1..]; // an unterminated `.SUBCKT` still has a body
}

/// One complete card, plus the body `subcktBody` gave it. Returns true if it
/// produced a module.
fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: []const u8,
    body: []const []const u8,
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
        // dependent.
        const params = try modelParams(arena, row.prim, &it);
        try out.print(arena,
            \\module {s}({s});
            \\   inout {s};
            \\   electrical {s};
            \\{s}   {s} #({s}) prim({s});
            \\endmodule
            \\
            \\
        , .{ decl, row.ports, row.ports, row.ports, params.decls, row.prim, params.args, row.ports });
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
            try out.print(arena, "module {s};\n", .{decl});
        } else {
            const list = try std.mem.join(arena, ", ", ports.items);
            try out.print(arena,
                \\module {s}({s});
                \\   inout {s};
                \\   electrical {s};
                \\
            , .{ decl, list, list, list });
        }
        try emitBody(arena, out, body);
        try out.appendSlice(arena, "endmodule\n\n");
    }
    try seen.append(arena, name);
    return true;
}

/// E.2.2.3 is the annex translating E.2.2.2's subcircuit card by card, and it is
/// the only place the LRM says what a DEVICE card means. It prints
/// `R1 B1 GND 10K` as `resistor #(.r(10k)) R1 (b1, gnd);`, `VA VCC GND 5` as
/// `vsine #(.dc(5)) Vcc (vcc, gnd);` and `IEE E GND 1MA` as
/// `isine #(.dc(1m)) Iee (e, gnd);` — so the card's leading LETTER picks the
/// Table E.1 primitive and the card's one positional value lands on the
/// parameter named here. `c` and `l` are the remaining two-terminal rows whose
/// Behavior column Table E.1 actually fills in; the letters with an empty one
/// (`Q`, `M`, `J`, `D`) have no equation to contribute and are not listed.
const device_cards = [_]struct { letter: u8, prim: []const u8, param: []const u8 }{
    .{ .letter = 'r', .prim = "resistor", .param = "r" },
    .{ .letter = 'c', .prim = "capacitor", .param = "c" },
    .{ .letter = 'l', .prim = "inductor", .param = "l" },
    .{ .letter = 'v', .prim = "vsine", .param = "dc" },
    .{ .letter = 'i', .prim = "isine", .param = "dc" },
};

/// E.3.1: "the following primitives are not supported: ccvs, cccs, and mutual
/// inductors; however, these primitives can be instantiated inside a SPICE
/// subcircuit". The four SPICE controlled-source letters, as the one
/// contribution each is, in SPICE's own sign convention — the controlled
/// quantity flows (or rises) from the card's first node to its second, which
/// is what `I(a, b)`/`V(a, b)` mean in §5.6:
///
///     E n+ n- nc+ nc- gain    V(n+, n-) <+ gain * V(nc+, nc-);   vcvs
///     G n+ n- nc+ nc- gm      I(n+, n-) <+ gm * V(nc+, nc-);     vccs
///     F n+ n- vctl gain       I(n+, n-) <+ gain * I(vctl);       cccs
///     H n+ n- vctl r          V(n+, n-) <+ r * I(vctl);          ccvs
///
/// `I(vctl)` is the current through the controlling V card, which SPICE takes
/// entering its first node. A V card that controls something is therefore
/// written as a NAMED BRANCH of this module (`branch (p, n) vctl;
/// V(vctl) <+ dc;`) rather than a `vsine` child, so the controlled source reads
/// the flow of a branch its own module declares — §5.4.2's flow probe of the
/// source branch, and no cross-instance access.
const controlled = [_]struct { letter: u8, lhs: []const u8, rhs: []const u8, by_current: bool }{
    .{ .letter = 'e', .lhs = "V", .rhs = "V", .by_current = false },
    .{ .letter = 'g', .lhs = "I", .rhs = "V", .by_current = false },
    .{ .letter = 'f', .lhs = "I", .rhs = "I", .by_current = true },
    .{ .letter = 'h', .lhs = "V", .rhs = "I", .by_current = true },
};

/// The instance lines a `.SUBCKT`'s device cards become — the equations that
/// make E.2's "module definition" a circuit rather than two floating pins.
///
/// A card this cannot read contributes nothing and is not diagnosed, on the same
/// argument as the skipped `.TRAN` above: a letter with no `device_cards` row
/// (`Q`, `M`, `X`), or a value that is a model name rather than a number
/// (`R1 A B RMOD`, where `spiceNumber` returns null). Both are out of the H04
/// SPEC's scope, and a body VerA reads part of is still more of a definition
/// than the empty one this replaces.
///
/// Nodes are run through `spell` for the same reason the port list is, and a
/// node the port list does not name needs no declaration: it is an implicit net
/// of the synthesized module, resolved by §7.5 from the primitive port it
/// touches, exactly as `rDiv x1(in, mid, gnd);` resolves `mid` in the caller.
///
/// ponytail: two terminals and one positional value, which is every row of
/// `device_cards`; a three-terminal or `k=v` card needs its own arity column.
/// The `controlled` letters are the exception, and read their own shape.
fn emitBody(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const []const u8,
) Allocator.Error!void {
    // The V cards an F or H card reads the current of, by name.
    var controls: std.ArrayList([]const u8) = .empty;
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card, " \t(),");
        const inst = it.next() orelse continue;
        if (inst[0] != 'f' and inst[0] != 'h') continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        try controls.append(arena, it.next() orelse continue);
    }
    var analog: std.ArrayList(u8) = .empty;
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card, " \t(),");
        const inst = it.next() orelse continue;
        if (for (controlled) |c| {
            if (inst[0] == c.letter) break c;
        } else null) |c| {
            const p = try spell(arena, it.next() orelse continue);
            const n = try spell(arena, it.next() orelse continue);
            // The controlling quantity: a V card's branch, or a node pair.
            const ctl = if (c.by_current) blk: {
                const v = it.next() orelse continue;
                if (v[0] != 'v' or !declares(body, v)) continue;
                break :blk try spell(arena, v);
            } else try std.fmt.allocPrint(arena, "{s}, {s}", .{
                try spell(arena, it.next() orelse continue),
                try spell(arena, it.next() orelse continue),
            });
            const gain = spiceNumber(it.next() orelse continue) orelse continue;
            try analog.print(arena, "      {s}({s}, {s}) <+ {d} * {s}({s});\n", .{ c.lhs, p, n, gain, c.rhs, ctl });
            continue;
        }
        const row = for (device_cards) |d| {
            if (inst[0] == d.letter) break d;
        } else continue;
        const p = it.next() orelse continue;
        const n = it.next() orelse continue;
        const value = spiceNumber(it.next() orelse continue) orelse continue;
        if (row.letter == 'v' and for (controls.items) |v| {
            if (std.mem.eql(u8, v, inst)) break true;
        } else false) {
            const name = try spell(arena, inst);
            try out.print(arena, "   branch ({s}, {s}) {s};\n", .{ try spell(arena, p), try spell(arena, n), name });
            try analog.print(arena, "      V({s}) <+ {d};\n", .{ name, value });
            continue;
        }
        try out.print(arena, "   {s} #(.{s}({d})) {s}({s}, {s});\n", .{
            row.prim,
            row.param,
            value,
            try spell(arena, inst),
            try spell(arena, p),
            try spell(arena, n),
        });
    }
    if (analog.items.len != 0) try out.print(arena, "   analog begin\n{s}   end\n", .{analog.items});
}

/// Does `body` hold a card named `name`? An F/H card naming a V card the
/// subcircuit does not declare reads nothing, and is skipped like any other
/// unreadable card.
fn declares(body: []const []const u8, name: []const u8) bool {
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card, " \t(),");
        if (std.mem.eql(u8, it.next() orelse continue, name)) return true;
    }
    return false;
}

/// The `parameter` declarations a model-derived module carries, and the argument
/// list that forwards them to the primitive it wraps.
const ModelParams = struct {
    /// One `   parameter ...;\n` line per parameter of the primitive.
    decls: []const u8,
    /// `.r(r), .tc1(tc1), ...` — §6.3.3 by name, so Table E.1's order is not
    /// load-bearing here.
    args: []const u8,
};

/// E.2.2.1: "The ports and parameters of the bjt are determined by the bjt
/// primitive itself and not by the model statement for the bjt." That fixes
/// which parameters EXIST — the primitive's, all of them — and says nothing
/// about discarding the VALUES the card assigns to them; E.1's "huge legacy of
/// SPICE netlists" is the reason not to, since a card-derived resistor that
/// ignored `R=2000` would be 1 ohm where the netlist said two thousand.
///
/// So the model-derived module re-declares the primitive's own parameter list —
/// LIFTED OUT OF THE PRELUDE that declares it rather than re-tabulated here, so
/// the `from` ranges and the defaults cannot drift from the row they transcribe
/// — with the default replaced by the card's value wherever the card names one,
/// and forwards the lot by name. Re-declaring rather than forwarding the card's
/// literals directly is what makes §6.7.1's `r1.r` resolve and §6.3.3's
/// `rmod #(.r(2500))` override, which are the same sentence's other two
/// consequences.
///
/// A card parameter Table E.1 does not declare (`BF=80`, `RSH=50`) is dropped in
/// silence: E.2 makes "all aspects of SPICE primitives implementation
/// dependent", E.4.2 makes model-card support "implementation specific", and
/// E.1.2's remedy for a name mismatch is a user-written wrapper module, not a
/// diagnostic. Refusing the card would make VerA read FEWER of the netlists
/// E.1 exists for.
fn modelParams(
    arena: Allocator,
    prim: []const u8,
    it: *std.mem.TokenIterator(u8, .any),
) Allocator.Error!ModelParams {
    // The card's `k=v` tail. ponytail: `k = v` with spaces around the `=` is not
    // a shape SPICE writes; split on the token if a dialect turns up that does.
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList(f64) = .empty;
    while (it.next()) |t| {
        const at = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (at == 0 or at + 1 == t.len) continue;
        const v = spiceNumber(t[at + 1 ..]) orelse continue;
        try keys.append(arena, t[0..at]);
        try vals.append(arena, v);
    }

    var decls: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, primitiveBody(prim), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "parameter ")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const head = std.mem.trimEnd(u8, line[0..eq], " \t");
        // The declared name is the last token before the `=`, minus any §3.4.4
        // array range: `parameter real wave[0:nwave-1] = ...` declares `wave`.
        var name = head[(std.mem.lastIndexOfAny(u8, head, " \t") orelse 0) + 1 ..];
        if (std.mem.indexOfScalar(u8, name, '[')) |b| name = name[0..b];
        if (name.len == 0) continue;

        if (args.items.len != 0) try args.appendSlice(arena, ", ");
        try args.print(arena, ".{s}({s})", .{ name, name });

        const bound = for (keys.items, vals.items) |k, v| {
            if (std.mem.eql(u8, k, name)) break v;
        } else null;
        if (bound) |v| {
            // Everything from the `from` range on is kept: §3.4.2's range is part
            // of the declaration, not of the default it replaces.
            const rest = line[eq + 1 ..];
            const tail = if (std.mem.indexOf(u8, rest, " from ")) |f| rest[f..] else ";";
            try decls.print(arena, "   {s} = {d}{s}\n", .{ head, v, tail });
        } else {
            try decls.print(arena, "   {s}\n", .{line});
        }
    }
    return .{ .decls = decls.items, .args = args.items };
}

/// The body of `Preprocessor.spice_primitives`'s module for `prim`, between its
/// header and its `endmodule`. Empty if there is no such row — `model_types`
/// only names rows that exist, and a test below pins that.
fn primitiveBody(prim: []const u8) []const u8 {
    const prelude = @import("preprocessor.zig").spice_primitives;
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "\nmodule {s}(", .{prim}) catch return "";
    const at = std.mem.indexOf(u8, prelude, header) orelse return "";
    const rest = prelude[at + header.len ..];
    const end = std.mem.indexOf(u8, rest, "\nendmodule") orelse return "";
    return rest[0..end];
}

/// SPICE's own scaled notation, which Annex E prints throughout its netlists —
/// `R1 B1 GND 10K`, `C1 VCC OUT 1P`, `TF=0.3NS`, `IEE E GND 1MA`. E.2.2.3
/// translates the first of those as `resistor #(.r(10k)) R1 (b1, gnd);`, and
/// §2.6.2 Table 2-1 makes `10k` ten thousand — so the two spellings are the
/// annex's own statement that `10K` is 10000.
///
/// The scale letter is followed by UNIT letters that carry no value (`PF`, `UH`,
/// `NS`, `MA`), so anything after the matched suffix is ignored rather than
/// rejected. Returns null when the token does not start with a number at all.
fn spiceNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const digits = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    }
    if (i == digits or (i == digits + 1 and t[digits] == '.')) return null;
    // An exponent only if it is complete: `1E-18` is a number, the `E` of a bare
    // `1EXP` is the start of unit noise.
    if (i < t.len and t[i] == 'e') {
        var j = i + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        if (j < t.len and std.ascii.isDigit(t[j])) {
            while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
            i = j;
        }
    }
    const mant = std.fmt.parseFloat(f64, t[0..i]) catch return null;
    return mant * spiceScale(t[i..]);
}

/// Berkeley SPICE's ten scale factors. `meg` and `mil` are tested before `m`
/// because they share its first letter and mean 1e6 and 25.4e-6, not 1e-3 with
/// unit noise — the one place SPICE and §2.6.2 Table 2-1 disagree outright (a
/// Verilog `M` is mega, a SPICE `M` is milli), which is why a card's number is
/// converted to plain decimal here rather than handed on with its suffix.
/// `a` (atto) is NOT one of them: SPICE has no atto and `1A` is one ampere.
fn spiceScale(rest: []const u8) f64 {
    const scales = [_]struct { suffix: []const u8, mul: f64 }{
        .{ .suffix = "meg", .mul = 1e6 },
        .{ .suffix = "mil", .mul = 25.4e-6 },
        .{ .suffix = "t", .mul = 1e12 },
        .{ .suffix = "g", .mul = 1e9 },
        .{ .suffix = "k", .mul = 1e3 },
        .{ .suffix = "m", .mul = 1e-3 },
        .{ .suffix = "u", .mul = 1e-6 },
        .{ .suffix = "n", .mul = 1e-9 },
        .{ .suffix = "p", .mul = 1e-12 },
        .{ .suffix = "f", .mul = 1e-15 },
    };
    for (scales) |s| if (std.mem.startsWith(u8, rest, s.suffix)) return s.mul;
    return 1.0;
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
    // E.2.2.1: ports AND parameters from the bjt primitive, in Table E.1's
    // order, and the card's own names are not among them — Table E.1's bjt row
    // declares `area` and nothing else, so `BF`, `IS`, `CJE` have no parameter
    // to land on and are dropped in silence (E.4.2: "support of SPICE model
    // cards is implementation specific").
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module vertnpn(c, b, e, s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real area = 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bjt #(.area(area)) prim(c, b, e, s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bf") == null);
    // E.2.2.2: ports from the card, lowered, parentheses dropped — and the two
    // device cards between it and `.ENDS` as E.2.2.3 translates them. `vcc` is
    // an internal node and appears only in the body.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module ecposc(out, gnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "vsine #(.dc(5)) va(vcc, gnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(10000)) r1(b1, gnd);") != null);
    // The `.TRAN` after `.ENDS` is outside the body and is still not a module.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "100n") == null);
}

test "a .SUBCKT's device cards are its body, and an unreadable one is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT RDIV IN OUT GND
        \\R1 IN OUT 1K
        \\R2 OUT GND 3K
        \\Q1 OUT IN GND VERTNPN
        \\R3 A B RMOD
        \\.ENDS RDIV
        \\R9 X Y 1K
    );
    try std.testing.expectEqual(@as(u32, 1), s.modules);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(1000)) r1(in, out);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(3000)) r2(out, gnd);") != null);
    // No Table E.1 equation for a bjt and no number on a model-referenced card,
    // so neither becomes an instance — and neither stops the two that do.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "q1") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "r3") == null);
    // `R9` is after `.ENDS`: top-level netlist, not part of any definition.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "r9") == null);

    // A repeated `.SUBCKT` is dropped WITH its body — the cards inside must not
    // fall out into the next module, or into a module of their own.
    const dup = try synthesize(arena,
        \\.SUBCKT PAD A B
        \\R1 A B 1K
        \\.ENDS
        \\.SUBCKT PAD A B
        \\R1 A B 9K
        \\.ENDS
    );
    try std.testing.expectEqual(@as(u32, 1), dup.modules);
    try std.testing.expect(std.mem.indexOf(u8, dup.text, "9000") == null);
}

test "a .MODEL card's value reaches the Table E.1 parameter of the same name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL RMOD R R=10K TC1=1E-3
        \\.MODEL CM C C=1P IC=2.5
    );
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // §2.6.2 Table 2-1 by way of E.2.2.3's `resistor #(.r(10k))`: `10K` is 10000.
    // §3.4.2's `from` range survives the substitution — it belongs to the
    // declaration, not to the default it replaces.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real r = 10000 from (0:inf);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real tc1 = 0.001;") != null);
    // A parameter the card does not name keeps the primitive's own default.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real tc2 = 0.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(r), .tc1(tc1), .tc2(tc2)) prim(p, n);") != null);
    // Not a resistor special case, and `ic` is an initial condition rather than
    // a coefficient.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real c = 0.000000000001 from (0:inf);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real ic = 2.5;") != null);
}

test "SPICE's scaled notation, including the three suffixes §2.6.2 does not share" {
    // The annex prints `10K`, `3PF`, `1UH`, `0.3NS`, `1MA`, `1E-18` in its own
    // netlists; a reader that cannot turn those into numbers cannot read
    // E.2.2.2. `MEG`/`MIL` are the SPICE-only ones, and `M` is milli here where
    // §2.6.2 Table 2-1 makes it mega — which is why a card's number is
    // converted rather than handed on with its suffix.
    try std.testing.expectEqual(@as(?f64, 10000), spiceNumber("10k"));
    try std.testing.expectEqual(@as(?f64, 3e-12), spiceNumber("3pf"));
    try std.testing.expectEqual(@as(?f64, 1e-6), spiceNumber("1uh"));
    try std.testing.expectEqual(@as(?f64, 0.3e-9), spiceNumber("0.3ns"));
    try std.testing.expectEqual(@as(?f64, 1e-3), spiceNumber("1ma"));
    try std.testing.expectEqual(@as(?f64, 1e6), spiceNumber("1meg"));
    try std.testing.expectEqual(@as(?f64, 25.4e-6), spiceNumber("1mil"));
    try std.testing.expectEqual(@as(?f64, 1e-18), spiceNumber("1e-18"));
    try std.testing.expectEqual(@as(?f64, -2.5), spiceNumber("-2.5"));
    // SPICE has no atto, so a bare `1A` is one ampere and the letter is noise.
    try std.testing.expectEqual(@as(?f64, 1.0), spiceNumber("1a"));
    // Not a number at all.
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("rmod"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber(""));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("."));
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

test "E.3.1 the four controlled sources inside a .SUBCKT, and the V card an F or H reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT CTL A B C D
        \\VS A X 0
        \\E1 B 0 A X 2
        \\G1 C 0 A X 3
        \\F1 D 0 VS 4
        \\H1 B C VS 5
        \\F2 D 0 VNONE 6
        \\.ENDS
    );
    for ([_][]const u8{
        "branch (a, x) vs;",
        "V(vs) <+ 0;",
        "V(b, \\0 ) <+ 2 * V(a, x);",
        "I(c, \\0 ) <+ 3 * V(a, x);",
        "I(d, \\0 ) <+ 4 * I(vs);",
        "V(b, c) <+ 5 * I(vs);",
    }) |want| try std.testing.expect(std.mem.indexOf(u8, s.text, want) != null);
    // A controlling V card the subcircuit does not declare reads nothing, and a
    // controlling V card is a branch of this module, not a `vsine` child.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "6 *") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "vsine") == null);
}
