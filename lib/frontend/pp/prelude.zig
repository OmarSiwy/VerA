//! The prelude snapshot: the Annex D/E definitions, preprocessed once and reused.
//!
//! In: the embedded standard-definition text. Out: a macro table and output snapshot every
//! compilation starts from, so disciplines.vams is not re-scanned per file.
//!
//! LRM clauses this file's code cites: §1, §6.7.
//!
//! Cut verbatim from `preprocessor.zig`.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const pp_annex_d = @import("annex_d.zig");
const pp_annex_e = @import("annex_e.zig");
const Allocator = Preprocessor.Allocator;
const diag = @import("diag");
const Lexer = @import("../lexer.zig");
const token = @import("../token.zig");
const Parser = @import("../parser.zig");
const predefined_macros = Preprocessor.predefined_macros;
const Macro = Preprocessor.Macro;
const Pp = Preprocessor.Pp;

// ---------------------------------------------------------------------------
// The prelude snapshot
// ---------------------------------------------------------------------------

/// Annex D.2 + annex D.1 + Table E.1, already preprocessed, computed once per
/// PROCESS instead of once per compilation.
///
/// WHY. Those three files are compile-time string constants and nothing a
/// caller can pass changes what they preprocess to: they contain no `include
/// (so `Options.include_dirs` cannot reach them), and the only conditionals they
/// test — `CONSTANTS_VAMS, `DISCIPLINES_VAMS, the six `*_ABSTOL overrides — are
/// macros that can only exist if the USER's text defined them, and the user's
/// text runs after this. The annex E.2 netlist tail is the one part that does
/// vary, and it is appended by `process` after the replay, unchanged.
/// So the snapshot is keyed on nothing, and this is a snapshot rather than a
/// cache: exactly one entry, of fixed content, whose size is
/// `constants_vams.len + disciplines_vams.len + spice_primitives.len` stripped
/// of comments plus ~12 KB of output — the bound is those three literals, and
/// nothing at runtime can add a fourth.
///
/// MEASURED, `zig build benchmark -- fixtures` on this tree, before → after, **in
/// DEBUG** — that invocation takes the default `-Doptimize`, which is Debug, and
/// the run predates the bench printing its mode:
/// `pp` 902.5 ms → 186.0 ms and `lint` 2.700 s → 1.970 s over the 1164-fixture
/// batch, with every byte column identical. Re-expanding it was 79% of stage 1
/// and 27% of everything up to MIR, because a 200-byte model still paid for
/// 11,791 bytes of shipped prelude (`bench -- gen`, `contrib n=1`: 0.69 ms of
/// `pp`, of which 0.08 ms is now the whole phase).
///
/// The shipping figures for the SAME batch, `bench -Doptimize=ReleaseFast --
/// fixtures`: `pp` 19.5 ms, `lint` 247.0 ms — i.e. `pp` is 7.9% of lint, which
/// is the proportion this snapshot has to keep true. The `before` column cannot
/// be re-measured in any mode: that code is gone.
///
/// WHAT IT HOLDS is everything the three `runFile` calls wrote into `Pp`:
/// the output bytes, the source-map segments, the macros, and the `Bag` file
/// registrations the segments index by position. A field added to `Pp` that the
/// prelude can write is a field that must be added here too — the equivalence
/// test at the bottom of this file is what catches that, and `runStdDefs` is
/// deliberately the only spelling of the three-file sequence so there is one
/// thing to compare against.
///
/// It also holds the STAGE 2 result for the same bytes — `tags`/`starts`, see
/// `preludeTokens` — and the STAGE 3 result, `ast`, see `preludeAst`. Neither is
/// a preprocessor output, but both are functions of the same three literals and
/// of nothing else, so both are keyed on nothing for the same reason, and there
/// is no second place to put either that does not need a second copy of this
/// argument. Each has its own equivalence test at the bottom too.
///
/// LIFETIME: process-lifetime and never freed. Every compilation `@memcpy`s the
/// text into its own arena, so the borrowed-text rule in root.zig's OWNERSHIP
/// section is untouched; what the `Bag` borrows (the stripped file texts, macro
/// bodies) outlives every arena instead of dying with one, which is strictly
/// safer than before.
///
/// THREAD SAFETY: safe. The snapshot is published by one release store of a
/// pointer, read by an acquire load, and is immutable after publication. Two
/// threads that race the first compilation both build one and one loses the
/// compare-exchange; the loser's arena leaks, bounded by the number of racing
/// threads and byte-identical to the winner's either way.
pub const Prelude = struct {
    text: []const u8,
    /// `text`'s tokens, `.eof` excluded — see `preludeTokens`. Two columns
    /// rather than a `TokenList` because that is the shape `Lexer.Seed` wants
    /// and a `MultiArrayList`'s own slice is not stable across a resize.
    tags: []const token.Tag,
    starts: []const u32,
    /// STAGE 3 for the same tokens — see `preludeAst`.
    ast: Parser.Parser.Seed,
    segs: []const diag.Segment,
    macros: []const Def,
    /// In registration order, which is what makes `segs`' `FileId`s — indices
    /// into `Bag.files` — mean the same thing on replay as they did on capture.
    files: [3]File,

    const Def = struct { name: []const u8, macro: Macro };
    const File = struct {
        name: []const u8,
        raw: []const u8,
        stripped: []const u8,
        /// The stripped→raw offset map `stripComments` left on the bag, so a
        /// replayed registration renders exactly like a fresh one.
        marks: []const diag.StripMark,
    };
};

pub var prelude_snapshot: std.atomic.Value(?*const Prelude) = .init(null);

/// Stage 2's half of the snapshot: the prelude's tokens, ready to be handed to
/// `Lexer.tokenizeSeeded` so a compilation lexes only the bytes AFTER the
/// prelude. `null` when `std_defs` is off — there is then no prefix to skip.
///
/// WHY THIS IS SOUND. `process` writes `replayStdDefs`' bytes first and nothing
/// else can precede them, so `Prelude.text` is a byte-for-byte prefix of every
/// preprocessed text compiled with `std_defs`, at offset 0, every time. Annex
/// E.2's netlist tail and the user's source both land AFTER it and are lexed
/// normally. `Lexer.next` reads no state but the cursor, so resuming at
/// `text.len` is the same scan the whole-buffer call would have done from there.
///
/// LIFETIME and THREAD SAFETY: `Prelude`'s, unchanged. The two columns live in
/// the process-lifetime arena, are immutable after publication, and the
/// compilation `@memcpy`s them into its own arena exactly as it does the text.
pub fn preludeTokens(std_defs: bool) Allocator.Error!?Lexer.Lexer.Seed {
    if (!std_defs) return null;
    const p = try preludeSnapshot();
    return .{ .tags = p.tags, .starts = p.starts, .len = @intCast(p.text.len) };
}

/// Stage 3's half of the snapshot: what parsing the prelude's tokens leaves in
/// the parser, ready to be handed to `Parser.initSeeded` so a compilation parses
/// only the tokens AFTER the prelude. `null` when `std_defs` is off.
///
/// WHY THIS IS SOUND, on top of `preludeTokens`' argument (which already
/// establishes that the prelude is the same leading run of tokens every time):
///
///   - **The ids are already a prefix.** `StrId`, `ExprId`, `StmtId` and the
///     `exprs.pool` offsets are all "index into an append-only column", assigned
///     as `id = column.len` at insert. The parser walks tokens in order and the
///     prelude's tokens come first, so the prelude's ids are 0..N-1 in the same
///     order in every compilation, seeded or not. Nothing interns ahead of
///     `parseSourceFile` — `access_names`' "V"/"I" go into a separate `void`
///     set, not the interner. So the prefix property is a consequence of
///     insertion order, not something this seed has to engineer.
///   - **Nothing below the parser writes the prelude's declarations**, so the
///     `ModuleDecl`/`NatureDecl`/`DisciplineDecl` arrays are SHARED out of the
///     process-lifetime arena rather than copied. See `Ast.SourceFile.seedFrom`,
///     which carries the evidence.
///   - **The stores ARE appended to** (§6.7 flattening clones expressions and
///     interns flat names into them), so those are copied per compilation. That
///     copy is the entire cost of this cache.
///
/// MEASURED, ReleaseFast, min of 500, the 6-line resistor in root.zig's tests:
/// parsing the prelude's 2,574 tokens was **82.7 µs of the 109.7 µs** a whole
/// `.lint` compilation cost. Cloning what it produces instead — 777 expression
/// rows, 63 statements, 154 interned names and their map, 19+16+11 decls — is
/// ~13 µs on a cold arena, of which 3.4 µs is the interner map.
///
/// LIFETIME and THREAD SAFETY: `Prelude`'s, unchanged. One wrinkle worth naming:
/// the seed's interned names borrow `Prelude.text`, while the compilation's own
/// names borrow its private copy of the same bytes. Both are content-identical
/// and the interner hashes and compares by content, so the mixed provenance is
/// invisible — and the prelude's half now outlives every arena instead of dying
/// with one.
pub fn preludeAst(std_defs: bool) Allocator.Error!?*const Parser.Parser.Seed {
    if (!std_defs) return null;
    const p = try preludeSnapshot();
    return &p.ast;
}

pub fn preludeSnapshot() Allocator.Error!*const Prelude {
    if (prelude_snapshot.load(.acquire)) |p| return p;
    const p = try buildPrelude();
    if (prelude_snapshot.cmpxchgStrong(null, p, .release, .acquire)) |won| return won.?;
    return p;
}

/// Run the three files once, on an arena that is never freed, and freeze what
/// they produced.
pub fn buildPrelude() Allocator.Error!*const Prelude {
    const arena_state = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena_state.* = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    var pp: Pp = .{ .arena = arena, .opts = .{ .bag = &bag } };
    // The same starting state `process` has: the compilation unit is file 0 and
    // the §10.5 predefined macros are already in scope. Both are observable to a
    // `ifdef in a prelude file, so neither may be skipped here.
    _ = try bag.addFile("<source>", "");
    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }

    pp.runStdDefs() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The three files are compile-time constants that this tree's tests
        // preprocess on every run; a diagnostic out of them is a broken build,
        // not a user error, and there is no user bag to report it into.
        error.PreprocessFailed => unreachable,
    };

    // Nothing the prelude writes may be left behind: these are the rest of
    // `Pp`'s output surface, and each is empty because the shipped files hold no
    // `default_discipline, no `default_transition, no `timescale, no
    // `default_nettype/`celldefine/`unconnected_drive and no unclosed `ifdef.
    // An added prelude file that breaks one of these must extend `Prelude`
    // rather than lose the event.
    std.debug.assert(pp.defaults.items.len == 0);
    std.debug.assert(pp.transitions.items.len == 0);
    std.debug.assert(pp.timescale == null);
    std.debug.assert(pp.conds.items.len == 0);
    std.debug.assert(pp.nettypes.items.len == 0);
    std.debug.assert(pp.cells.items.len == 0);
    std.debug.assert(pp.drives.items.len == 0);

    var macros: std.ArrayList(Prelude.Def) = .empty;
    var it = pp.macros.iterator();
    while (it.next()) |e| {
        // §10.5's two are re-inserted by `process` itself, from the same
        // literals, so replaying them would be a second spelling of one fact.
        if (e.value_ptr.predefined) continue;
        try macros.append(arena, .{ .name = e.key_ptr.*, .macro = e.value_ptr.* });
    }

    // Stage 2 for the same three files, also once per process.
    var toks = try Lexer.Lexer.tokenize(arena, pp.out.items);
    std.debug.assert(toks.len > 0 and toks.items(.tag)[toks.len - 1] == .eof);

    // Stage 3, on the WHOLE token list including its `.eof` — `Parser.init`
    // requires one, and the parse stops ON it, which is what makes `pos` the
    // prelude's token count and therefore the first index a resumed parse reads.
    var parser = Parser.Parser.init(arena, pp.out.items, toks.items(.tag), toks.items(.start), &bag);
    const file = parser.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Same argument as `runStdDefs`' above: a diagnostic out of three
        // compile-time constants is a broken build, not a user error, and there
        // is no user bag to report it into.
        error.ParseError => unreachable,
    };
    // Nothing the prelude parse leaves behind may be lost: these are the rest of
    // `Parser`'s state surface, and each is back at its `init` value because the
    // shipped files open no `begin_keywords, no generate region, no analog
    // function and no connect module that outlives its own `end*`. A prelude
    // file that breaks one of these must extend `Parser.Seed` rather than lose
    // the event — which is exactly the shape of `Pp`'s four asserts above.
    std.debug.assert(!parser.failed and bag.list.items.len == 0);
    std.debug.assert(parser.pos == toks.len - 1);
    std.debug.assert(parser.kw_set == token.default_keyword_set);
    std.debug.assert(parser.kw_stack.items.len == 0);
    std.debug.assert(parser.attrs.items.len == 0 and parser.attr_depth == 0);
    std.debug.assert(!parser.in_analog_fn and !parser.in_connect_module);
    std.debug.assert(parser.gen_depth == 0 and parser.gen_construct_depth == 0);

    var access: std.ArrayList([]const u8) = .empty;
    var ait = parser.access_names.keyIterator();
    while (ait.next()) |k| try access.append(arena, k.*);

    // The `.eof` is dropped from the SEED columns: it is a property of the
    // buffer being lexed, and the buffer the compilation lexes ends past the
    // user's source, not here. After the parse, which needed it.
    toks.len -= 1;

    const p = try arena.create(Prelude);
    p.* = .{
        .text = pp.out.items,
        .tags = toks.items(.tag),
        .starts = toks.items(.start),
        .ast = .{
            .file = file,
            .access_names = access.items,
            .pos = parser.pos,
            .gen_construct = parser.gen_construct,
        },
        .segs = pp.segs.items,
        .macros = macros.items,
        .files = .{
            .{ .name = "constants.vams", .raw = pp_annex_d.constants_vams, .stripped = bag.fileText(@enumFromInt(1)), .marks = bag.fileMarks(@enumFromInt(1)) },
            .{ .name = "disciplines.vams", .raw = pp_annex_d.disciplines_vams, .stripped = bag.fileText(@enumFromInt(2)), .marks = bag.fileMarks(@enumFromInt(2)) },
            .{ .name = "spice_primitives.vams", .raw = pp_annex_e.spice_primitives, .stripped = bag.fileText(@enumFromInt(3)), .marks = bag.fileMarks(@enumFromInt(3)) },
        },
    };
    return p;
}
