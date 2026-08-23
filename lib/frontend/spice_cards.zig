//! SPICE `.MODEL` and `.SUBCKT` cards in, Verilog-AMS module source text out
//! (LRM annex E.2, E.3). Reads the two interface cards and, inside a
//! `.SUBCKT`, the device cards that form its body. Cards outside a definition
//! (`.tran`, top-level devices) are not module definitions and are skipped
//! without a diagnostic, except a `.MODEL` of a type VerA has no primitive
//! for, which is recorded so an instance of it is refused by name (E0952,
//! E.1.2). The text is prepended to the source like
//! `Preprocessor.spice_primitives`, so §6 instantiation, overrides and their
//! diagnostics apply unchanged. Input is lower-cased at ingest (E.2.1), file
//! names excepted.
//!
//! E.1.2: "with which particular variant of SPICE it is compatible, is solely
//! determined by the authors of the simulator". VerA claims SPICE3 card
//! syntax for `.MODEL` (the `model_types` rows), for `.SUBCKT` bodies of
//! numeric-valued R/C/L/V/I/E/F/G/H cards and of M/Q/J/D cards whose model is
//! a Verilog-A module or paramset (`model_cards`), and for `.INCLUDE`, `.LIB`
//! and HSPICE's `.HDL` anywhere (`Reader`). Inside a `.SUBCKT`, anything else
//! (`PARAMS:`, a `{expr}` value, a nested `.SUBCKT`, a model-referenced R or
//! unlisted device card, a binned model) is a `Refusal` (E0928), and a card
//! whose model is a Table E.1 semiconductor with no behaviour is E0953:
//! skipping either would change the circuit, a dropped R being an open.

const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");

/// Synthesized prelude text plus the number of module declarations it holds,
/// which `Ast.SourceFile.netlist_modules` records.
pub const Synthesized = struct {
    text: []const u8 = "",
    modules: u32 = 0,
    /// Cards inside a definition this reader does not claim; the caller
    /// reports each (`Refusal.code`) and stops.
    refused: []const Refusal = &.{},
    /// `.MODEL` cards whose type is a primitive VerA does not support (E.1.2
    /// bullet 2), as `name type`, lower-cased: an instance naming one is
    /// refused with E0952 rather than as an unknown module.
    unsupported: []const []const u8 = &.{},
    /// The files a `Refusal` points into: the netlist itself first, then
    /// each file a `.INCLUDE` or `.LIB` card read.
    files: []const File = &.{},
    /// HSPICE `.HDL "file"`: Verilog-A sources the netlist names, as opened
    /// (relative to the naming file's directory), each once, in card order.
    /// They belong to the design like files given together on a command line.
    hdl: []const []const u8 = &.{},
};

/// One netlist file: the name it was opened by, and its text.
pub const File = struct { name: []const u8, text: []const u8 };

/// One card `synthesize` cannot read, located in `Synthesized.files[file]`
/// (the first physical line of the card).
pub const Refusal = struct {
    file: u32 = 0,
    at: u32,
    len: u32,
    why: []const u8,
    /// E0928 unless the card is readable and its model is not (E0953).
    code: enum { E0928, E0953 } = .E0928,
};

/// A logical card (continuations joined) and where its first line starts.
const Card = struct {
    text: []const u8,
    file: u32 = 0,
    at: u32,
    len: u32,
};

/// The refusals of one `synthesize` call.
const Refusals = struct {
    arena: Allocator,
    list: std.ArrayList(Refusal) = .empty,

    fn add(r: *Refusals, card: Card, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try r.list.append(r.arena, .{ .file = card.file, .at = card.at, .len = card.len, .why = try r.arena.print(fmt, args) });
    }
};

/// E.2.2.1: ".MODEL statements can be accessed in Verilog-AMS HDL ... The ports
/// and parameters of the bjt are determined by the bjt primitive itself and not
/// by the model statement." So a model card contributes a name and a primitive
/// type, and the interface comes from Table E.1's row for that type.
///
/// The rows are the SPICE model-type letters, mapped to the Table E.1 primitive
/// each names. Absent types (`sw`, `ltra`, `core`, ...) are skipped cards, not
/// errors: E.1.2's first bullet makes the recognised flavor "solely determined by
/// the authors of the simulator".
///
/// `ports` is pre-joined in Table E.1's order, which E.3 makes normative for
/// connection by order. A test pins each row against
/// `Preprocessor.spice_primitives`.
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

/// One `.MODEL` card of the netlist, wherever it sits: what a body card's
/// model name resolves to (`emitModelCard`).
const ModelCard = struct {
    name: []const u8,
    type_: []const u8,
    card: Card,
};

/// Returns Verilog-AMS module text for every `.MODEL` and `.SUBCKT` card in
/// `netlist`, the text of the file `path` names ("" when it names none:
/// relative `.INCLUDE`/`.LIB`/`.HDL` names then resolve against the working
/// directory). The text, the refusals and the files are allocated from
/// `arena`; the working copies (the lowered lines, the joined cards, per-card
/// strings) live on a scratch arena freed on return. Never fails on malformed
/// input: a line outside a definition this does not understand contributes
/// nothing, and one inside a definition is a `Refusal`.
pub fn synthesize(arena: Allocator, netlist: []const u8, path: []const u8) Allocator.Error!Synthesized {
    if (netlist.len == 0) return .{};
    var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var refusals: Refusals = .{ .arena = arena };

    // Every line of every file, `.INCLUDE`/`.LIB` expanded in place.
    var r: Reader = .{ .arena = arena, .scratch = scratch, .refusals = &refusals };
    try r.files.append(arena, .{ .name = if (path.len == 0) "<spice netlist>" else path, .text = netlist });
    try r.read(0, null, 0);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(scratch,
        \\// Annex E.2 — synthesized from the `//! spice` cards of this compilation;
        \\// see `spice_cards.synthesize` for what of a netlist is read and what is not.
        \\
        \\
    );
    var count: u32 = 0;
    // Emitted names, so a repeated card does not declare the same module twice.
    // The first card wins; E.1.2 leaves the choice to "the authors of the
    // simulator".
    var seen: std.ArrayList([]const u8) = .empty;
    var unsupported: std.ArrayList([]const u8) = .empty;

    // `+` continuations make a card longer than a line, so the cards are
    // assembled first and read second.
    var cards: std.ArrayList(Card) = .empty;
    var logical: std.ArrayList(u8) = .empty;
    var first: Card = undefined;
    for (r.lines.items) |line| {
        if (line.text[0] == '+') {
            // Joins the card under construction. A `+` with nothing above it has
            // nothing to continue and is dropped.
            if (logical.items.len != 0) {
                try logical.append(scratch, ' ');
                try logical.appendSlice(scratch, std.mem.trim(u8, line.text[1..], " \t"));
            }
            continue;
        }
        if (logical.items.len != 0) try cards.append(scratch, .{ .text = try tightEquals(scratch, logical.items), .file = first.file, .at = first.at, .len = first.len });
        logical.clearRetainingCapacity();
        try logical.appendSlice(scratch, line.text);
        first = .{ .text = "", .file = line.file, .at = line.at, .len = line.len };
    }
    if (logical.items.len != 0) try cards.append(scratch, .{ .text = try tightEquals(scratch, logical.items), .file = first.file, .at = first.at, .len = first.len });

    // A body card may name a model declared after it, or in another file.
    var models: std.ArrayList(ModelCard) = .empty;
    for (cards.items) |card| {
        var it = std.mem.tokenizeAny(u8, card.text, " \t(),");
        if (!std.mem.eql(u8, it.next() orelse continue, ".model")) continue;
        const name = it.next() orelse continue;
        const type_ = it.next() orelse continue;
        for (models.items) |m| {
            if (std.mem.eql(u8, m.name, name)) break;
        } else try models.append(scratch, .{ .name = name, .type_ = type_, .card = card });
    }

    // Index-based, because a `.SUBCKT` header is not the whole card it reads:
    // E.2 makes it a module definition, which runs to its `.ENDS`.
    // The body is consumed with the header whether or not anything is emitted,
    // so a repeated `.SUBCKT`'s cards are not read a second time at top level.
    var i: usize = 0;
    while (i < cards.items.len) {
        const body = subcktBody(cards.items[i..]);
        if (try emitCard(scratch, &out, cards.items[i], body, models.items, &seen, &refusals, &unsupported)) count += 1;
        i += 1 + body.len;
    }

    const kept = try arena.alloc([]const u8, unsupported.items.len);
    for (unsupported.items, kept) |u, *k| k.* = try arena.dupe(u8, u);
    var done: Synthesized = .{ .refused = refusals.list.items, .unsupported = kept, .files = r.files.items, .hdl = r.hdl.items };
    if (count == 0) return done;
    done.text = try arena.dupe(u8, out.items);
    done.modules = count;
    return done;
}

/// One physical line of a netlist file, comments stripped and lower-cased,
/// and where it is in `Reader.files[file]`.
const Line = struct { text: []const u8, file: u32, at: u32, len: u32 };

/// Reads netlist files into `lines`, the way SPICE reads them: a `.INCLUDE
/// file` card is replaced by the file's lines, a `.LIB file entry` card by
/// the lines between `.LIB entry` and `.ENDL` in that file, and a `.LIB
/// entry` ... `.ENDL` block met any other way is a library entry, read only
/// when called. A relative file name is looked for beside the file whose
/// card names it, as VD-091 does for `` `include ``. `.HDL file` names a
/// Verilog-A source (`Synthesized.hdl`). A file that cannot be read, an entry
/// it does not have, or nesting past `max_depth` is a `Refusal` at the card.
const Reader = struct {
    arena: Allocator,
    scratch: Allocator,
    refusals: *Refusals,
    lines: std.ArrayList(Line) = .empty,
    files: std.ArrayList(File) = .empty,
    hdl: std.ArrayList([]const u8) = .empty,

    /// SPICE netlists do not nest library files deeply; past this a
    /// `.INCLUDE` cycle is the likelier reading.
    const max_depth = 16;
    /// The `--spice` netlist's own bound (E1013).
    const max_bytes = 64 * 1024 * 1024;

    /// Appends file `fi`'s lines, or with `entry` only those of its `.LIB
    /// entry` block.
    fn read(r: *Reader, fi: u32, entry: ?[]const u8, depth: u32) Allocator.Error!void {
        const text = r.files.items[fi].text;
        // Inside a `.LIB name` block: true when it is the entry asked for.
        var in_lib: ?bool = null;
        // The open block's header, so one `.ENDL` never closes is not a
        // silent end of the file.
        var header: Card = undefined;
        defer if (in_lib != null) r.refusals.add(header, "`.lib` entry has no `.endl`; the cards after it are not read", .{}) catch {};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = strip(raw);
            if (line.len == 0) continue;
            const at: u32 = @intCast(line.ptr - text.ptr);
            const card: Card = .{ .text = line, .file = fi, .at = at, .len = @intCast(line.len) };
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const kw = try std.ascii.allocLowerString(r.scratch, it.next().?);
            const arg = unquote(it.next() orelse "");
            const arg2 = unquote(it.next() orelse "");
            if (std.mem.eql(u8, kw, ".lib") and arg2.len == 0) {
                // A library entry's header, not a call.
                if (in_lib == null) {
                    in_lib = if (entry) |e| std.ascii.eqlIgnoreCase(e, arg) else false;
                    header = card;
                }
                continue;
            }
            if (std.mem.eql(u8, kw, ".endl")) {
                const done = in_lib orelse false;
                in_lib = null;
                if (done) return;
                continue;
            }
            if (entry != null and !(in_lib orelse false)) continue;
            if (in_lib == false) continue;
            const include = std.mem.eql(u8, kw, ".include") or std.mem.eql(u8, kw, ".inc");
            if (include or std.mem.eql(u8, kw, ".lib")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`{s}` names no file", .{kw});
                    continue;
                }
                if (depth == max_depth) {
                    try r.refusals.add(card, "`{s}` is nested more than {d} files deep", .{ kw, max_depth });
                    continue;
                }
                const sub = try r.open(card, kw, arg) orelse continue;
                const before = r.lines.items.len;
                try r.read(sub, if (include) null else arg2, depth + 1);
                if (!include and r.lines.items.len == before and !hasEntry(r.files.items[sub].text, arg2))
                    try r.refusals.add(card, "`{s}` has no `.lib {s}` entry", .{ r.files.items[sub].name, arg2 });
                continue;
            }
            if (std.mem.eql(u8, kw, ".hdl")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`.hdl` names no file", .{});
                    continue;
                }
                const full = try r.resolve(fi, arg);
                for (r.hdl.items) |h| {
                    if (std.mem.eql(u8, h, full)) break;
                } else try r.hdl.append(r.arena, full);
                continue;
            }
            try r.lines.append(r.scratch, .{ .text = try std.ascii.allocLowerString(r.scratch, line), .file = fi, .at = at, .len = card.len });
        }
    }

    /// `name` beside the file `fi` was opened by, or as written when absolute.
    fn resolve(r: *Reader, fi: u32, name: []const u8) Allocator.Error![]const u8 {
        if (std.fs.path.isAbsolute(name)) return r.arena.dupe(u8, name);
        const dir = std.fs.path.dirname(r.files.items[fi].name) orelse ".";
        const base = if (fi == 0 and r.files.items[0].name[0] == '<') "." else dir;
        return std.fs.path.join(r.arena, &.{ base, name });
    }

    /// Reads the file `card` names (`.include` or `.lib`) into `files`, or
    /// records why not and returns null.
    fn open(r: *Reader, card: Card, kw: []const u8, name: []const u8) Allocator.Error!?u32 {
        const full = try r.resolve(card.file, name);
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, full, r.arena, .limited(max_bytes)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.refusals.add(card, "`{s}`: cannot read \"{s}\" ({t})", .{ kw, full, e });
                return null;
            },
        };
        try r.files.append(r.arena, .{ .name = full, .text = text });
        return @intCast(r.files.items.len - 1);
    }
};

/// Whether `text` has a `.LIB entry` header, so an empty entry is not
/// reported as a missing one.
fn hasEntry(text: []const u8, entry: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, strip(raw), " \t");
        if (!std.ascii.eqlIgnoreCase(it.next() orelse continue, ".lib")) continue;
        if (std.ascii.eqlIgnoreCase(unquote(it.next() orelse continue), entry) and it.next() == null) return true;
    }
    return false;
}

/// A file name or entry without the `"`/`'` SPICE dialects put around it.
fn unquote(t: []const u8) []const u8 {
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// `card` with the white space around each `=` removed: HSPICE writes
/// `level = 72`, and every reader below splits a parameter on its `=` within
/// one token.
fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, card, '=') == null) return arena.dupe(u8, card);
    var out: std.ArrayList(u8) = try .initCapacity(arena, card.len);
    for (card, 0..) |c, i| {
        const blank = c == ' ' or c == '\t';
        if (blank) {
            const next = std.mem.trimStart(u8, card[i..], " \t");
            if (next.len != 0 and next[0] == '=') continue;
            if (out.items.len != 0 and out.items[out.items.len - 1] == '=') continue;
        }
        out.appendAssumeCapacity(c);
    }
    return out.items;
}

/// One physical line with its comments removed: `*` is a full-line comment, `;`
/// and `$` start a trailing one.
fn strip(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len != 0 and line[0] == '*') return "";
    if (std.mem.indexOfAny(u8, line, ";$")) |at| line = std.mem.trim(u8, line[0..at], " \t");
    return line;
}

// ponytail: the first `.ENDS` ends it. A nested `.SUBCKT` is refused
// (`emitBody`), so closing the outer one early never produces a module.

/// Returns the cards `rest[0]` owns, excluding the terminating `.ENDS`; empty
/// unless `rest[0]` is a `.SUBCKT` header. E.2 makes a subcircuit a module
/// definition and E.2.2.2 shows its device cards as its body.
fn subcktBody(rest: []const Card) []const Card {
    if (!std.mem.startsWith(u8, rest[0].text, ".subckt")) return &.{};
    for (rest[1..], 1..) |card, i| {
        if (std.mem.startsWith(u8, card.text, ".ends")) return rest[1..i];
    }
    return rest[1..]; // an unterminated `.SUBCKT` still has a body
}

/// Emits one complete card, plus the body `subcktBody` gave it. Returns true
/// if it produced a module.
fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    body: []const Card,
    models: []const ModelCard,
    seen: *std.ArrayList([]const u8),
    refusals: *Refusals,
    unsupported: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    // `(` `)` and `,` are noise in a SPICE port list: E.2.2.2's own example
    // writes `.SUBCKT ECPOSC (OUT GND)` with parentheses that carry no meaning.
    var it = std.mem.tokenizeAny(u8, card.text, " \t(),");
    const kw = it.next() orelse return false;
    const is_model = std.mem.eql(u8, kw, ".model");
    if (!is_model and !std.mem.eql(u8, kw, ".subckt")) return false; // a device card, .tran, .include, ...

    const name = it.next() orelse {
        if (!is_model) try refusals.add(card, "`{s}` names no definition", .{kw});
        return false;
    };
    if (!isSpiceName(name)) {
        if (!is_model) try refusals.add(card, "`{s}` is not a name for a definition", .{name});
        return false;
    }
    for (seen.items) |s| if (std.mem.eql(u8, s, name)) return false;
    // `seen` keeps the bare name: the escape is a spelling of it, so two cards
    // named `wire` are still a repeat.
    const decl = try spell(arena, name);

    if (is_model) {
        const type_ = it.next() orelse return false;
        const row = for (model_types) |r| {
            if (std.mem.eql(u8, r.type_, type_)) break r;
        } else {
            // E.1.2: "a particular SPICE netlist can reference a primitive
            // which is unsupported". Kept, so its use is named as that.
            try seen.append(arena, name);
            try unsupported.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, type_ }));
            return false;
        };
        // E.2.2.1: the interface is the primitive's. The body instantiates the
        // primitive, so the model behaves as Table E.1's Behavior column gives
        // that row; an empty column (bjt, mosfet, diode) gives nothing, which
        // E.2 makes implementation dependent.
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
        // `.SUBCKT name p1 p2 ... [params: k=v]`: ports up to the first thing
        // that is not a node name. Numeric nodes are the SPICE default (`1`,
        // `2`, `0`), so only a parameter ends the list.
        var ports: std.ArrayList([]const u8) = .empty;
        while (it.next()) |t| {
            if (!isSpiceName(t)) {
                // `params:`, `k=v`: HSPICE/Spectre subcircuit parameters.
                try refusals.add(card, "`{s}` on `.subckt {s}`: subcircuit parameters (`PARAMS:`, `k=v`) are not read", .{ t, name });
                return false;
            }
            try ports.append(arena, try spell(arena, t));
        }
        // A.1.2 makes the port list optional, so a portless `.SUBCKT` is a legal
        // module, and an empty `electrical ;` would not be.
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
        try emitBody(arena, out, body, models, refusals);
        try out.appendSlice(arena, "endmodule\n\n");
    }
    try seen.append(arena, name);
    return true;
}

/// Device card letters and the Table E.1 primitive each becomes. E.2.2.3, the
/// only place the LRM says what a device card means, prints `R1 B1 GND 10K` as
/// `resistor #(.r(10k)) R1 (b1, gnd);`, `VA VCC GND 5` as
/// `vsine #(.dc(5)) Vcc (vcc, gnd);` and `IEE E GND 1MA` as
/// `isine #(.dc(1m)) Iee (e, gnd);`: the leading letter picks the primitive and
/// the one positional value lands on `param`. `c` and `l` are the other
/// two-terminal rows whose Behavior column Table E.1 fills in; letters with an
/// empty one (`Q`, `M`, `J`, `D`) have no equation here, and are read only
/// with a model (`model_cards`).
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
/// contribution each is, in SPICE's own sign convention: the controlled
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
/// written as a named branch of this module (`branch (p, n) vctl;
/// V(vctl) <+ dc;`) rather than a `vsine` child, so the controlled source reads
/// the flow of a branch its own module declares (§5.4.2's flow probe of the
/// source branch) with no cross-instance access.
const controlled = [_]struct { letter: u8, lhs: []const u8, rhs: []const u8, by_current: bool }{
    .{ .letter = 'e', .lhs = "V", .rhs = "V", .by_current = false },
    .{ .letter = 'g', .lhs = "I", .rhs = "V", .by_current = false },
    .{ .letter = 'f', .lhs = "I", .rhs = "I", .by_current = true },
    .{ .letter = 'h', .lhs = "V", .rhs = "I", .by_current = true },
};

// ponytail: two terminals and one positional value, which is every row of
// `device_cards`; a three-terminal or `k=v` card needs its own arity column.
// The `controlled` letters are the exception, and read their own shape.

/// Emits the instance lines and analog contributions a `.SUBCKT`'s device
/// cards become.
///
/// A card this cannot read is a `Refusal`: a letter with no `device_cards` or
/// `controlled` row (`Q`, `M`, `X`), a value that is a model name or a
/// `{expr}` rather than a number (`R1 A B RMOD`), a missing or extra field, a
/// nested `.SUBCKT` or any other dot card.
///
/// A node the port list does not name needs no declaration: it is an implicit
/// net of the synthesized module, resolved by §7.5 from the primitive port it
/// touches.
fn emitBody(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const Card,
    models: []const ModelCard,
    refusals: *Refusals,
) Allocator.Error!void {
    // The V cards an F or H card reads the current of, by name.
    var controls: std.ArrayList([]const u8) = .empty;
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card.text, " \t(),");
        const inst = it.next() orelse continue;
        if (inst[0] != 'f' and inst[0] != 'h') continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        try controls.append(arena, it.next() orelse continue);
    }
    var analog: std.ArrayList(u8) = .empty;
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card.text, " \t(),");
        const inst = it.next() orelse continue;
        if (inst[0] == '.') {
            if (std.mem.eql(u8, inst, ".subckt"))
                try refusals.add(card, "a `.subckt` inside a `.subckt` body: nested subcircuits are not read", .{})
            else
                try refusals.add(card, "`{s}` inside a `.subckt` body is not read", .{inst});
            continue;
        }
        const short = "`{s}` has too few fields";
        if (for (controlled) |c| {
            if (inst[0] == c.letter) break c;
        } else null) |c| {
            const p = try spell(arena, it.next() orelse {
                try refusals.add(card, short, .{inst});
                continue;
            });
            const n = try spell(arena, it.next() orelse {
                try refusals.add(card, short, .{inst});
                continue;
            });
            // The controlling quantity: a V card's branch, or a node pair.
            const ctl = if (c.by_current) blk: {
                const v = it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                };
                if (v[0] != 'v' or !declares(body, v)) {
                    try refusals.add(card, "`{s}` reads the current of `{s}`, which is not a V card of this subcircuit", .{ inst, v });
                    continue;
                }
                break :blk try spell(arena, v);
            } else try arena.print("{s}, {s}", .{
                try spell(arena, it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                }),
                try spell(arena, it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                }),
            });
            const gain = try cardValue(it.next(), &it, inst, card, refusals) orelse continue;
            try analog.print(arena, "      {s}({s}, {s}) <+ {f} * {s}({s});\n", .{ c.lhs, p, n, num(gain), c.rhs, ctl });
            continue;
        }
        if (for (model_cards) |m| {
            if (inst[0] == m.letter) break m;
        } else null) |m| {
            try emitModelCard(arena, out, card, inst, &it, m, models, refusals);
            continue;
        }
        const row = for (device_cards) |d| {
            if (inst[0] == d.letter) break d;
        } else {
            try refusals.add(card, "`{s}`: a `{c}` device card is not one VerA reads in a subcircuit (R, C, L, V, I, E, F, G, H, M, Q, J, D)", .{ inst, inst[0] });
            continue;
        };
        const p = it.next() orelse {
            try refusals.add(card, short, .{inst});
            continue;
        };
        const n = it.next() orelse {
            try refusals.add(card, short, .{inst});
            continue;
        };
        const value = try cardValue(it.next(), &it, inst, card, refusals) orelse continue;
        if (row.letter == 'v' and for (controls.items) |v| {
            if (std.mem.eql(u8, v, inst)) break true;
        } else false) {
            const name = try spell(arena, inst);
            try out.print(arena, "   branch ({s}, {s}) {s};\n", .{ try spell(arena, p), try spell(arena, n), name });
            try analog.print(arena, "      V({s}) <+ {f};\n", .{ name, num(value) });
            continue;
        }
        try out.print(arena, "   {s} #(.{s}({f})) {s}({s}, {s});\n", .{
            row.prim,
            row.param,
            num(value),
            try spell(arena, inst),
            try spell(arena, p),
            try spell(arena, n),
        });
    }
    if (analog.items.len != 0) try out.print(arena, "   analog begin\n{s}   end\n", .{analog.items});
}

/// SPICE3's semiconductor device cards: the letter, its node count before
/// the model name, and the Table E.1 primitive a `.MODEL` of a Table E.1
/// type would make it (`emitModelCard`):
///
///     M d g s b model [k=v ...]
///     Q c b e [s] model [area] [k=v ...]
///     J d g s model [area] [k=v ...]
///     D a c model [area] [k=v ...]
const model_cards = [_]struct { letter: u8, nodes: u8, prim: []const u8 }{
    .{ .letter = 'm', .nodes = 4, .prim = "mosfet" },
    .{ .letter = 'q', .nodes = 3, .prim = "bjt" },
    .{ .letter = 'j', .nodes = 3, .prim = "jfet" },
    .{ .letter = 'd', .nodes = 2, .prim = "diode" },
};

/// One `.name(value)` a model card's instance carries.
const Override = struct { name: []const u8, value: f64 };

/// Emits the instance an M/Q/J/D card is (`model_cards`). E.2: "models
/// contained within the SPICE netlist are treated as module definitions",
/// and E.1.1 lets "anything that can be instantiated in the particular flavor
/// of SPICE" be instantiated from Verilog-AMS. The card's model name
/// resolves, in order, to
///
///   - a `.MODEL name type ...` card whose type is no Table E.1 row: an
///     instance of `type`, a Verilog-A module or paramset of the design (the
///     HSPICE/Spectre `.model nch bsim4 ...` naming a compiled model), the
///     card's parameters as overrides;
///   - a `.MODEL` of a Table E.1 type (nmos, npn, d, ...): the rows Table E.1
///     leaves without a Behavior, which E.2 makes "implementation dependent",
///     and VerA has no equations for. Refused (E0953): an instance with no
///     behaviour would be an open where the netlist has a transistor;
///   - no `.MODEL` of that name: the name itself, as a module or paramset of
///     the design; one naming nothing is E0904 at elaboration.
///
/// A binned model (`.MODEL name.1 ...`, E.4.2) is not read. The card's own
/// parameters (`W=`, `L=`, `NFIN=`, a positional area) override the model
/// card's of the same name, and `M=` is E.4.1's multiplicity factor, the
/// §6.3.6 `$mfactor`. Names keep the netlist's lower case: elaboration
/// matches them to the module's regardless of case (E.2.1, `spiceCase`).
fn emitModelCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    inst: []const u8,
    it: *std.mem.TokenIterator(u8, .any),
    row: @TypeOf(model_cards[0]),
    models: []const ModelCard,
    refusals: *Refusals,
) Allocator.Error!void {
    var plain: std.ArrayList([]const u8) = .empty;
    var over: std.ArrayList(Override) = .empty;
    while (it.next()) |t| {
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse {
            if (over.items.len != 0)
                return refusals.add(card, "`{s}`: the field `{s}` after its parameters is not read", .{ inst, t });
            try plain.append(arena, t);
            continue;
        };
        try setOverride(arena, &over, t[0..eq], try paramValue(t, eq, inst, card, refusals) orelse return);
    }
    // Q's substrate is optional: a fifth name that is not a number is the
    // model after it, as SPICE3 reads the card.
    var nodes: usize = row.nodes;
    if (row.letter == 'q' and plain.items.len >= 5 and spiceNumber(plain.items[4]) == null) nodes = 4;
    if (plain.items.len <= nodes) return refusals.add(card, "`{s}` has too few fields", .{inst});
    const model = plain.items[nodes];
    var extra = plain.items[nodes + 1 ..];
    // A positional area (Q, J, D) is Table E.1's `area`; `area=` wins.
    if (row.letter != 'm' and extra.len == 1) if (spiceNumber(extra[0])) |a| {
        for (over.items) |o| {
            if (std.mem.eql(u8, o.name, "area")) break;
        } else try over.append(arena, .{ .name = "area", .value = a });
        extra = extra[1..];
    };
    if (extra.len != 0) return refusals.add(card, "`{s}`: the field `{s}` after the model is not read", .{ inst, extra[0] });

    var module = model;
    var params: std.ArrayList(Override) = .empty;
    if (for (models) |m| {
        if (std.mem.eql(u8, m.name, model)) break m;
    } else null) |m| {
        if (for (model_types) |t| {
            if (std.mem.eql(u8, t.type_, m.type_)) break t;
        } else null) |t| {
            try refusals.list.append(refusals.arena, .{
                .file = card.file,
                .at = card.at,
                .len = card.len,
                .code = .E0953,
                .why = try refusals.arena.print("`{s}`: its model `{s}` is `.model {s} {s}`, Table E.1's `{s}`, which has no behaviour in VerA; name a Verilog-A module as the model's type (`.model {s} <module> ...`)", .{ inst, model, model, m.type_, t.prim, model }),
            });
            return;
        }
        module = m.type_;
        var mit = std.mem.tokenizeAny(u8, m.card.text, " \t(),");
        for (0..3) |_| _ = mit.next(); // `.model name type`
        while (mit.next()) |t| {
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse
                return refusals.add(card, "`{s}`: the field `{s}` of `.model {s}` is not read", .{ inst, t, model });
            try setOverride(arena, &params, t[0..eq], try paramValue(t, eq, inst, card, refusals) orelse return);
        }
    } else for (models) |m| {
        const bin = std.mem.startsWith(u8, m.name, model) and m.name.len > model.len + 1 and m.name[model.len] == '.';
        if (bin) return refusals.add(card, "`{s}`: `{s}` is a binned model (`.model {s}`), which is not read", .{ inst, model, m.name });
    }
    for (over.items) |o| try setOverride(arena, &params, o.name, o.value);

    try out.print(arena, "   {s} ", .{try spell(arena, module)});
    if (params.items.len != 0) {
        try out.appendSlice(arena, "#(");
        for (params.items, 0..) |p, i| {
            if (i != 0) try out.appendSlice(arena, ", ");
            const name = if (std.mem.eql(u8, p.name, "m")) "$mfactor" else try spell(arena, p.name);
            try out.print(arena, ".{s}({f})", .{ name, num(p.value) });
        }
        try out.appendSlice(arena, ") ");
    }
    try out.print(arena, "{s}(", .{try spell(arena, inst)});
    for (plain.items[0..nodes], 0..) |n, i| try out.print(arena, "{s}{s}", .{ if (i == 0) "" else ", ", try spell(arena, n) });
    try out.appendSlice(arena, ");\n");
}

/// Sets `name` in `list`, replacing an earlier value: a later assignment of
/// one parameter wins, as an instance's does over its model card's.
fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: f64) Allocator.Error!void {
    for (list.items) |*o| if (std.mem.eql(u8, o.name, name)) {
        o.value = value;
        return;
    };
    try list.append(arena, .{ .name = name, .value = value });
}

/// The number `t[eq + 1 ..]` of the parameter assignment `t`, or null after
/// recording why it is not one (a `{expr}`, a name).
fn paramValue(t: []const u8, eq: usize, inst: []const u8, card: Card, refusals: *Refusals) Allocator.Error!?f64 {
    const v = t[eq + 1 ..];
    if (eq == 0 or v.len == 0) {
        try refusals.add(card, "`{s}`: `{s}` is not a parameter assignment", .{ inst, t });
        return null;
    }
    if (spiceNumber(v)) |n| return n;
    if (v[0] == '{' or v[0] == '\'')
        try refusals.add(card, "`{s}`: the expression value `{s}` is not read; write a number", .{ inst, v })
    else
        try refusals.add(card, "`{s}`: the value `{s}` of `{s}` is not a number", .{ inst, v, t[0..eq] });
    return null;
}

/// A card value as Verilog-AMS source: `{d}`'s plain decimal, except an
/// integral value of 2^31 or more, which `{d}` would spell as an integer
/// literal too wide for §3.2's 32-bit integer; `{e}` keeps it real.
fn num(v: f64) Num {
    return .{ .v = v };
}
const Num = struct {
    v: f64,
    pub fn format(n: Num, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (@abs(n.v) >= 0x1p31 and @trunc(n.v) == n.v) return w.print("{e}", .{n.v});
        return w.print("{d}", .{n.v});
    }
};

/// A device card's one positional value, with nothing after it, or null after
/// recording why not: a model name (`R1 A B RMOD`), a `{expr}`, a missing
/// value, or a trailing field (`TC=...`, `AC 1`) whose meaning would be
/// dropped.
fn cardValue(
    t: ?[]const u8,
    it: *std.mem.TokenIterator(u8, .any),
    inst: []const u8,
    card: Card,
    refusals: *Refusals,
) Allocator.Error!?f64 {
    const v = t orelse {
        try refusals.add(card, "`{s}` has too few fields", .{inst});
        return null;
    };
    const value = spiceNumber(v) orelse {
        if (v[0] == '{' or v[0] == '\'')
            try refusals.add(card, "`{s}`: the expression value `{s}` is not read; write a number", .{ inst, v })
        else
            try refusals.add(card, "`{s}`: the value `{s}` is not a number (a model-referenced card is not read)", .{ inst, v });
        return null;
    };
    if (it.next()) |extra| {
        try refusals.add(card, "`{s}`: the field `{s}` after the value is not read", .{ inst, extra });
        return null;
    }
    return value;
}

/// Reports whether `body` holds a card named `name`. An F/H card naming a V
/// card the subcircuit does not declare is skipped like any unreadable card.
fn declares(body: []const Card, name: []const u8) bool {
    for (body) |card| {
        var it = std.mem.tokenizeAny(u8, card.text, " \t(),");
        if (std.mem.eql(u8, it.next() orelse continue, name)) return true;
    }
    return false;
}

/// The `parameter` declarations a model-derived module carries, and the argument
/// list that forwards them to the primitive it wraps.
const ModelParams = struct {
    /// One `   parameter ...;\n` line per parameter of the primitive.
    decls: []const u8,
    /// `.r(r), .tc1(tc1), ...`: §6.3.3 by name, so Table E.1's order does not
    /// matter here.
    args: []const u8,
};

/// E.2.2.1: "The ports and parameters of the bjt are determined by the bjt
/// primitive itself and not by the model statement for the bjt." That fixes
/// which parameters exist (all of the primitive's) but does not discard the
/// values the card assigns to them.
///
/// So the model-derived module re-declares the primitive's parameter list,
/// copied from the prelude so the `from` ranges and defaults cannot drift,
/// with the default replaced by the card's value wherever the card names one,
/// and forwards all of them by name. Re-declaring is what makes §6.7.1's
/// `r1.r` resolve and §6.3.3's `rmod #(.r(2500))` override.
///
/// A card parameter Table E.1 does not declare (`BF=80`, `RSH=50`) is dropped in
/// silence: E.2 makes "all aspects of SPICE primitives implementation
/// dependent", E.4.2 makes model-card support "implementation specific", and
/// E.1.2's remedy for a name mismatch is a user-written wrapper module, not a
/// diagnostic.
fn modelParams(
    arena: Allocator,
    prim: []const u8,
    it: *std.mem.TokenIterator(u8, .any),
) Allocator.Error!ModelParams {
    // The card's `k=v` tail; `tightEquals` has joined HSPICE's `k = v`.
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
            try decls.print(arena, "   {s} = {f}{s}\n", .{ head, num(v), tail });
        } else {
            try decls.print(arena, "   {s}\n", .{line});
        }
    }
    return .{ .decls = decls.items, .args = args.items };
}

/// The body of `Preprocessor.spice_primitives`'s module for `prim`, between its
/// header and its `endmodule`. Empty if there is no such row; a test pins that
/// every `model_types` row exists.
fn primitiveBody(prim: []const u8) []const u8 {
    const prelude = @import("preprocessor.zig").spice_primitives;
    var buf: [64]u8 = undefined;
    const header = std.mem.print(&buf, "\nmodule {s}(", .{prim}) catch return "";
    const at = std.mem.indexOf(u8, prelude, header) orelse return "";
    const rest = prelude[at + header.len ..];
    const end = std.mem.indexOf(u8, rest, "\nendmodule") orelse return "";
    return rest[0..end];
}

/// Parses SPICE's scaled notation, which annex E prints throughout its
/// netlists (`10K`, `1P`, `0.3NS`, `1MA`). E.2.2.3 translates `10K` as
/// `10k`, which §2.6.2 Table 2-1 makes ten thousand.
///
/// The scale letter is followed by unit letters that carry no value (`PF`, `UH`,
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
/// unit noise. SPICE and §2.6.2 Table 2-1 disagree on `M` (milli in SPICE,
/// mega in Verilog), which is why a card's number is converted to plain
/// decimal here rather than handed on with its suffix. SPICE has no atto, so
/// `1A` is one ampere.
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

/// Reports whether `t` has the §2.7 shape of a simple identifier. `$` is not
/// admitted even though §2.7 allows it in an identifier: `strip` has
/// already treated it as a comment opener, so it cannot reach here.
fn isIdent(t: []const u8) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isAlphabetic(t[0]) and t[0] != '_') return false;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Reports whether `t` is a SPICE model, subcircuit or node name. SPICE names
/// may lead with digits (`2N2222`) and bare numbers are the default node
/// spelling, so anything printable that is not a parameter (`k=v`, `params:`)
/// qualifies; `spell` decides how it is written.
fn isSpiceName(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| if (c < 33 or c > 126 or c == '=' or c == ':') return false;
    return true;
}

/// Returns `t` as it must be written to declare it: bare when it is a simple
/// identifier and not a keyword, otherwise as a §2.8.1 escaped identifier
/// (`\wire `, `\2n2222 `), since SPICE has no reserved words and no §2.7
/// shape rule. An escaped identifier is never a keyword (§2.8.2), and neither
/// the `\` nor the terminating white space is part of the name, so lookups
/// still see `wire`. The trailing space is required: `,` and `)` are printable
/// and would otherwise be scanned into the identifier.
fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    // ponytail: share the lexer's keyword lookup; extend the common table for new keywords.
    if (isIdent(t) and token.lookupKeyword(t) == null) return t;
    return arena.print("\\{s} ", .{t});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "model_types names a real Table E.1 module with the ports it lists" {
    // A row whose primitive or port order does not match the prelude would be
    // wrong without any other test noticing.
    const prelude = @import("preprocessor.zig").spice_primitives;
    for (model_types) |r| {
        const header = try std.testing.allocator.print(
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
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    try std.testing.expectEqual(@as(usize, 0), s.refused.len);
    // E.2.2.1: ports AND parameters from the bjt primitive, in Table E.1's
    // order, and the card's own names are not among them: Table E.1's bjt row
    // declares `area` and nothing else, so `BF`, `IS`, `CJE` have no parameter
    // to land on and are dropped in silence (E.4.2: "support of SPICE model
    // cards is implementation specific").
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module vertnpn(c, b, e, s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "parameter real area = 1.0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bjt #(.area(area)) prim(c, b, e, s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "bf") == null);
    // E.2.2.2: ports from the card, lowered, parentheses dropped, and the two
    // device cards between it and `.ENDS` as E.2.2.3 translates them. `vcc` is
    // an internal node and appears only in the body.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module ecposc(out, gnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "vsine #(.dc(5)) va(vcc, gnd);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(10000)) r1(b1, gnd);") != null);
    // The `.TRAN` after `.ENDS` is outside the body and is still not a module.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "100n") == null);
}

test "a .SUBCKT's device cards are its body, and an unreadable one is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT RDIV IN OUT GND
        \\R1 IN OUT 1K
        \\R2 OUT GND 3K
        \\S1 OUT IN GND 0 SWMOD
        \\R3 A B RMOD
        \\.ENDS RDIV
        \\R9 X Y 1K
    , "");
    try std.testing.expectEqual(@as(u32, 1), s.modules);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(1000)) r1(in, out);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "resistor #(.r(3000)) r2(out, gnd);") != null);
    // A letter VerA has no row for (`S`, a switch) and no number on a
    // model-referenced R: neither becomes an instance, and each is a refusal
    // located at its line.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "s1") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "r3") == null);
    try std.testing.expectEqual(@as(usize, 2), s.refused.len);
    try std.testing.expectEqual(@as(u32, 51), s.refused[0].at);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[1].why, "`rmod` is not a number") != null);
    // `R9` is after `.ENDS`: top-level netlist, not part of any definition.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "r9") == null);

    // A repeated `.SUBCKT` is dropped with its body: the cards inside must not
    // fall out into the next module, or into a module of their own.
    const dup = try synthesize(arena,
        \\.SUBCKT PAD A B
        \\R1 A B 1K
        \\.ENDS
        \\.SUBCKT PAD A B
        \\R1 A B 9K
        \\.ENDS
    , "");
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
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // §2.6.2 Table 2-1 by way of E.2.2.3's `resistor #(.r(10k))`: `10K` is 10000.
    // §3.4.2's `from` range survives the substitution: it belongs to the
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
    // §2.6.2 Table 2-1 makes it mega.
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
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // The terminator is the point: `\input,` would scan the comma into the
    // name (§2.8.1 ends at white space, and `,` is printable ASCII).
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module amp(\\input , \\output );") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "electrical \\input , \\output ;") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module \\wire (c, b, e, s);") != null);
    // A name that is not a keyword is not escaped.
    const plain = try synthesize(arena, ".SUBCKT PAD IN OUT\n.ENDS\n", "");
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
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // E.2 treats the model as a module definition even though `2N2222` fails
    // §2.7's identifier shape.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module \\2n2222 (c, b, e, s);") != null);
    // The numeric node is the SPICE default and is a port, not the end of the
    // list: three ports, in card order, or §6.5.4's ordered binding is wrong.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "module flt(a, \\1 , b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "electrical a, \\1 , b;") != null);
    // A parameter assignment is outside the claimed subset (E.1.2).
    const p = try synthesize(arena, ".SUBCKT X N1 N2 PARAMS: W=2\n.ENDS\n", "");
    try std.testing.expectEqual(@as(u32, 0), p.modules);
    try std.testing.expectEqual(@as(usize, 1), p.refused.len);
    try std.testing.expect(std.mem.indexOf(u8, p.refused[0].why, "`params:`") != null);
}

test "an unrecognised model type, a repeat and an empty netlist all contribute nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "", "")).modules);
    const sw = try synthesize(arena, ".MODEL SW1 SW RON=1\n", "");
    try std.testing.expectEqual(@as(u32, 0), sw.modules);
    // E.1.2: kept by name and type, so its instance is refused as such.
    try std.testing.expectEqual(@as(usize, 1), sw.unsupported.len);
    try std.testing.expectEqualStrings("sw1 sw", sw.unsupported[0]);
    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "R1 a b 1k\n.TRAN 1n 1u\n", "")).modules);
    const dup = try synthesize(arena, ".MODEL M1 NPN\n.MODEL M1 PNP\n", "");
    try std.testing.expectEqual(@as(u32, 1), dup.modules);
    // A portless .SUBCKT is A.1.2's `module identifier ;`, not `electrical ;`.
    const bare = try synthesize(arena, ".SUBCKT PAD\n.ENDS\n", "");
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
    , "");
    for ([_][]const u8{
        "branch (a, x) vs;",
        "V(vs) <+ 0;",
        "V(b, \\0 ) <+ 2 * V(a, x);",
        "I(c, \\0 ) <+ 3 * V(a, x);",
        "I(d, \\0 ) <+ 4 * I(vs);",
        "V(b, c) <+ 5 * I(vs);",
    }) |want| try std.testing.expect(std.mem.indexOf(u8, s.text, want) != null);
    // A controlling V card the subcircuit does not declare is refused, and a
    // controlling V card is a branch of this module, not a `vsine` child.
    try std.testing.expect(std.mem.indexOf(u8, s.text, "6 *") == null);
    try std.testing.expectEqual(@as(usize, 1), s.refused.len);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "vsine") == null);
}

test "E.1.2 nested .SUBCKT, {expr} values and trailing fields in a body are refused, top-level cards are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT OUTER A B
        \\.SUBCKT INNER C D
        \\R1 A B {RVAL}
        \\R2 A B 1K TC=0.01
        \\.ENDS
        \\R9 X Y RMOD
        \\.TRAN 1N 1U
    , "");
    try std.testing.expectEqual(@as(usize, 3), s.refused.len);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[0].why, "nested") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[1].why, "{rval}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[2].why, "tc=0.01") != null);
}

test "E.2 an M/Q/J/D card instantiates its model's module, card parameters under the instance's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT AMP D G S B
        \\M1 D G S B NCH W=2U L = 50N M=3
        \\Q1 D G S QMOD 2
        \\Q2 D G S B QMOD
        \\D1 G S DIO 4 AREA=5
        \\J1 D G S MYJFET
        \\.ENDS
        \\.MODEL NCH BSIMCMG TYPE=1 L=20N NSD=2E+26
        \\.MODEL QMOD MYBJT BF=80
        \\.MODEL DIO DIODE_VA IS=1E-14
    , "");
    try std.testing.expectEqual(@as(usize, 0), s.refused.len);
    for ([_][]const u8{
        // The model card first (its `l` replaced by the instance's 50n, in
        // the card's place), then what only the instance sets; `M` is
        // E.4.1's multiplicity, `$mfactor`. 2e26 is real, not an integer.
        "   bsimcmg #(.type(1), .l(0.00000005), .nsd(2e26), .w(0.000002), .$mfactor(3)) m1(d, g, s, b);",
        // Q: a fifth name that is a number is the area, not a substrate.
        "   mybjt #(.bf(80), .area(2)) q1(d, g, s);",
        // ...and a fifth that is not is the model after a substrate.
        "   mybjt #(.bf(80)) q2(d, g, s, b);",
        // An explicit `area=` wins over the positional one.
        "   diode_va #(.is(0.00000000000001), .area(5)) d1(g, s);",
        // No `.MODEL`: the name is a module or paramset of the design.
        "   myjfet j1(d, g, s);",
    }) |want| {
        if (std.mem.indexOf(u8, s.text, want) == null) {
            std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, s.text });
            return error.TestUnexpectedResult;
        }
    }
}

test "E.2 a card whose model is a Table E.1 semiconductor is E0953; a binned model and a bad value are E0928" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL NMOS_LVT NMOS LEVEL = 72
        \\.MODEL PCH.1 BSIM4 LMIN=1U
        \\.SUBCKT INV A Y VDD VSS
        \\MN Y A VSS VSS NMOS_LVT L=21N
        \\MP Y A VDD VDD PCH L=21N
        \\MX Y A VDD VDD BSIM4 L={LEN}
        \\MY Y A VDD VDD BSIM4 OFF
        \\.ENDS
    , "");
    try std.testing.expectEqual(@as(usize, 4), s.refused.len);
    try std.testing.expect(s.refused[0].code == .E0953);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[0].why, "Table E.1's `mosfet`") != null);
    try std.testing.expect(s.refused[1].code == .E0928);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[1].why, "binned") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[2].why, "{len}") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.refused[3].why, "`off`") != null);
}

test "a card value at or past 2^31 that is integral is spelled real" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10000", try std.fmt.bufPrint(&buf, "{f}", .{num(1e4)}));
    try std.testing.expectEqualStrings("2147483647", try std.fmt.bufPrint(&buf, "{f}", .{num(2147483647)}));
    try std.testing.expectEqualStrings("2.147483648e9", try std.fmt.bufPrint(&buf, "{f}", .{num(2147483648)}));
    try std.testing.expectEqualStrings("0.5", try std.fmt.bufPrint(&buf, "{f}", .{num(0.5)}));
}
