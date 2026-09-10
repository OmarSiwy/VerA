//! Class 1 — Preprocessing & compiler directives.
//! LRM ch10 (§10.4 `define/`undef, §10.5 predefined macros, §10.7 `__FILE__/
//! `__LINE__ and the IEEE 1364 `line that remaps them, §10.2
//! `default_discipline), §2.4 (comments), §2.8.4 (directives), annex D.1
//! (disciplines.vams), annex D.2 (constants.vams).
//!
//! Transformation: raw source text + include dirs → preprocessed text
//! (macros expanded, comments stripped preserving newlines, `include inlined).
//! The preprocessed bytes are the CACHE IDENTITY (hash these), so macro/include
//! changes are part of the fingerprint.
//!
//! DOD: output is a single flat `[]u8` in the caller's arena. Directive tables
//! are comptime StaticStringMaps. Define storage is a StringHashMap keyed by
//! macro name (cold — touched only at directive sites, not per-token). The
//! annex D + Table E.1 preload is a pure function of the directive set, so it
//! is preprocessed ONCE PER PROCESS and `@memcpy`d into each compilation's
//! arena — see `Prelude`, which carries the measurement and the bound.
//!
//! Line-number contract: every byte this stage deletes (comments, directives,
//! inactive `ifdef arms) is replaced by exactly the newlines it contained, so
//! `\n`-counting a byte offset in the output yields the source line — for the
//! LAST file processed. Prepended std defs and `include shift that; the caller
//! gets the prelude length back via `Options.prelude_len` to compensate.
//!
//! PROVENANCE. The line-number contract above only ever held per file. This
//! stage therefore also publishes a `diag.SourceMap`: one `Segment` every time
//! the ORIGIN of the output changes (entering a file, returning from an
//! `include, starting a macro expansion) plus one after every directive,
//! because a directive that collapses to its newlines shortens the output
//! relative to its file and breaks the linear mapping the segment assumes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag.zig");
/// §2.6.2 number decoding, for §10.3's `transition_time` operand, and the
/// prelude's own token snapshot. The lexer does not depend on this file, so the
/// edge only goes one way.
const Lexer = @import("lexer.zig");
const token = @import("token.zig");
/// Stage 3, imported by stage 1 for ONE reason: the prelude snapshot below
/// carries the PARSE of the same three files, for the same "keyed on nothing"
/// argument as the text and the tokens. Nothing else in this file parses.
const Parser = @import("parser.zig");
/// Annex E.2 — the `.MODEL`/`.SUBCKT` reader whose output joins this prelude.
const spice_cards = @import("spice_cards.zig");

pub const Options = struct {
    /// Searched in order for `include, before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    file_name: []const u8 = "<source>",
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams.
    std_defs: bool = true,
    /// Annex E.2 — SPICE netlist text this compilation may read `.MODEL` and
    /// `.SUBCKT` declarations out of, one card per line (`//! spice`). Read by
    /// `spice_cards.synthesize`, which turns each into a module and appends it to
    /// the Table E.1 prelude; empty means E.1.1's antecedent is false for this
    /// compilation and nothing is appended. Only with `std_defs`, since a model
    /// card's interface comes from a Table E.1 primitive that would not be there.
    spice_netlist: []const u8 = "",
    /// Out-param: how many modules `spice_netlist` contributed, so the caller can
    /// tell the netlist-derived tail of the prelude from Table E.1's own rows —
    /// E.2.1's case-insensitive fallback applies to the tail only.
    spice_netlist_modules: ?*u32 = null,
    /// Out-param: byte length of the prepended std-def prelude, so a caller
    /// mapping an output offset back to a user source line can subtract it.
    prelude_len: ?*u32 = null,
    /// Out-param: every §10.2 `default_discipline event, in text-stream order,
    /// for §7.4 discipline resolution to consult. Arena-owned like the output.
    defaults: ?*[]const DefaultDiscipline = null,
    /// Out-param: every §10.3 `default_transition event, in text-stream order,
    /// for §4.5.8's rise/fall defaulting to consult. Arena-owned like the
    /// output.
    transitions: ?*[]const DefaultTransition = null,
    /// Out-param: the IEEE 1364 §19.9 `timescale in force, or null if the
    /// stream declared none. Read by §9.15 Table 9-27's "timeUnit" and
    /// "timePrecision", which are the only two rows of that table whose value
    /// comes out of the SOURCE rather than out of a simulator's preferences.
    timescale: ?*?Timescale = null,
    /// Where diagnostics go, and where the file table and the source map are
    /// published. Required: preprocessing that nobody can hear is not useful.
    bag: *diag.Bag,
};

pub const Error = Allocator.Error || error{PreprocessFailed};

/// Depth caps. Blown caps are reported as normal diagnostics, never panics.
const max_include_depth = 32;
const max_expansion_depth = 128;
/// `include file size cap.
const max_include_bytes = 1 << 24;

/// Directives handled here. LRM §10 Table 10-1.
pub const Directive = enum {
    define, // §10.4
    undef, // §10.4
    ifdef, // IEEE 1364
    ifndef, // IEEE 1364
    elsif, // IEEE 1364
    @"else", // IEEE 1364
    endif, // IEEE 1364
    include, // IEEE 1364
    resetall, // IEEE 1364 — clears user macros (predefined ones survive)
    keywords, // §10.6 — emitted verbatim, handled by the parser
    default_discipline, // §10.2 — parsed here, applied by discipline resolution
    default_transition, // §10.3 — parsed here, applied by §4.5.8 codegen
    line, // IEEE 1364 §19.7 — remaps §10.7 `__LINE__` / `__FILE__`
    timescale, // IEEE 1364 §19.9 — read back by §9.15 Table 9-27
    ignored, // parsed, consumed to end of line, no effect
};

/// §10.2 Syntax 10-1:
///
///   default_discipline_directive ::=
///       `default_discipline [ discipline_identifier [ qualifier ] ]
///   qualifier ::= integer | real | reg | wreal | wire | tri | wand | triand
///               | wor | trior | trireg | tri0 | tri1 | supply0 | supply1
///
/// A CLOSED alternation of fifteen names, so anything else in that slot is a
/// syntax error and not a second discipline (E0127).
const qualifiers = std.StaticStringMap(void).initComptime(.{
    .{"integer"}, .{"real"}, .{"reg"},    .{"wreal"},   .{"wire"},
    .{"tri"},     .{"wand"}, .{"triand"}, .{"wor"},     .{"trior"},
    .{"trireg"},  .{"tri0"}, .{"tri1"},   .{"supply0"}, .{"supply1"},
});

/// One `default_discipline (or the `resetall / bare form that withdraws one),
/// in the order the text stream met it. §10.2 makes the directive POSITIONAL —
/// it applies "to all discrete signals without a discipline declaration that
/// appear in the text stream FOLLOWING the use of the directive" — so the
/// events are published rather than a single final table, and the consumer
/// (§7.4 discipline resolution, ir/lower.zig) looks the net's own declaration
/// offset up against them.
///
/// `at` is an offset into the PREPROCESSED output, which is the one currency
/// every stage after this one reports in (see root.zig `compileInArena`), so
/// it compares directly against a token start.
pub const DefaultDiscipline = struct {
    at: u32,
    /// Syntax 10-1's optional qualifier; "" when the directive named none.
    qualifier: []const u8,
    /// "" WITHDRAWS every default in force from `at` on. §10.2: "In addition
    /// to `resetall, if this directive is used without a discipline name,
    /// discipline resolution will not use a default discipline for nets
    /// declared after this directive is encountered in the text stream."
    discipline: []const u8,
};

/// One §10.3 `` `default_transition ``, in the order the text stream met it.
///
/// An event list rather than a single latched value, for the reason
/// `DefaultDiscipline` is one: §10.3 makes the directive POSITIONAL. "If
/// another `default_transition directive is encountered in the subsequent
/// source description, the transition filters following the newly encountered
/// directive derive their default rise and fall times from … the directive
/// which IMMEDIATELY PRECEDES the transition filter." A latched value cannot
/// express supersession — it answers the first directive, or the last, but
/// never "the nearest one above this call".
///
/// `at` is an offset into the PREPROCESSED output, the currency every later
/// stage reports in, so it compares directly against a token start.
pub const DefaultTransition = struct {
    at: u32,
    /// Seconds. §10.3's transition_time, used for BOTH the rise and the fall.
    time: f64,
};

/// IEEE Std 1364 §19.9 `` `timescale <unit> / <precision> ``, in SECONDS.
///
/// The analog kernel has no tick — §9.10 `$abstime` is seconds whatever this
/// directive says, which ch10_directives/19 pins — so nothing here rescales a
/// time base. The directive is parsed for exactly one reason: §9.15 Table 9-27
/// makes both operands readable, "Time unit as specified in `timescale, in
/// seconds", and they are the only two rows of that table that are a property
/// of the SOURCE rather than of a simulator's preference file.
pub const Timescale = struct {
    unit: f64,
    precision: f64,
};

pub const directive_map = std.StaticStringMap(Directive).initComptime(.{
    .{ "define", .define },
    .{ "undef", .undef },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "elsif", .elsif },
    .{ "else", .@"else" },
    .{ "endif", .endif },
    .{ "include", .include },
    .{ "resetall", .resetall },

    // §10.6. The only directives that outlive the preprocessor: which annex B
    // words are reserved is a parse-time property of the design elements that
    // follow, and §10.6 restricts the directive to sit "outside of a design
    // element" — neither is knowable from the text stream. Emitted verbatim so
    // the lexer can tag them (`dir_begin_keywords`) and the parser can act.
    .{ "begin_keywords", .keywords },
    .{ "end_keywords", .keywords },

    // §10.2 and IEEE 1364 §19.7: both carry state past their own line, so both
    // are parsed here and published (`Options.defaults`, `Pp.line_*`).
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },

    .{ "default_transition", .default_transition }, // §10.3 — read by §4.5.8

    .{ "timescale", .timescale }, // IEEE 1364 §19.9 — §9.15 reads it back
    .{ "default_nettype", .ignored }, // IEEE 1364
    .{ "celldefine", .ignored }, // IEEE 1364
    .{ "endcelldefine", .ignored }, // IEEE 1364
    .{ "unconnected_drive", .ignored }, // IEEE 1364
    .{ "nounconnected_drive", .ignored }, // IEEE 1364
    .{ "pragma", .ignored }, // IEEE 1364
});

/// LRM §10.5. Defined for every compilation; `undef on these has no effect.
const predefined_macros = [_][]const u8{
    "__VAMS_ENABLE__",
    "__VAMS_COMPACT_MODELING__",
};

/// Built-in annex D files, resolvable by `include even with no include_dirs.
/// All three are self-guarded (`ifdef CONSTANTS_VAMS / DISCIPLINES_VAMS /
/// DRIVER_ACCESS_VAMS), so an explicit `include after the prelude expands to
/// nothing.
///
/// D.3 driver_access.vams is here even though driver access itself is a §7
/// digital feature VerA does not implement: annex D is normative and its
/// requirement is that the implementation SUPPLY the file. The file is twelve
/// `defines and nothing else, so shipping it costs nothing and a model that
/// `includes it is no longer refused for a file the standard says exists.
/// Only D.1/D.2 are preloaded (see `process`); D.3 must be asked for.
pub const builtin_includes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "constants.vams", constants_vams },
    .{ "disciplines.vams", disciplines_vams },
    .{ "driver_access.vams", driver_access_vams },
});

/// Main entry. LRM ch10.
/// Strips comments (§2.4, preserving newline count), runs the conditional
/// stack, expands object- and function-like macros (§10.4), inlines `include,
/// and prepends the annex D standard definitions.
/// Returns arena-owned bytes; on failure adds to `opts.bag` and returns
/// `error.PreprocessFailed`.
pub fn process(arena: Allocator, source: []const u8, opts: Options) Error![]const u8 {
    var pp: Pp = .{ .arena = arena, .opts = opts };

    // FIRST, so the compilation unit is `.root`. The prelude files register
    // after it, even though they are processed before it.
    const root = try opts.bag.addFile(opts.file_name, source);

    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }

    if (opts.std_defs) {
        // The three shipped files, replayed from the process-lifetime snapshot
        // rather than re-preprocessed — see `Prelude`. Byte-identical to
        // `runStdDefs`, which is what builds the snapshot and what the
        // equivalence test below re-runs by hand.
        try pp.replayStdDefs();
        // Annex E.2 after Table E.1: a `.MODEL` wrapper instantiates the
        // primitive its type names, so the primitive has to be declared first.
        const cards = try spice_cards.synthesize(arena, opts.spice_netlist);
        if (cards.modules != 0) {
            try pp.runFile(cards.text, "spice_netlist.vams", null);
            if (opts.spice_netlist_modules) |n| n.* = cards.modules;
        }
    }
    const prelude = pp.out.items.len;
    if (opts.prelude_len) |p| p.* = @intCast(prelude);

    try pp.runFile(source, opts.file_name, root);

    if (pp.conds.items.len != 0) {
        const top = pp.conds.items[pp.conds.items.len - 1];
        pp.cur_file_id = top.file;
        pp.expand_site = null;
        // The catalogue's contract for E0101: point at end of source, name the
        // unclosed directive in a label.
        const text = opts.bag.fileText(top.file);
        var b = pp.failWith(.{ .start = @intCast(text.len), .end = @intCast(text.len) }, .E0101);
        b.msg("", .{});
        b.label(top.span, "unclosed", .{});
        try b.emit();
        return error.PreprocessFailed;
    }

    if (opts.defaults) |d| d.* = try pp.defaults.toOwnedSlice(arena);
    if (opts.transitions) |t| t.* = try pp.transitions.toOwnedSlice(arena);
    if (opts.timescale) |t| t.* = pp.timescale;

    opts.bag.map = .{
        .segs = try pp.segs.toOwnedSlice(arena),
        // ZERO, not the prelude's newline count: `prelude_lines` corrects a
        // root line number that was measured in the PREPROCESSED text, and the
        // segments above already resolve a root offset to root's own text.
        // Subtracting twice would put every user error ~100 lines too early.
        // `Options.prelude_len` still reports the byte length for callers that
        // slice the output themselves.
        .prelude_lines = 0,
    };
    return pp.out.toOwnedSlice(arena);
}

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
/// MEASURED, `zig build bench -- fixtures` on this tree, before → after, **in
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
const Prelude = struct {
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

var prelude_snapshot: std.atomic.Value(?*const Prelude) = .init(null);

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

fn preludeSnapshot() Allocator.Error!*const Prelude {
    if (prelude_snapshot.load(.acquire)) |p| return p;
    const p = try buildPrelude();
    if (prelude_snapshot.cmpxchgStrong(null, p, .release, .acquire)) |won| return won.?;
    return p;
}

/// Run the three files once, on an arena that is never freed, and freeze what
/// they produced.
fn buildPrelude() Allocator.Error!*const Prelude {
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

    // Nothing the prelude writes may be left behind: these four are the rest of
    // `Pp`'s output surface, and each is empty because the shipped files hold no
    // `default_discipline, no `default_transition, no `timescale and no unclosed
    // `ifdef. An added prelude file that breaks one of these must extend
    // `Prelude` rather than lose the event.
    std.debug.assert(pp.defaults.items.len == 0);
    std.debug.assert(pp.transitions.items.len == 0);
    std.debug.assert(pp.timescale == null);
    std.debug.assert(pp.conds.items.len == 0);

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
            .{ .name = "constants.vams", .raw = constants_vams, .stripped = bag.fileText(@enumFromInt(1)), .marks = bag.fileMarks(@enumFromInt(1)) },
            .{ .name = "disciplines.vams", .raw = disciplines_vams, .stripped = bag.fileText(@enumFromInt(2)), .marks = bag.fileMarks(@enumFromInt(2)) },
            .{ .name = "spice_primitives.vams", .raw = spice_primitives, .stripped = bag.fileText(@enumFromInt(3)), .marks = bag.fileMarks(@enumFromInt(3)) },
        },
    };
    return p;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Macro = struct {
    /// Empty and `is_func == false` ⇒ object-like macro (§10.4).
    params: []const []const u8 = &.{},
    is_func: bool = false,
    body: []const u8,
    /// §10.5 predefined: survives `undef and `resetall.
    predefined: bool = false,
};

/// One `ifdef/`ifndef level.
const Cond = struct {
    /// Enclosing levels are all emitting.
    parent_active: bool,
    /// This level emits right now (already includes `parent_active`).
    active: bool,
    /// Some arm of this level was taken — later `elsif/`else are dead.
    taken: bool,
    seen_else: bool = false,
    /// The `ifdef that opened this level, for E0101's label.
    span: diag.Span = .{},
    file: diag.FileId = .root,
};

const Pp = struct {
    arena: Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    macros: std.StringHashMapUnmanaged(Macro) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    /// Macro-expansion cycle guard (§10.4): names currently being expanded.
    expanding: std.ArrayList([]const u8) = .empty,
    /// Every live `expand` call, argument pre-expansion included. `expanding`
    /// only counts body rescans, and argument pre-expansion runs BEFORE the
    /// name is pushed — so this, not `expanding.items.len`, is what E0119's
    /// nesting ceiling has to measure or `` `M(`M(`M(... `` recurses on the
    /// native stack unbounded.
    expand_depth: u32 = 0,
    /// `include stack, innermost last. Its depth IS the include depth.
    includes: std.ArrayList([]const u8) = .empty,
    /// Provenance of the output so far. Appended to only, so it stays sorted
    /// by `out_start` and `SourceMap.resolve` can binary-search it.
    segs: std.ArrayList(diag.Segment) = .empty,
    /// §10.2 events, in text-stream order. Published via `Options.defaults`.
    defaults: std.ArrayList(DefaultDiscipline) = .empty,
    /// §10.3 events, in text-stream order. Published via `Options.transitions`.
    transitions: std.ArrayList(DefaultTransition) = .empty,
    /// IEEE 1364 §19.9. Last one wins rather than a positional event list like
    /// `defaults`, and that IS a ceiling now: the directive scopes to the design
    /// elements that FOLLOW it, and since elaboration walks a hierarchy every
    /// module of one file shares this single value. Two modules with a
    /// `timescale between them therefore both see the second one. No fixture
    /// pins that (§9.6's tick has no analog kernel behind it — see E0908's
    /// note), which is why it stays a ceiling and not a bug report.
    // ponytail: make it a positional event list, exactly like `defaults`, the
    // day a fixture puts a `timescale between two module definitions.
    timescale: ?Timescale = null,
    /// IEEE 1364 §19.7 `line remap, for §10.7 `__LINE__` / `__FILE__`. Null
    /// when the current file is numbered naturally. `from` is the PHYSICAL
    /// 1-based line the remap starts at (the one after the directive), `to`
    /// the number §19.7 gives it, so a later line L reports `to + (L - from)`.
    /// Both are per-file: `runFile` saves and restores them, which is exactly
    /// §10.7's "revert to the values they had before the `include".
    line_from: u32 = 0,
    line_to: ?u32 = null,
    /// `line's optional file name, which §10.7 says the directive "may change
    /// `__FILE__` as well" with. Null ⇒ the real name of the current file.
    file_override: ?[]const u8 = null,
    /// The file the current offsets belong to.
    cur_file_id: diag.FileId = .root,
    /// Set while rescanning a macro BODY. Offsets inside a body index the
    /// body, not any file, so every diagnostic raised there is reported at the
    /// outermost invocation site instead — which is a real place in a real
    /// file, and the only honest answer.
    expand_site: ?u32 = null,

    fn emitting(pp: *const Pp) bool {
        const n = pp.conds.items.len;
        return n == 0 or pp.conds.items[n - 1].active;
    }

    /// Drop `span`'s text but keep its line count, so a dead `ifdef arm and a
    /// collapsed directive both leave the output as long, in LINES, as the
    /// input they replaced. Every diagnostic location downstream depends on it.
    ///
    /// Written as count-then-fill rather than the byte loop it replaces:
    /// `std.mem.count` with a one-byte needle IS `mem.countScalar`, which is
    /// vectorized in the stdlib (`std/mem.zig:1653`), and `appendNTimes` is one
    /// capacity check plus a `@memset`. The scalar reference lives in the
    /// "putNewlines counts the same newlines as the byte loop" test below.
    fn putNewlines(pp: *Pp, span: []const u8) Error!void {
        try pp.out.appendNTimes(pp.arena, '\n', std.mem.count(u8, span, "\n"));
    }

    /// A file-local span for `[start, end)` of the text being scanned.
    fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span {
        if (pp.expand_site) |s| return .at(s);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// §10.7 `__LINE__`: "the current input line number". PHYSICAL, 1-based,
    /// counted in the file being scanned — `stripComments` replaces every
    /// comment with the newlines it contained precisely so this holds — then
    /// put through the IEEE 1364 §19.7 `line remap if one is in force.
    ///
    /// `at` indexes the text being scanned, which inside a macro body is the
    /// BODY and not a file; there `expand_site` is the invocation offset, and
    /// the invocation is the only line in a real file this can honestly name.
    fn physicalLine(pp: *const Pp, at: usize) u32 {
        const off = pp.expand_site orelse @as(u32, @intCast(at));
        const text = pp.opts.bag.fileText(pp.cur_file_id);
        return @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n"));
    }

    fn currentLine(pp: *const Pp, at: usize) u32 {
        const phys = pp.physicalLine(at);
        const to = pp.line_to orelse return phys;
        // Saturating: a `line whose operand is smaller than the offset it
        // corrects for cannot produce a line 0, let alone a negative one.
        return if (phys >= pp.line_from) to + (phys - pp.line_from) else to;
    }

    /// Start a diagnostic. Preprocessor offsets are FILE-LOCAL — this stage
    /// fails before there is a preprocessed text to map them through.
    fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder {
        var b = pp.opts.bag.build(.preprocess, code, span);
        b.inFile(pp.cur_file_id);
        return b;
    }

    fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        var b = pp.failWith(span, code);
        b.msg(fmt, args);
        try b.emit();
        return error.PreprocessFailed;
    }

    /// Note the output now continues from `at` in the current file. Called
    /// after every directive, because a directive that collapses to its
    /// newlines makes the output shorter than the file it came from.
    fn resync(pp: *Pp, at: usize) Error!void {
        // Inside a macro body there is no file offset to resync to; the
        // enclosing `.macro` segment already covers the whole expansion.
        if (pp.expand_site != null) return;
        try pp.segs.append(pp.arena, .{
            .out_start = @intCast(pp.out.items.len),
            .in_start = @intCast(at),
            .file = pp.cur_file_id,
            .kind = .verbatim,
        });
    }

    /// The annex D + Table E.1 preload, the long way. Called ONCE per process,
    /// by `buildPrelude`; `process` replays its result. The only other caller is
    /// the equivalence test, which is the point of it being a function.
    fn runStdDefs(pp: *Pp) Error!void {
        // annex D.2 first: disciplines.vams reads `*_ABSTOL overrides, and the
        // constants are pure directives (they contribute only newlines here).
        try pp.runFile(constants_vams, "constants.vams", null);
        try pp.runFile(disciplines_vams, "disciplines.vams", null);
        // Annex E after annex D.1: the primitives' ports are `electrical`, which
        // disciplines.vams declares, and the source rows read `M_TWO_PI, which
        // constants.vams defines. Before the user's source, so nothing the user
        // `defines can reach into a shipped standard file.
        try pp.runFile(spice_primitives, "spice_primitives.vams", null);
    }

    /// `runStdDefs`' result, `@memcpy`d out of the process-lifetime snapshot.
    /// Must leave `pp` in exactly the state `runStdDefs` would have.
    fn replayStdDefs(pp: *Pp) Error!void {
        const p = try preludeSnapshot();
        for (p.files, 1..) |f, want_id| {
            const id = try pp.opts.bag.addFile(f.name, f.raw);
            // `Prelude.segs` names its file by index, so the three must land at
            // 1, 2, 3 — i.e. the caller registered the compilation unit as
            // `.root` and nothing else has registered a file yet. `process` is
            // the only caller and does exactly that.
            std.debug.assert(@intFromEnum(id) == want_id);
            // Registered raw, then repointed at the stripped text with its
            // offset marks, because that is the triple `runFile` leaves behind:
            // every span cut from this file indexes the stripped half, and the
            // renderer maps back through the marks.
            pp.opts.bag.setStrippedText(id, f.stripped, f.marks);
        }
        try pp.out.appendSlice(pp.arena, p.text);
        try pp.segs.appendSlice(pp.arena, p.segs);
        for (p.macros) |d| try pp.macros.put(pp.arena, d.name, d.macro);
    }

    /// Register, strip comments, then scan. Saves/restores the file context so
    /// an error inside an `include still names the right file. `existing` is
    /// the id of an already-registered file (the compilation unit, which must
    /// be `.root` and is therefore registered before the prelude runs).
    fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: ?diag.FileId) Error!void {
        const saved_id = pp.cur_file_id;
        defer pp.cur_file_id = saved_id;

        // §10.7: "An `include directive changes the expansions of `__FILE__ and
        // `__LINE__ to correspond to the included file. At the end of that file
        // ... the expansions of `__FILE__ and `__LINE__ revert to the values
        // they had before the `include". The included file is numbered
        // naturally until it says otherwise, and the parent's remap comes back
        // on the way out — nothing has to count the lines the include spliced
        // in, because `__LINE__` is always derived from a PHYSICAL offset in
        // whichever file is being scanned.
        const saved_from = pp.line_from;
        const saved_to = pp.line_to;
        const saved_override = pp.file_override;
        pp.line_from = 0;
        pp.line_to = null;
        pp.file_override = null;
        defer {
            pp.line_from = saved_from;
            pp.line_to = saved_to;
            pp.file_override = saved_override;
        }

        const id = existing orelse try pp.opts.bag.addFile(file, raw);
        pp.cur_file_id = id;

        // Registered RAW first so a stripComments failure resolves, then
        // repointed: every offset after this indexes the stripped text. The
        // raw text and the offset marks stay behind on the bag for rendering.
        const s = try stripComments(pp, raw);
        pp.opts.bag.setStrippedText(id, s.text, s.marks);
        const text = s.text;

        try pp.segs.append(pp.arena, .{
            .out_start = @intCast(pp.out.items.len),
            .in_start = 0,
            .file = id,
            .kind = .verbatim,
        });
        try scan(pp, text);
    }

    /// `A -> B -> C`, arena-owned. Only built when a diagnostic needs it.
    fn joinChain(pp: *Pp, stack: []const []const u8, last: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (stack) |s| {
            try out.appendSlice(pp.arena, s);
            try out.appendSlice(pp.arena, " -> ");
        }
        try out.appendSlice(pp.arena, last);
        return out.items;
    }
};

// ---------------------------------------------------------------------------
// §2.4 comments
// ---------------------------------------------------------------------------

const Stripped = struct { text: []const u8, marks: []const diag.StripMark };

/// Replace `//`- and `/* */`-comments with nothing, keeping every newline they
/// contained so line numbers survive. String literals (§2.7) are opaque.
/// Block comments do NOT nest (§2.4) — `/* a /* b */` ends at the first `*/`.
///
/// Also returns one `diag.StripMark` per comment collapsed — the stripped→
/// original offset map the renderer needs to put a caret on the line the user
/// WROTE. LINES already agree between the two texts (that is the newline
/// contract above); what a comment shifts is every COLUMN after it, and every
/// absolute offset below it, in ways only the stripper knows.
fn stripComments(pp: *Pp, src: []const u8) Error!Stripped {
    // Fast path: most sources shrink, none grow.
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, src.len);
    var marks: std.ArrayList(diag.StripMark) = .empty;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const start = i;
            // §2.7: an unterminated literal is the lexer's error to report; stop
            // at the newline so the rest of the file still preprocesses.
            i = stringStop(src, i);
            if (i < src.len and src[i] == '"') i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier (or a `define line continuation):
            // opaque up to the next whitespace, so `//` inside cannot start a
            // comment.
            const start = i;
            i += 1;
            while (i < src.len and !isSpace(src[i])) i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            // §2.4: to the end of the line. `indexOfScalarPos` IS vectorized in
            // the stdlib (`std/mem.zig:1241`), unlike the set-valued `findAnyPos`.
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            // The output stood still while the input advanced: from here the
            // two run in lockstep again, which is exactly one mark.
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            // Offsets here index `src`, which runFile registered before this
            // call precisely so this span resolves.
            if (i + 1 >= src.len) return pp.fail(pp.spanAt(start, start + 2), .E0102, "", .{});
            // §2.2: "spaces and newlines shall not be syntactically significant
            // other than being token separators", and the same list makes a
            // comment one of the seven lexical tokens — so a comment SEPARATES
            // the tokens around it. Re-emitting only the newlines is enough for
            // a multi-line comment and silently WELDS a single-line one:
            // `1/*c*/2` used to lex as the integer 12 and `<` `/*c*/` `=` as the
            // operator `<=`, both with no diagnostic. One byte of whitespace
            // fixes both, and it always fits: the comment it replaces is at
            // least the four bytes of `/**/`.
            const lines = std.mem.count(u8, src[start..i], "\n");
            if (lines == 0) {
                out.appendAssumeCapacity(' ');
            } else {
                out.appendNTimesAssumeCapacity('\n', lines);
            }
            i += 2;
            // After the replacement bytes, so the lockstep run the mark opens
            // starts at the first byte AFTER the comment on both sides.
            try marks.append(pp.arena, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        // Ordinary text: copy the whole run up to the next byte the branches
        // above care about, in one `appendSlice`. Same chain-outside /
        // scan-inside split as `scan`.
        //
        // `src[i]` is neither `"` nor `\` — both `continue` above — but it CAN
        // be a `/` that starts neither comment: at end of file, or before an
        // ordinary byte. That is the `end == i` case, and stepping one byte is
        // cheaper than teaching the stop set to exclude it.
        const end = findStop(src, i, "\"\\/");
        if (end == i) {
            out.appendAssumeCapacity(c);
            i += 1;
        } else {
            out.appendSliceAssumeCapacity(src[i..end]);
            i = end;
        }
    }
    return .{ .text = out.items, .marks = marks.items };
}

// ---------------------------------------------------------------------------
// Main scan
// ---------------------------------------------------------------------------

/// The three bytes `scan` branches on: a §2.7 string, a §2.8.1 escaped
/// identifier, and a §10 directive or macro use. Everything else is ordinary.
const scan_stops = "\"\\`";

/// First index at or after `from` whose byte is in `stops`, else `text.len`.
///
/// `std.mem.indexOfAnyPos` is the stdlib answer and would be the right rung of
/// the ladder, but in Zig 0.16 it is `mem.findAnyPos`, a plain nested scalar
/// loop doing one compare per (byte, needle) pair — `std/mem.zig:1347`, no
/// `@Vector` anywhere. Only the SINGLE-needle `findScalarPos` and `countScalar`
/// are vectorized, and neither takes a set. Hence the shape, hand-written:
/// splat each stop, OR the compare masks, count trailing zeros for the lane.
///
/// The scalar loop under the vector block is the tail, the fallback on a target
/// with no vectors, and the reference the differential test below compares
/// against. Do not delete it.
///
/// N here is the RUN, not the file. MEASURED over the 1164 fixtures: runs
/// between `scan`'s stops are median 23 bytes, mean 72, and runs between
/// `stripComments`' stops are median 6, mean 27 — so with 32 u8 lanes the
/// MEDIAN call never enters the vector block at all. It still pays, because
/// the length distribution is what matters and not its middle: 91% and 89% of
/// the BYTES respectively sit in runs of 32 or more.
fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
    var i = from;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = std.meta.Int(.unsigned, lanes);
        while (i + lanes <= text.len) : (i += lanes) {
            const block: V = text[i..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| {
                const splat: V = @splat(stop);
                hit |= @as(Mask, @bitCast(block == splat));
            }
            if (hit != 0) return i + @ctz(hit);
        }
    }
    while (i < text.len) : (i += 1) {
        inline for (stops) |stop| {
            if (text[i] == stop) return i;
        }
    }
    return i;
}

/// `text` is already comment-stripped. Copies bytes to `out`, handling
/// directives (§10) and macro uses (§10.4). In an inactive conditional arm
/// only newlines are emitted.
fn scan(pp: *Pp, text: []const u8) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // §2.7 strings are opaque to macro expansion and to directives.
        if (c == '"') {
            const start = i;
            i = stringStop(text, i);
            if (i < text.len and text[i] == '"') i += 1;
            if (pp.emitting()) {
                try pp.out.appendSlice(pp.arena, text[start..i]);
            } else {
                try pp.putNewlines(text[start..i]);
            }
            continue;
        }

        // §2.8.1 escaped identifiers are opaque too (they may contain '`').
        if (c == '\\') {
            const start = i;
            i += 1;
            while (i < text.len and !isSpace(text[i])) i += 1;
            if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[start..i]);
            continue;
        }

        if (c == '`') {
            i = try directive(pp, text, i);
            try pp.resync(i);
            continue;
        }

        // Ordinary text: everything up to the next byte the three branches
        // above care about is copied verbatim, in one `appendSlice`.
        //
        // The OUTER loop is a chain — where the next run starts depends on what
        // the last one ended at — but the INNER question, "where is the next
        // interesting byte", has no dependency between positions at all, and
        // that inner question is the whole of what `findStop` answers.
        //
        // '\n' is deliberately NOT interesting: in an emitting arm it is an
        // ordinary byte to be copied, and in a dead one `putNewlines` finds it
        // again with a vectorized count. '/' is not interesting either — this
        // text is post-`stripComments`, so no comment survives to be found.
        const end = findStop(text, i, scan_stops);
        if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[i..end]) else try pp.putNewlines(text[i..end]);
        // `text[i]` is none of the three, so `end > i`: the loop always moves.
        i = end;
    }
}

/// Handles one '`' at `at`. Returns the offset to resume from.
fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize {
    const name_start = at + 1;
    var j = name_start;

    // §2.8.1 escaped identifier: `\` then printable ASCII, ended by white
    // space, with neither the backslash nor the terminator part of the name.
    // Syntax 10-3 makes text_macro_identifier an `identifier` (A.9.3: simple
    // OR escaped), so a use may be spelled `` `\MY-GAIN ``. No compiler
    // directive is spelled with a backslash, so this can only be a macro use
    // and goes straight to `expand`.
    if (j < text.len and text[j] == '\\') {
        j += 1;
        const body = j;
        while (j < text.len and !isSpace(text[j]) and text[j] >= 33 and text[j] <= 126) j += 1;
        if (j == body) {
            if (!pp.emitting()) return at + 1;
            return pp.fail(pp.spanAt(at, at + 1), .E0103, "", .{});
        }
        return expand(pp, text, at, j, text[body..j]);
    }

    while (j < text.len and isIdentChar(text[j])) j += 1;
    if (j == name_start) {
        if (!pp.emitting()) return at + 1;
        return pp.fail(pp.spanAt(at, at + 1), .E0103, "", .{});
    }
    const name = text[name_start..j];

    const kind = directive_map.get(name) orelse return expand(pp, text, at, j, name);

    // Conditionals run even inside an inactive arm — they nest.
    switch (kind) {
        .ifdef, .ifndef, .elsif, .@"else", .endif => return conditional(pp, text, at, j, kind),
        else => {},
    }

    // Everything else is line-oriented and dies with the arm it sits in.
    const end = logicalLineEnd(text, j);
    if (!pp.emitting()) {
        try pp.putNewlines(text[at..end]);
        return end;
    }
    switch (kind) {
        .define => try handleDefine(pp, text[j..end], at, j),
        .undef => try removeDefine(pp, text[j..end], at, j),
        .include => try handleInclude(pp, text[j..end], at, j),
        .resetall => {
            var it = pp.macros.iterator();
            var dead: std.ArrayList([]const u8) = .empty;
            while (it.next()) |e| {
                if (!e.value_ptr.predefined) try dead.append(pp.arena, e.key_ptr.*);
            }
            for (dead.items) |k| _ = pp.macros.remove(k);
            // §10.2 opens its reset sentence with "In addition to `resetall",
            // which makes the global reset the second way to withdraw the
            // default discipline. An empty `discipline` is that withdrawal.
            try pp.defaults.append(pp.arena, .{
                .at = @intCast(pp.out.items.len),
                .qualifier = "",
                .discipline = "",
            });
            // IEEE 1364 §19.6: `resetall returns every directive to its default
            // value, and `timescale's default is "none specified" — which is
            // what §9.15 answers "not known" for.
            pp.timescale = null;
        },
        .default_discipline => try handleDefaultDiscipline(pp, text[j..end], j),
        .default_transition => try handleDefaultTransition(pp, text[j..end], j),
        .line => try handleLine(pp, text[j..end], at, j),
        .timescale => handleTimescale(pp, text[j..end]),
        .ignored => {},
        // §10.6: passed through instead of being blanked out, so the lexer and
        // parser see it. The slice carries its own newlines, so the
        // line-number contract in the file header holds unchanged.
        .keywords => {
            try pp.out.appendSlice(pp.arena, text[at..end]);
            return end;
        },
        else => unreachable,
    }
    try pp.putNewlines(text[at..end]);
    return end;
}

/// `ifdef / `ifndef / `elsif / `else / `endif. IEEE Std 1364 Verilog.
fn conditional(pp: *Pp, text: []const u8, at: usize, after_name: usize, kind: Directive) Error!usize {
    const end = logicalLineEnd(text, after_name);
    const rest = text[after_name..end];
    // The directive word itself: `ifdef, `else, ...
    const sp = pp.spanAt(at, after_name);

    switch (kind) {
        .ifdef, .ifndef => {
            var r: Rest = .{ .s = rest };
            // The operand is a text_macro_identifier (Syntax 10-3), and A.9.3
            // makes `identifier` simple OR escaped — the same pair of spellings
            // `handleDefine` accepts, so `` `ifdef \M-X `` tests the macro that
            // `` `define \M-X `` created.
            const macro = r.escapedIdent() orelse r.ident() orelse
                return pp.fail(sp, .E0104, "`{s}", .{@tagName(kind)});
            const parent = pp.emitting();
            const defined = pp.macros.contains(macro);
            const want = if (kind == .ifdef) defined else !defined;
            const active = parent and want;
            try pp.conds.append(pp.arena, .{
                .parent_active = parent,
                .active = active,
                .taken = active,
                .span = sp,
                .file = pp.cur_file_id,
            });
        },
        .elsif, .@"else" => {
            const n = pp.conds.items.len;
            if (n == 0) return pp.fail(sp, .E0105, "`{s}", .{@tagName(kind)});
            const top = &pp.conds.items[n - 1];
            if (top.seen_else) return pp.fail(sp, .E0106, "`{s}", .{@tagName(kind)});
            if (kind == .@"else") {
                top.seen_else = true;
                top.active = top.parent_active and !top.taken;
                top.taken = true;
            } else {
                var r: Rest = .{ .s = rest };
                // Same A.9.3 pair as `ifdef above: the name may be escaped.
                const macro = r.escapedIdent() orelse r.ident() orelse
                    return pp.fail(sp, .E0107, "", .{});
                top.active = top.parent_active and !top.taken and pp.macros.contains(macro);
                if (top.active) top.taken = true;
            }
        },
        .endif => {
            if (pp.conds.pop() == null) return pp.fail(sp, .E0108, "", .{});
        },
        else => unreachable,
    }
    try pp.putNewlines(text[at..end]);
    return end;
}

// ---------------------------------------------------------------------------
// §10.4 `define / `undef
// ---------------------------------------------------------------------------

/// `rest` is everything after the word "define" on one logical line; `at` is
/// the '`' and `off` the offset `rest` starts at.
fn handleDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3 writes two different nonterminals into adjacent lines:
    //   formal_argument_identifier ::= simple_identifier
    //   text_macro_identifier      ::= identifier
    // and A.9.3 makes `identifier` simple OR escaped. So the NAME may be
    // escaped and the formals may not — `escapedIdent` is used here and
    // `ident` stays in the formal loop below.
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), .E0109, "", .{});

    var m: Macro = .{ .body = "" };
    // The '(' of a formal argument list must touch the macro name (§10.4).
    if (r.peek() == '(') {
        r.i += 1;
        m.is_func = true;
        var params: std.ArrayList([]const u8) = .empty;
        while (true) {
            r.skipSpace();
            if (r.peek() == ')') {
                r.i += 1;
                break;
            }
            const p = r.ident() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0110, "`{s}`", .{name});
            try params.append(pp.arena, p);
            r.skipSpace();
            const c = r.peek() orelse
                return pp.fail(pp.spanAt(off + r.i, off + r.i), .E0111, "`{s}`", .{name});
            if (c == ',') {
                r.i += 1;
                continue;
            }
            if (c == ')') {
                r.i += 1;
                break;
            }
            return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0112, "`{s}`", .{name});
        }
        m.params = params.items;
    }
    r.skipSpace();
    m.body = try joinContinuations(pp, std.mem.trimEnd(u8, r.s[r.i..], " \t\r"));

    // §10.4: "To avoid conflicts with predefined Verilog-AMS macros (10.5), the
    // `define compiler directive's macro text shall not begin with __VAMS_."
    // The target is the TEXT (Syntax 10-3's second operand), not the name — a
    // body is what can expand into a §10.5 predefined macro and shadow it.
    if (std.mem.startsWith(u8, m.body, "__VAMS_"))
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0139, "`{s}` begins with __VAMS_", .{m.body});

    // §10.4: a redefinition silently replaces. Predefined macros keep their flag
    // so `resetall does not drop them.
    if (pp.macros.get(name)) |old| m.predefined = old.predefined;
    try pp.macros.put(pp.arena, name, m);
}

fn removeDefine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Syntax 10-3: `undef's operand is a text_macro_identifier ::= identifier,
    // simple OR escaped (A.9.3) — a name `` `define \M-X `` could create is a
    // name `` `undef \M-X `` must be able to withdraw.
    const name = r.escapedIdent() orelse r.ident() orelse
        return pp.fail(pp.spanAt(at, off), .E0113, "", .{});
    // §10.4: "`undef shall have no effect on predefined Verilog-AMS macros".
    if (pp.macros.get(name)) |m| {
        if (m.predefined) return;
    }
    _ = pp.macros.remove(name);
}

/// A macro body is one logical line: `\`+newline collapses to a space. The
/// newlines it swallowed are re-emitted by the caller, so lines still line up.
fn joinContinuations(pp: *Pp, body: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, body, '\n') == null) return body;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, body.len);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            var k = i + 1;
            while (k < body.len and (body[k] == ' ' or body[k] == '\t' or body[k] == '\r')) k += 1;
            if (k < body.len and body[k] == '\n') {
                // One separating space, unless the text already ends in one.
                if (out.items.len != 0 and out.items[out.items.len - 1] != ' ')
                    out.appendAssumeCapacity(' ');
                i = k;
                // Also eat the indentation of the continuation line.
                while (i + 1 < body.len and (body[i + 1] == ' ' or body[i + 1] == '\t')) i += 1;
                continue;
            }
        }
        if (body[i] == '\n' or body[i] == '\r') continue;
        out.appendAssumeCapacity(body[i]);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// §10.4 macro expansion
// ---------------------------------------------------------------------------

/// `at` points at '`', `after_name` past the macro name. Returns resume offset.
fn expand(pp: *Pp, text: []const u8, at: usize, after_name: usize, name: []const u8) Error!usize {
    if (!pp.emitting()) return after_name;
    // The whole use, backtick included: `FOO.
    const sp = pp.spanAt(at, after_name);

    const m = pp.macros.get(name) orelse {
        // §10.7. Not in `macros` because neither has a fixed body: both are
        // computed from where the use SITS, so they are expanded here, at the
        // one point that still knows the file and the offset. A user `define
        // of either name is found by the lookup above and wins, which costs
        // nothing to allow and is the only reading §10.4 leaves open.
        if (std.mem.eql(u8, name, "__LINE__")) {
            // "in the form of a simple decimal number" — an integer token, not
            // a string, so it is usable as `ln = `__LINE__;`.
            var buf: [16]u8 = undefined;
            try pp.out.appendSlice(pp.arena, std.fmt.bufPrint(&buf, "{d}", .{pp.currentLine(at)}) catch unreachable);
            return after_name;
        }
        if (std.mem.eql(u8, name, "__FILE__")) {
            // "in the form of a string literal" — §2.7, so the quotes are part
            // of the expansion and a '"' or '\' in the path has to be escaped
            // or the literal ends early (Windows paths are full of the latter).
            try pp.out.appendSlice(pp.arena, "\"");
            // §10.7 `__FILE__`: "the name of the current input file". The clause makes
            // the spelling "implementation dependent" and says a `line directive may
            // replace it, so the override wins when there is one.
            for (pp.file_override orelse pp.opts.bag.fileName(pp.cur_file_id)) |c| {
                if (c == '"' or c == '\\') try pp.out.appendSlice(pp.arena, "\\");
                try pp.out.append(pp.arena, c);
            }
            try pp.out.appendSlice(pp.arena, "\"");
            return after_name;
        }
        var b = pp.failWith(sp, .E0115);
        b.msg("`{s}", .{name});
        if (diag.didYouMeanMap(name, pp.macros)) |near| {
            // `sp` spans the whole use INCLUDING the backtick, so the rewrite
            // has to put one back — `suggestHere` would eat it.
            const repl = try std.fmt.allocPrint(pp.arena, "`{s}", .{near});
            b.suggest(.{ .span = sp, .replacement = repl }, "did you mean `{s}`?", .{near});
        }
        try b.emit();
        return error.PreprocessFailed;
    };

    var end = after_name;
    var args: []const []const u8 = &.{};
    if (m.is_func) {
        var k = after_name;
        while (k < text.len and isSpace(text[k])) k += 1;
        if (k >= text.len or text[k] != '(')
            return pp.fail(sp, .E0116, "`{s}` takes {d} argument(s)", .{ name, m.params.len });
        const parsed = try macroArgs(pp, text, k, at, name);
        args = parsed.args;
        end = parsed.end;
        // `M()` on a zero-parameter macro is an empty list, not one empty arg.
        if (m.params.len == 0 and args.len == 1 and args[0].len == 0) args = &.{};
        if (args.len != m.params.len)
            return pp.fail(sp, .E0117, "expected {d}, found {d}", .{ m.params.len, args.len });
    }

    for (pp.expanding.items) |active| {
        if (!std.mem.eql(u8, active, name)) continue;
        var b = pp.failWith(sp, .E0118);
        b.msg("`{s}`", .{name});
        b.note("expansion chain: {s}", .{try pp.joinChain(pp.expanding.items, name)});
        try b.emit();
        return error.PreprocessFailed;
    }
    if (pp.expand_depth >= max_expansion_depth)
        return pp.fail(sp, .E0119, "limit is {d}", .{max_expansion_depth});
    pp.expand_depth += 1;
    defer pp.expand_depth -= 1;

    // §10.4 defers text-macro semantics to IEEE Std 1364, whose rule is that a
    // macro's TEXT may not refer to the macro itself, directly or indirectly —
    // a property of the DEFINITION. A nested invocation in an ACTUAL argument
    // (`` `MAX(`MAX(a,b),c) ``) is not that: the C-preprocessor model, which
    // 1364's macro system transcribes, expands each argument FULLY before it is
    // substituted into the body. Splicing the RAW argument text and rescanning
    // it while `name` sits on `pp.expanding` turned every such use into a false
    // E0118. Pre-expansion happens here, BEFORE the name is pushed, so the
    // argument's own uses see the caller's stack — while a self-reference in
    // the BODY is still rescanned with the name on the stack and still E0118s.
    const body = if (m.is_func) blk: {
        var actuals = args;
        for (args, 0..) |a, first| {
            if (std.mem.indexOfScalar(u8, a, '`') == null) continue;
            // At least one argument invokes a macro: expand them all into a
            // copy. Backtick-free arguments (the overwhelming case) take the
            // branch above and are substituted verbatim, byte-identically to
            // what the splice-and-rescan model produced.
            const copy = try pp.arena.dupe([]const u8, args);
            for (copy[first..]) |*slot| slot.* = try expandArg(pp, slot.*, at);
            actuals = copy;
            break;
        }
        break :blk try substitute(pp, m.body, m.params, actuals);
    } else m.body;

    try pp.expanding.append(pp.arena, name);
    defer _ = pp.expanding.pop();

    // Provenance: the bytes about to be emitted came from a macro body, not
    // from the file. Only the OUTERMOST expansion is recorded — a nested one
    // resolves to the same invocation site anyway, so the extra segments would
    // buy nothing.
    const outermost = pp.expand_site == null;
    if (outermost) {
        const o: u32 = @intCast(pp.out.items.len);
        const site: u32 = @intCast(at);
        const inv: u32 = @intCast(pp.segs.items.len);
        // A zero-width verbatim segment pinning the invocation site, so
        // `resolve` walking out of the macro lands on the use, not on
        // wherever the enclosing segment happened to start.
        try pp.segs.append(pp.arena, .{ .out_start = o, .in_start = site, .file = pp.cur_file_id, .kind = .verbatim });
        try pp.segs.append(pp.arena, .{
            .out_start = o,
            .in_start = site,
            .file = pp.cur_file_id,
            .kind = .macro,
            .parent = inv,
            .macro = name,
        });
        pp.expand_site = site;
    }
    defer if (outermost) {
        pp.expand_site = null;
    };

    // Rescan the expansion so nested macro uses (§10.4) expand too. The cycle
    // guard above is what makes this terminate.
    try scan(pp, body);

    // The invocation may have spanned lines; keep the count.
    try pp.putNewlines(text[at..end]);
    // `scan` resyncs the map to `end` when this returns.
    return end;
}

/// Fully macro-expand one collected actual argument (§10.4 via IEEE 1364 —
/// arguments are expanded BEFORE substitution, see the comment in `expand`).
/// Runs `scan` with the output redirected into a fresh arena list; `at` is the
/// invocation's '`', which becomes `expand_site` so that diagnostics raised
/// inside the argument, `__LINE__`, and the no-segment rule all behave exactly
/// as they do for a body rescan. Backtick-free text expands to itself and is
/// returned unscanned.
fn expandArg(pp: *Pp, arg: []const u8, at: usize) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '`') == null) return arg;
    const saved_out = pp.out;
    const saved_site = pp.expand_site;
    pp.out = .empty;
    if (pp.expand_site == null) pp.expand_site = @intCast(at);
    defer {
        pp.out = saved_out;
        pp.expand_site = saved_site;
    }
    try scan(pp, arg);
    return pp.out.items;
}

const MacroArgs = struct { args: []const []const u8, end: usize };

/// Splits a top-level comma list starting at the '(' at `lparen`. Nested
/// (), [], {} and string literals are opaque.
///
/// The nesting is a STACK of opener kinds, not one shared counter: with a
/// counter every one of `)]}` could close the argument list, so `` `ID(2.0] ``
/// compiled clean and crossed nestings like `[(],)` mis-sliced the arguments.
/// A closer that does not match its opener is E0120 — the `(` it leaves behind
/// really is unterminated, and saying so at the mismatch is the honest place.
fn macroArgs(pp: *Pp, text: []const u8, lparen: usize, at: usize, name: []const u8) Error!MacroArgs {
    var args: std.ArrayList([]const u8) = .empty;
    var opens: std.ArrayList(u8) = .empty;
    var i = lparen;
    var arg_start = lparen + 1;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => i = stringStop(text, i),
            '(', '[', '{' => try opens.append(pp.arena, c),
            ')', ']', '}' => {
                // Non-empty: the first iteration pushes the '(' at `lparen`,
                // and the list returns the moment the stack empties.
                const open = opens.pop().?;
                const want: u8 = switch (open) {
                    '(' => ')',
                    '[' => ']',
                    else => '}',
                };
                if (c != want) {
                    var b = pp.failWith(pp.spanAt(i, i + 1), .E0120);
                    b.msg("`{s}`: `{c}` cannot close `{c}`", .{ name, c, open });
                    try b.emit();
                    return error.PreprocessFailed;
                }
                if (opens.items.len == 0) {
                    try args.append(pp.arena, std.mem.trim(u8, text[arg_start..i], " \t\r\n"));
                    return .{ .args = args.items, .end = i + 1 };
                }
            },
            ',' => if (opens.items.len == 1) {
                try args.append(pp.arena, std.mem.trim(u8, text[arg_start..i], " \t\r\n"));
                arg_start = i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return pp.fail(pp.spanAt(at, at + 1 + name.len), .E0120, "`{s}`", .{name});
}

/// Replace whole-identifier occurrences of the formals in `body`. String
/// literals are left alone, and the identifier right after a '`' is a macro
/// name, never a formal.
fn substitute(pp: *Pp, body: []const u8, params: []const []const u8, args: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, body.len);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '"') {
            const start = i;
            i += 1;
            while (i < body.len and body[i] != '"') {
                if (body[i] == '\\' and i + 1 < body.len) i += 1;
                i += 1;
            }
            if (i < body.len) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '`') {
            const start = i;
            i += 1;
            while (i < body.len and isIdentChar(body[i])) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier: opaque up to the next white space,
            // exactly as `scan` and `stripComments` treat it. A formal spelled
            // INSIDE one is part of that identifier, not a use of the formal —
            // `` `define M(x) real \sig-x ; `` declares `\sig-x`, not `\sig-1`.
            const start = i;
            i += 1;
            while (i < body.len and !isSpace(body[i])) i += 1;
            try out.appendSlice(pp.arena, body[start..i]);
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < body.len and isIdentChar(body[i])) i += 1;
            const word = body[start..i];
            const idx = indexOfString(params, word);
            try out.appendSlice(pp.arena, if (idx) |k| args[k] else word);
            continue;
        }
        try out.append(pp.arena, c);
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// `include
// ---------------------------------------------------------------------------

fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    // The directive word, for the errors that have nothing better to point at.
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, .E0121, "", .{});
    const close: u8 = switch (open) {
        '"' => '"',
        '<' => '>',
        else => return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0122, "found `{c}`", .{open}),
    };
    r.i += 1;
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] != close) r.i += 1;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + start - 1, off + r.i), .E0123, "", .{});
    const path = r.s[start..r.i];
    if (path.len == 0) return pp.fail(pp.spanAt(off + start - 1, off + r.i + 1), .E0124, "", .{});
    // The file name itself, quotes excluded.
    const name_span = pp.spanAt(off + start, off + r.i);

    if (pp.includes.items.len >= max_include_depth) {
        var b = pp.failWith(name_span, .E0125);
        b.msg("limit is {d}", .{max_include_depth});
        b.note("include chain: {s}", .{try pp.joinChain(pp.includes.items, path)});
        try b.emit();
        return error.PreprocessFailed;
    }

    const text = (try readInclude(pp, path)) orelse {
        var b = pp.failWith(name_span, .E0126);
        b.msg("\"{s}\"", .{path});
        if (pp.opts.include_dirs.len == 0) {
            b.note("no include directories were configured; only the built-in annex D headers ({s}) are resolvable", .{"constants.vams, disciplines.vams"});
        } else {
            b.note("searched: {s}", .{try std.mem.join(pp.arena, ", ", pp.opts.include_dirs)});
        }
        try b.emit();
        return error.PreprocessFailed;
    };

    try pp.includes.append(pp.arena, path);
    defer _ = pp.includes.pop();
    try pp.runFile(text, path, null);
    // `scan` resyncs the map back to the parent file when `directive` returns.
}

/// Search order: caller include dirs (in order), then the built-in annex D
/// files by basename. Returns null if nothing matched.
fn readInclude(pp: *Pp, path: []const u8) Error!?[]const u8 {
    if (pp.opts.include_dirs.len != 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir: std.Io.Dir = .cwd();
        for (pp.opts.include_dirs) |base| {
            const full = try std.fs.path.join(pp.arena, &.{ base, path });
            if (dir.readFileAlloc(io, full, pp.arena, .limited(max_include_bytes))) |bytes| {
                return bytes;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {}, // try the next dir
            }
        }
    }
    return builtin_includes.get(std.fs.path.basename(path));
}

// ---------------------------------------------------------------------------
// §10.2 `default_discipline, IEEE 1364 §19.7 `line
// ---------------------------------------------------------------------------

/// §10.2 Syntax 10-1. `rest` is everything after the word on one logical line;
/// `off` is the offset `rest` starts at.
///
/// Nothing is applied here — the directive's effect is §7.4 discipline
/// resolution, which needs the module's declarations and so cannot run in a
/// text stage. What this does is PARSE it (a wrong qualifier is a syntax error
/// the front end owes the user, and it is exactly the typo the closed list
/// exists to catch, two adjacent identifiers being easy to duplicate) and
/// record the event with the output offset it takes effect from.
fn handleDefaultDiscipline(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Both operands are optional; the bare form WITHDRAWS the default. The
    // discipline_identifier is an A.9.3 `identifier`, simple OR escaped —
    // annex D.1 itself declares `discipline \logic ;`, so the escaped spelling
    // is the only way to name that one here. The qualifier stays `ident()`:
    // Syntax 10-1 closes it over fifteen KEYWORDS, and §2.8.2 makes an escaped
    // identifier never a keyword.
    const disc = r.escapedIdent() orelse r.ident() orelse "";
    const qual = if (disc.len == 0) "" else r.ident() orelse "";
    if (qual.len != 0 and !qualifiers.has(qual)) {
        var b = pp.failWith(pp.spanAt(off + r.i - qual.len, off + r.i), .E0127);
        b.msg("`{s}` is not a qualifier", .{qual});
        b.note("Syntax 10-1 allows one of: {s}", .{"integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1"});
        try b.emit();
        return error.PreprocessFailed;
    }
    // Anything after the qualifier is not in Syntax 10-1 either. Reported with
    // the same code so the rule reads as one rule.
    r.skipSpace();
    if (r.i < r.s.len and std.mem.trim(u8, r.s[r.i..], " \t\r").len != 0) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0127);
        b.msg("`{s}` follows the qualifier", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("Syntax 10-1 is `default_discipline [ discipline_identifier [ qualifier ] ], and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.defaults.append(pp.arena, .{
        .at = @intCast(pp.out.items.len),
        .qualifier = qual,
        .discipline = disc,
    });
}

/// §10.3 Syntax 10-2:
///
///   default_transition_directive ::= `default_transition transition_time
///   transition_time ::= constant_expression
///
/// No brackets round the operand, so it is MANDATORY — see E0129 for why the
/// bare form is a diagnostic rather than a request for the simulator default.
///
/// `constant_expression` in full is a parser's job and this is a text stage, so
/// what is read here is one §2.6 number, scale factor included: `4n`, `4e-9`,
/// `0.000000004`. That is every `default_transition anyone writes, and the
/// alternative — deferring the directive to the parser the way §10.6
/// `begin_keywords is deferred — buys an expression grammar for an operand the
/// LRM only ever illustrates as a literal.
/// ponytail: upgrade path is emitting the directive verbatim and letting the
/// parser fold it, the day a model writes `default_transition tr*2.
fn handleDefaultTransition(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and !isSpace(r.s[r.i])) r.i += 1;
    const text = r.s[start..r.i];
    if (text.len == 0) {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0129);
        b.msg("`default_transition needs a transition time and this one has none", .{});
        b.note("Syntax 10-2 is `default_transition transition_time, and the operand is not optional", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    const t = Lexer.parseReal(text) catch {
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "`{s}` is not a transition time", .{text});
    };
    // §4.5.8 gives the value straight to rise_time and fall_time, and both are
    // times: a negative one describes an edge that finishes before it starts.
    // (E0516 says the same of a rise_time written at the call.)
    if (!(t >= 0.0) or !std.math.isFinite(t)) {
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "a transition time cannot be `{s}`", .{text});
    }
    r.skipSpace();
    if (r.i < r.s.len and std.mem.trim(u8, r.s[r.i..], " \t\r").len != 0) {
        var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), .E0129);
        b.msg("`{s}` follows the transition time", .{std.mem.trim(u8, r.s[r.i..], " \t\r")});
        b.note("Syntax 10-2 is `default_transition transition_time, and nothing more", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.transitions.append(pp.arena, .{ .at = @intCast(pp.out.items.len), .time = t });
}

/// IEEE Std 1364 §19.9 `` `timescale <unit> / <precision> ``.
///
/// Both operands are on Table 19-1's closed grid — a magnitude of 1, 10 or 100
/// and one of six unit names — so a hand-written table of six exponents is the
/// whole conversion, and nothing here has to parse a general real.
//
// ponytail: a malformed operand leaves the timescale UNSET rather than raising
// a diagnostic, so `$simparam("timeUnit")` on it reports §9.15's "not known"
// (E0811) instead of a number nobody wrote. IEEE 1364 makes the malformed form
// an error in its own right; no fixture demands it, and the E0811 route already
// refuses to invent a value. Add a class-1 code here when one does.
fn handleTimescale(pp: *Pp, rest: []const u8) void {
    var r: Rest = .{ .s = rest };
    const unit = timeLiteral(&r) orelse return;
    r.skipSpace();
    if (r.peek() != '/') return;
    r.i += 1;
    const precision = timeLiteral(&r) orelse return;
    // "The time precision shall be at least as precise as the time unit"
    // (§19.9). A card that has them backwards is not a timescale.
    if (precision > unit) return;
    pp.timescale = .{ .unit = unit, .precision = precision };
}

/// One IEEE 1364 Table 19-1 time literal — `1`, `10` or `100` glued to one of
/// `s ms us ns ps fs` — as a count of SECONDS, which is the unit §9.15
/// Table 9-27 asks for. Null (cursor undefined) on anything else.
fn timeLiteral(r: *Rest) ?f64 {
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    const mag: i8 = if (std.mem.eql(u8, r.s[start..r.i], "1"))
        0
    else if (std.mem.eql(u8, r.s[start..r.i], "10"))
        1
    else if (std.mem.eql(u8, r.s[start..r.i], "100")) 2 else return null;
    const unit = r.ident() orelse return null;
    const units = std.StaticStringMap(i8).initComptime(.{
        .{ "s", 0 },   .{ "ms", -3 },  .{ "us", -6 },
        .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 },
    });
    // Composed as ONE decimal literal and not as magnitude × unit: 100 * 1e-6
    // is 9.999999999999999e-5, and a §9.15 reader comparing against the 1e-4
    // it wrote would be one ulp out for a reason that is arithmetic, not
    // timekeeping. The grid is 18 wide, so the table IS the multiplication.
    const decades = [_]f64{
        1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7,
        1e-6,  1e-5,  1e-4,  1e-3,  1e-2,  1e-1,  1e0,  1e1,  1e2,
    };
    return decades[@intCast(mag + (units.get(unit) orelse return null) + 15)];
}

/// IEEE Std 1364 §19.7 `line <number> ["<file>"] [<level>], which §10.7 names
/// as the way `__LINE__` (and possibly `__FILE__`) is remapped. The operand is
/// the number of the line FOLLOWING the directive.
///
/// The level is accepted and dropped: it says whether the remap enters, leaves
/// or stays in a file, which only matters to a tool that reconstructs an
/// include stack out of `line directives. VerA has the real one.
fn handleLine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    if (r.i == start)
        return pp.fail(pp.spanAt(off, off + r.s.len), .E0128, "", .{});
    const n = std.fmt.parseInt(u32, r.s[start..r.i], 10) catch
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0128, "`{s}` does not fit a line number", .{r.s[start..r.i]});

    r.skipSpace();
    if (r.peek() == '"') {
        const q = r.i + 1;
        r.i = q;
        while (r.i < r.s.len and r.s[r.i] != '"') r.i += 1;
        if (r.i >= r.s.len)
            return pp.fail(pp.spanAt(off + q - 1, off + r.i), .E0128, "unterminated file name", .{});
        pp.file_override = r.s[q..r.i];
    }

    pp.line_from = pp.physicalLine(at) + 1;
    pp.line_to = n;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Stop on a closing quote, an unescaped newline, or EOF; `start` is the opener.
// ponytail: share the three identical scans. The lexer rejects escaped newlines
// and `substitute` crosses bare ones; reuse either only if those rules converge.
fn stringStop(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len and text[i] != '"' and text[i] != '\n') {
        if (text[i] == '\\' and i + 1 < text.len) i += 1;
        i += 1;
    }
    return i;
}

/// Cursor over the tail of a directive line.
const Rest = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(r: *const Rest) ?u8 {
        return if (r.i < r.s.len) r.s[r.i] else null;
    }
    fn skipSpace(r: *Rest) void {
        while (r.i < r.s.len and isSpace(r.s[r.i])) r.i += 1;
    }
    /// Next §2.8.1 escaped identifier, skipping leading whitespace. Neither
    /// the backslash nor the terminating white space is part of the name, so
    /// the macro is keyed on the same bytes a `` `\name `` use produces.
    fn escapedIdent(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or r.s[r.i] != '\\') return null;
        const start = r.i + 1;
        var k = start;
        while (k < r.s.len and !isSpace(r.s[k]) and r.s[k] >= 33 and r.s[k] <= 126) k += 1;
        if (k == start) return null;
        r.i = k;
        return r.s[start..k];
    }
    /// Next identifier (§2.8), skipping leading whitespace.
    fn ident(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or !isIdentStart(r.s[r.i])) return null;
        const start = r.i;
        while (r.i < r.s.len and isIdentChar(r.s[r.i])) r.i += 1;
        return r.s[start..r.i];
    }
};

/// End of the logical line at `i`: the next unescaped newline, or EOF.
/// A `\` before a newline continues the line (§10.4 multi-line macro text).
fn logicalLineEnd(text: []const u8, i: usize) usize {
    var k = i;
    while (k < text.len) {
        if (text[k] == '\\') {
            var n = k + 1;
            while (n < text.len and (text[n] == ' ' or text[n] == '\t' or text[n] == '\r')) n += 1;
            if (n < text.len and text[n] == '\n') {
                k = n + 1;
                continue;
            }
        } else if (text[k] == '\n') return k;
        k += 1;
    }
    return text.len;
}

fn indexOfString(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |s, k| {
        if (std.mem.eql(u8, s, needle)) return k;
    }
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c;
}
fn isIdentStart(c: u8) bool {
    // ponytail: stdlib ASCII classes; `_` and `$` are Verilog's extensions.
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// ---------------------------------------------------------------------------
// Annex D standard definitions (transcribed verbatim from docs/annex-d-stddefs.html)
// ---------------------------------------------------------------------------

/// annex D.2 — constants.vams. Mathematical and physical constants (§10.5).
/// Self-guarded, so `include "constants.vams" after the prelude is a no-op.
pub const constants_vams =
    \\// Copyright(c) 2009-2023 Accellera Systems Initiative Inc.
    \\// Verbatim copies of constants.vams may be used and distributed without
    \\// restriction. VAMS-2023.
    \\`ifdef CONSTANTS_VAMS
    \\`else
    \\`define CONSTANTS_VAMS 1
    \\// M_ is a mathematical constant
    \\`define   M_E               2.7182818284590452354
    \\`define   M_LOG2E           1.4426950408889634074
    \\`define   M_LOG10E          0.43429448190325182765
    \\`define   M_LN2             0.69314718055994530942
    \\`define   M_LN10            2.30258509299404568402
    \\`define   M_PI              3.14159265358979323846
    \\`define   M_TWO_PI          6.28318530717958647693
    \\`define   M_PI_2            1.57079632679489661923
    \\`define   M_PI_4            0.78539816339744830962
    \\`define   M_1_PI            0.31830988618379067154
    \\`define   M_2_PI            0.63661977236758134308
    \\`define   M_2_SQRTPI        1.12837916709551257390
    \\`define   M_SQRT2           1.41421356237309504880
    \\`define   M_SQRT1_2         0.70710678118654752440
    \\
    \\// P_ is a physical constant (https://physics.nist.gov/cuu/Constants)
    \\// charge of electron in Coulombs
    \\`define   P_Q_SPICE         1.60219e-19
    \\`define   P_Q_OLD           1.6021918e-19
    \\`define   P_Q_NIST1998      1.602176462e-19
    \\`define   P_Q_NIST2010      1.602176565e-19
    \\`define   P_Q_NIST2018      1.602176634e-19
    \\// speed of light in vacuum in meters/second
    \\`define   P_C               2.99792458e8
    \\// Boltzmann's constant in Joules/Kelvin
    \\`define   P_K_SPICE         1.38062e-23
    \\`define   P_K_OLD           1.3806226e-23
    \\`define   P_K_NIST1998      1.3806503e-23
    \\`define   P_K_NIST2010      1.3806488e-23
    \\`define   P_K_NIST2018      1.380649e-23
    \\// Planck's constant in Joules*second
    \\`define   P_H_SPICE         6.62620e-34
    \\`define   P_H_OLD           6.6260755e-34
    \\`define   P_H_NIST1998      6.62606876e-34
    \\`define   P_H_NIST2010      6.62606957e-34
    \\`define   P_H_NIST2018      6.62607015e-34
    \\// permittivity of vacuum in Farads/meter
    \\`define   P_EPS0_SPICE      8.854214871e-12
    \\`define   P_EPS0_OLD        8.85418792394420013968e-12
    \\`define   P_EPS0_NIST1998   8.854187817e-12
    \\`define   P_EPS0_NIST2010   8.854187817e-12
    \\`define   P_EPS0_NIST2018   8.8541878128e-12
    \\// permeability of vacuum in Henrys/meter
    \\`define   P_U0_OLD          (4.0e-7 * `M_PI)
    \\`define   P_U0_NIST2018     1.25663706212e-6
    \\// zero Celsius in Kelvin
    \\`define   P_CELSIUS0        273.15
    \\
    \\`ifdef PHYSICAL_CONSTANTS_NIST2018
    \\`define P_Q `P_Q_NIST2018
    \\`define P_K `P_K_NIST2018
    \\`define P_H `P_H_NIST2018
    \\`define P_EPS0 `P_EPS0_NIST2018
    \\`define P_U0 `P_U0_NIST2018
    \\`else
    \\`define P_U0 `P_U0_OLD
    \\`ifdef PHYSICAL_CONSTANTS_SPICE
    \\// from UC Berkeley SPICE 3F5
    \\`define P_Q `P_Q_SPICE
    \\`define P_K `P_K_SPICE
    \\`define P_H `P_H_SPICE
    \\`define P_EPS0 `P_EPS0_SPICE
    \\`else
    \\`ifdef PHYSICAL_CONSTANTS_OLD
    \\// from Verilog-A LRM 1.0 and Verilog-AMS LRM 2.0
    \\`define P_Q `P_Q_OLD
    \\`define P_K `P_K_OLD
    \\`define P_H `P_H_OLD
    \\`define P_EPS0 `P_EPS0_OLD
    \\`else
    \\`ifdef PHYSICAL_CONSTANTS_NIST2010
    \\`define P_Q `P_Q_NIST2010
    \\`define P_K `P_K_NIST2010
    \\`define P_H `P_H_NIST2010
    \\`define P_EPS0 `P_EPS0_NIST2010
    \\`else
    \\// use NIST1998 values as in LRM 2.2 - 2.3 for backwards-compatibility
    \\`define P_Q `P_Q_NIST1998
    \\`define P_K `P_K_NIST1998
    \\`define P_H `P_H_NIST1998
    \\`define P_EPS0 `P_EPS0_NIST1998
    \\`endif
    \\`endif
    \\`endif
    \\`endif
    \\`endif
;

/// annex D.1 — disciplines.vams. Natures and disciplines, so class 3 resolves
/// real disciplines instead of assuming `electrical`. Self-guarded.
/// Default abstols are overridable by `define-ing <NATURE>_ABSTOL first.
pub const disciplines_vams =
    \\// Copyright(c) 2009-2023 Accellera Systems Initiative Inc.
    \\// Verbatim copies of disciplines.vams may be used and distributed without
    \\// restriction. VAMS-2023.
    \\`ifdef DISCIPLINES_VAMS
    \\`else
    \\`define DISCIPLINES_VAMS 1
    \\
    \\discipline \logic ;
    \\   domain discrete;
    \\enddiscipline
    \\
    \\discipline ddiscrete;
    \\   domain discrete;
    \\enddiscipline
    \\
    \\// Electrical
    \\
    \\// Current in amperes
    \\nature Current;
    \\   units       = "A";
    \\   access      = I;
    \\   idt_nature  = Charge;
    \\`ifdef CURRENT_ABSTOL
    \\   abstol      = `CURRENT_ABSTOL;
    \\`else
    \\   abstol      = 1e-12;
    \\`endif
    \\endnature
    \\
    \\// Charge in coulombs
    \\nature Charge;
    \\   units      = "coul";
    \\   access     = Q;
    \\   ddt_nature = Current;
    \\`ifdef CHARGE_ABSTOL
    \\   abstol     = `CHARGE_ABSTOL;
    \\`else
    \\   abstol     = 1e-14;
    \\`endif
    \\endnature
    \\
    \\// Potential in volts
    \\nature Voltage;
    \\   units      = "V";
    \\   access     = V;
    \\   idt_nature = Flux;
    \\`ifdef VOLTAGE_ABSTOL
    \\   abstol     = `VOLTAGE_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Flux in Webers
    \\nature Flux;
    \\   units      = "Wb";
    \\   access     = Phi;
    \\   ddt_nature = Voltage;
    \\`ifdef FLUX_ABSTOL
    \\   abstol     = `FLUX_ABSTOL;
    \\`else
    \\   abstol     = 1e-9;
    \\`endif
    \\endnature
    \\
    \\// Conservative discipline
    \\discipline electrical;
    \\   potential    Voltage;
    \\   flow         Current;
    \\enddiscipline
    \\
    \\// Signal flow disciplines
    \\discipline voltage;
    \\   potential    Voltage;
    \\enddiscipline
    \\
    \\discipline current;
    \\   flow    Current;
    \\enddiscipline
    \\
    \\// Magnetic
    \\
    \\// Magnetomotive force in Ampere-Turns.
    \\nature Magneto_Motive_Force;
    \\   units      = "A*turn";
    \\   access     = MMF;
    \\`ifdef MAGNETO_MOTIVE_FORCE_ABSTOL
    \\   abstol     = `MAGNETO_MOTIVE_FORCE_ABSTOL;
    \\`else
    \\   abstol     = 1e-12;
    \\`endif
    \\endnature
    \\
    \\// Conservative discipline
    \\discipline magnetic;
    \\   potential    Magneto_Motive_Force;
    \\   flow         Flux;
    \\enddiscipline
    \\
    \\// Thermal
    \\
    \\// Temperature in Kelvin
    \\nature Temperature;
    \\   units      = "K";
    \\   access     = Temp;
    \\`ifdef TEMPERATURE_ABSTOL
    \\   abstol     = `TEMPERATURE_ABSTOL;
    \\`else
    \\   abstol     = 1e-4;
    \\`endif
    \\endnature
    \\
    \\// Power in Watts
    \\nature Power;
    \\   units      = "W";
    \\   access     = Pwr;
    \\`ifdef POWER_ABSTOL
    \\   abstol     = `POWER_ABSTOL;
    \\`else
    \\   abstol     = 1e-9;
    \\`endif
    \\endnature
    \\
    \\// Conservative discipline
    \\discipline thermal;
    \\   potential    Temperature;
    \\   flow         Power;
    \\enddiscipline
    \\
    \\// Kinematic
    \\
    \\// Position in meters
    \\nature Position;
    \\   units      = "m";
    \\   access     = Pos;
    \\   ddt_nature = Velocity;
    \\`ifdef POSITION_ABSTOL
    \\   abstol     = `POSITION_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Velocity in meters per second
    \\nature Velocity;
    \\   units      = "m/s";
    \\   access     = Vel;
    \\   ddt_nature = Acceleration;
    \\   idt_nature = Position;
    \\`ifdef VELOCITY_ABSTOL
    \\   abstol     = `VELOCITY_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Acceleration in meters per second squared
    \\nature Acceleration;
    \\   units      = "m/s^2";
    \\   access     = Acc;
    \\   ddt_nature = Impulse;
    \\   idt_nature = Velocity;
    \\`ifdef ACCELERATION_ABSTOL
    \\   abstol     = `ACCELERATION_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Impulse in meters per second cubed
    \\nature Impulse;
    \\   units      = "m/s^3";
    \\   access     = Imp;
    \\   idt_nature = Acceleration;
    \\`ifdef IMPULSE_ABSTOL
    \\   abstol     = `IMPULSE_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Force in Newtons
    \\nature Force;
    \\   units      = "N";
    \\   access     = F;
    \\`ifdef FORCE_ABSTOL
    \\   abstol     = `FORCE_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Conservative disciplines
    \\discipline kinematic;
    \\   potential    Position;
    \\   flow         Force;
    \\enddiscipline
    \\
    \\discipline kinematic_v;
    \\   potential    Velocity;
    \\   flow         Force;
    \\enddiscipline
    \\
    \\// Rotational
    \\
    \\// Angle in radians
    \\nature Angle;
    \\   units      = "rads";
    \\   access     = Theta;
    \\   ddt_nature = Angular_Velocity;
    \\`ifdef ANGLE_ABSTOL
    \\   abstol     = `ANGLE_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Angular Velocity in radians per second
    \\nature Angular_Velocity;
    \\   units      = "rads/s";
    \\   access     = Omega;
    \\   ddt_nature = Angular_Acceleration;
    \\   idt_nature = Angle;
    \\`ifdef ANGULAR_VELOCITY_ABSTOL
    \\   abstol     = `ANGULAR_VELOCITY_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Angular acceleration in radians per second squared
    \\nature Angular_Acceleration;
    \\   units      = "rads/s^2";
    \\   access     = Alpha;
    \\   idt_nature = Angular_Velocity;
    \\`ifdef ANGULAR_ACCELERATION_ABSTOL
    \\   abstol     = `ANGULAR_ACCELERATION_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Torque in Newtons
    \\nature Angular_Force;
    \\   units      = "N*m";
    \\   access     = Tau;
    \\`ifdef ANGULAR_FORCE_ABSTOL
    \\   abstol     = `ANGULAR_FORCE_ABSTOL;
    \\`else
    \\   abstol     = 1e-6;
    \\`endif
    \\endnature
    \\
    \\// Conservative disciplines
    \\discipline rotational;
    \\   potential    Angle;
    \\   flow         Angular_Force;
    \\enddiscipline
    \\
    \\discipline rotational_omega;
    \\   potential    Angular_Velocity;
    \\   flow         Angular_Force;
    \\enddiscipline
    \\`endif
;

// ---------------------------------------------------------------------------
// Annex E — the Table E.1 SPICE primitives, as ordinary modules
// ---------------------------------------------------------------------------

/// Annex E Table E.1 — the "basic set of SPICE primitives" E.2 requires a
/// SPICE-compatible tool to provide, written as ordinary Verilog-AMS module
/// declarations and prepended like the annex D files.
///
/// WHY A PRELUDE OF MODULES, and not a table of names in the parser or codegen.
/// E.2 is explicit that "SPICE primitives built into the simulator shall be
/// treated in the same manner in Verilog-AMS HDL as built-in primitives" — the
/// same MANNER, which is instantiation. A primitive that is a real module gets
/// §6.3 parameter overrides, §6.5.5 named connection, §6.2.2 elaboration, §6.7.1
/// hierarchical access and every diagnostic in those clauses for free, from the
/// code that already implements them; a hard-coded name gets none of it and has
/// to reimplement each one. It is also readable: a user can see what `resistor`
/// does, which is the only defence against E.1.2's fourth axis of
/// incompatibility ("the mathematical description of the built-in primitives can
/// differ").
///
/// WHAT IS NORMATIVE HERE AND WHAT IS NOT. Table E.1 fixes three things and
/// nothing else: the primitive NAME, the port names IN ORDER, and the parameter
/// names IN ORDER (E.3: "for connection by order instead of by name, the ports
/// and parameters shall be given in the order listed"), plus "the default
/// discipline of the ports for these primitives shall be electrical and their
/// descriptions shall be inout". So the headers below are transcription and must
/// not drift. Everything else is implementation-dependent BY THE ANNEX'S OWN
/// WORDS — E.2: "while the Verilog-AMS HDL built-in primitives are standardized,
/// the SPICE primitives are not. All aspects of SPICE primitives are
/// implementation dependent" — which covers every parameter DEFAULT (Table E.1
/// lists none), every value range, and the five rows whose Behavior column is
/// EMPTY (tline, diode, bjt, mosfet, jfet, mesfet: interface only, no equations,
/// and a comment at each site saying so).
///
/// THE BEHAVIOR COLUMN IS CONTRIBUTED AS A FLOW WHEREVER THE TABLE'S EQUATION
/// ALLOWS IT. Table E.1 writes the resistor as `V = I*r*(...)`, which as a
/// potential contribution makes the branch a source and its current an unknown
/// the equation system carries; written as the algebraically identical
/// `I <+ V/(r*(...))` the current is the contributed value, which is what a
/// §6.7.1 flow probe of the primitive's branch reads back. Same equation, and
/// the observable the annex describes is observable.
///
/// `dc`, `mag` and `phase` lead the parameter list of every independent source
/// row and appear in NONE of their Behavior expressions: they are the §4.6.1
/// analysis-dependent values (DC operating point, AC magnitude and phase) rather
/// than terms of the transient waveform. They are declared, in Table E.1's
/// order, and unused — selecting on `$analysis`/`analysis()` is the ceiling.
///
/// E.3.1's ccvs, cccs and mutual inductor are ABSENT on purpose: they take a
/// controlling INSTANCE name as a parameter, "Verilog-AMS HDL does not support
/// the concept of passing an instance name as a parameter", and so E.3.1 says in
/// terms that they "are not supported". A missing module is the right answer and
/// E0904 is its diagnostic.
pub const spice_primitives =
    \\// Annex E Table E.1 — names, ports and parameters transcribed; see
    \\// `Preprocessor.spice_primitives` for what of this is normative.
    \\
    \\// resistor | p, n | r, tc1, tc2 | V = I*r*(1 + tc1*T + tc2*T^2)
    \\//
    \\// `T` is a bare T in the published table: it fixes neither a reference
    \\// temperature nor whether the polynomial is in absolute temperature or in
    \\// the rise above nominal, so it is read here as §9.10 `$temperature` in
    \\// kelvin. tc1 = tc2 = 0 collapses the factor to exactly 1 at every T,
    \\// which is the only reading the table pins.
    \\module resistor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real r = 1.0 from (0:inf);
    \\   parameter real tc1 = 0.0;
    \\   parameter real tc2 = 0.0;
    \\   analog
    \\      I(p, n) <+ V(p, n) / (r * (1.0 + tc1 * $temperature
    \\                                     + tc2 * $temperature * $temperature));
    \\endmodule
    \\
    \\// capacitor | p, n | c, ic | V = (1/c)*integral(I) + ic
    \\//
    \\// Written as the table's integral form rather than as `I <+ c*ddt(V)`,
    \\// because §4.5.5's second argument to `idt` IS the initial condition the
    \\// `ic` parameter names and `ddt` has nowhere to put it.
    \\module capacitor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real c = 1.0 from (0:inf);
    \\   parameter real ic = 0.0;
    \\   analog
    \\      V(p, n) <+ idt(I(p, n) / c, ic);
    \\endmodule
    \\
    \\// inductor | p, n | l, ic | I = l*integral(V) + ic
    \\//
    \\// The published row multiplies by `l` where the physics divides by it; the
    \\// dimensionally correct 1/l is used here. An inductor whose current grew
    \\// with its inductance would be a transcription bug shipped as a device.
    \\module inductor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real l = 1.0 from (0:inf);
    \\   parameter real ic = 0.0;
    \\   analog
    \\      I(p, n) <+ idt(V(p, n) / l, ic);
    \\endmodule
    \\
    \\// iexp | p, n | dc, mag, phase, val0, val1, td0, tau0, td1, tau1
    \\//
    \\// `Itd1`, "the value of I at time t = td1", is the second branch evaluated
    \\// at td1 — a closed form, not a recurrence. The first branch is `val0` in
    \\// the iexp row and `dc` in the vexp row; both are transcribed as printed.
    \\module iexp(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td0 = 0.0;
    \\   parameter real tau0 = 1.0 from (0:inf);
    \\   parameter real td1 = 1.0;
    \\   parameter real tau1 = 1.0 from (0:inf);
    \\   analog begin
    \\      if ($abstime <= td0)
    \\         I(p, n) <+ val0;
    \\      else if ($abstime <= td1)
    \\         I(p, n) <+ val1 - (val1 - dc) * exp((td0 - $abstime) / tau0);
    \\      else
    \\         I(p, n) <+ val0 - (val0 - (val1 - (val1 - dc)
    \\                                   * exp((td0 - td1) / tau0)))
    \\                          * exp((td1 - $abstime) / tau1);
    \\   end
    \\endmodule
    \\
    \\// ipulse | p, n | dc, mag, phase, val0, val1, td, rise, fall, width, period
    \\//
    \\// The table's t0..t4 are one period offset by `n*period` for non-negative
    \\// integer n, so the five branches are the ONE period the time reduced into
    \\// it falls in. period = 0 is a single pulse (nothing to reduce).
    \\module ipulse(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td = 0.0;
    \\   parameter real rise = 1e-12 from (0:inf);
    \\   parameter real fall = 1e-12 from (0:inf);
    \\   parameter real width = 1e-9 from (0:inf);
    \\   parameter real period = 0.0 from [0:inf);
    \\   analog begin : pulse
    \\      real tp;
    \\      tp = $abstime - td;
    \\      if (period > 0.0 && tp > 0.0)
    \\         tp = tp - period * floor(tp / period);
    \\      if (tp <= 0.0)
    \\         I(p, n) <+ val0;
    \\      else if (tp <= rise)
    \\         I(p, n) <+ val0 + (val1 - val0) * tp / rise;
    \\      else if (tp <= rise + width)
    \\         I(p, n) <+ val1;
    \\      else if (tp <= rise + width + fall)
    \\         I(p, n) <+ val1 + (val0 - val1) * (tp - rise - width) / fall;
    \\      else
    \\         I(p, n) <+ val0;
    \\   end
    \\endmodule
    \\
    \\// ipwl | p, n | dc, mag, phase, wave
    \\//
    \\// `wave` is (time, value) pairs and the table's `n = len(wave)`. §3.4.4
    \\// sizes an array parameter with a range, and there is no unsized array
    \\// parameter to declare, so the length is its own parameter and an instance
    \\// with more than four entries overrides `nwave` alongside `wave`. That is
    \\// the one place this row's interface is wider than Table E.1's.
    \\module ipwl(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter integer nwave = 4 from [4:inf);
    \\   parameter real wave[0:nwave-1] = '{0.0, 0.0, 1.0, 0.0};
    \\   analog begin : pwl
    \\      integer i;
    \\      real iw;
    \\      iw = wave[nwave-1];
    \\      for (i = 0; i + 3 <= nwave - 1; i = i + 2) begin
    \\         if ($abstime >= wave[i] && $abstime < wave[i+2])
    \\            iw = wave[i+1] + (wave[i+3] - wave[i+1])
    \\                             * ($abstime - wave[i]) / (wave[i+2] - wave[i]);
    \\      end
    \\      I(p, n) <+ iw;
    \\   end
    \\endmodule
    \\
    \\// isine | p, n | dc, mag, phase, offset, ampl, freq, td, damp, sinephase,
    \\//               ammodindex, ammodfreq, ammodphase, fmmodindex, fmmodfreq
    \\//
    \\// I = offset + ampl * (1 - Fam*cos(2*pi*Fam_f*(t-td) - Pam))
    \\//                   * (1 - damp*(t-td))
    \\//                   * cos(2*pi*freq*(1 - Ffm*cos(2*pi*Ffm_f*(t-td)))*(t-td)
    \\//                         - Psin)
    \\// The published row labels the FM frequency f_AM in both source rows; it is
    \\// fmmodfreq, as the parameter name says.
    \\module isine(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real offset = 0.0;
    \\   parameter real ampl = 1.0;
    \\   parameter real freq = 1.0 from (0:inf);
    \\   parameter real td = 0.0;
    \\   parameter real damp = 0.0;
    \\   parameter real sinephase = 0.0;
    \\   parameter real ammodindex = 0.0;
    \\   parameter real ammodfreq = 0.0;
    \\   parameter real ammodphase = 0.0;
    \\   parameter real fmmodindex = 0.0;
    \\   parameter real fmmodfreq = 0.0;
    \\   analog
    \\      I(p, n) <+ offset + ampl
    \\         * (1.0 - ammodindex * cos(`M_TWO_PI * ammodfreq * ($abstime - td)
    \\                                   - ammodphase))
    \\         * (1.0 - damp * ($abstime - td))
    \\         * cos(`M_TWO_PI * freq
    \\               * (1.0 - fmmodindex * cos(`M_TWO_PI * fmmodfreq
    \\                                         * ($abstime - td)))
    \\               * ($abstime - td) - sinephase);
    \\endmodule
    \\
    \\// vexp | p, n | dc, mag, phase, val0, val1, td0, tau0, td1, tau1
    \\// The iexp row with V for I, and `dc` rather than `val0` before td0.
    \\module vexp(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td0 = 0.0;
    \\   parameter real tau0 = 1.0 from (0:inf);
    \\   parameter real td1 = 1.0;
    \\   parameter real tau1 = 1.0 from (0:inf);
    \\   analog begin
    \\      if ($abstime <= td0)
    \\         V(p, n) <+ dc;
    \\      else if ($abstime <= td1)
    \\         V(p, n) <+ val1 - (val1 - dc) * exp((td0 - $abstime) / tau0);
    \\      else
    \\         V(p, n) <+ val0 - (val0 - (val1 - (val1 - dc)
    \\                                   * exp((td0 - td1) / tau0)))
    \\                          * exp((td1 - $abstime) / tau1);
    \\   end
    \\endmodule
    \\
    \\// vpulse | p, n | dc, mag, phase, val0, val1, td, rise, fall, width, period
    \\module vpulse(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td = 0.0;
    \\   parameter real rise = 1e-12 from (0:inf);
    \\   parameter real fall = 1e-12 from (0:inf);
    \\   parameter real width = 1e-9 from (0:inf);
    \\   parameter real period = 0.0 from [0:inf);
    \\   analog begin : pulse
    \\      real tp;
    \\      tp = $abstime - td;
    \\      if (period > 0.0 && tp > 0.0)
    \\         tp = tp - period * floor(tp / period);
    \\      if (tp <= 0.0)
    \\         V(p, n) <+ val0;
    \\      else if (tp <= rise)
    \\         V(p, n) <+ val0 + (val1 - val0) * tp / rise;
    \\      else if (tp <= rise + width)
    \\         V(p, n) <+ val1;
    \\      else if (tp <= rise + width + fall)
    \\         V(p, n) <+ val1 + (val0 - val1) * (tp - rise - width) / fall;
    \\      else
    \\         V(p, n) <+ val0;
    \\   end
    \\endmodule
    \\
    \\// vpwl | p, n | dc, mag, phase, wave
    \\// See ipwl for `nwave`. The published row's last line reads `I = wave[n-1]`
    \\// where every other line of it reads V; it is V.
    \\module vpwl(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter integer nwave = 4 from [4:inf);
    \\   parameter real wave[0:nwave-1] = '{0.0, 0.0, 1.0, 0.0};
    \\   analog begin : pwl
    \\      integer i;
    \\      real vw;
    \\      vw = wave[nwave-1];
    \\      for (i = 0; i + 3 <= nwave - 1; i = i + 2) begin
    \\         if ($abstime >= wave[i] && $abstime < wave[i+2])
    \\            vw = wave[i+1] + (wave[i+3] - wave[i+1])
    \\                             * ($abstime - wave[i]) / (wave[i+2] - wave[i]);
    \\      end
    \\      V(p, n) <+ vw;
    \\   end
    \\endmodule
    \\
    \\// vsine | p, n | dc, mag, phase, offset, ampl, freq, td, damp, sinephase,
    \\//               ammodindex, ammodfreq, ammodphase, fmmodindex, fmmodfreq
    \\// The isine row with V for I.
    \\module vsine(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real offset = 0.0;
    \\   parameter real ampl = 1.0;
    \\   parameter real freq = 1.0 from (0:inf);
    \\   parameter real td = 0.0;
    \\   parameter real damp = 0.0;
    \\   parameter real sinephase = 0.0;
    \\   parameter real ammodindex = 0.0;
    \\   parameter real ammodfreq = 0.0;
    \\   parameter real ammodphase = 0.0;
    \\   parameter real fmmodindex = 0.0;
    \\   parameter real fmmodfreq = 0.0;
    \\   analog
    \\      V(p, n) <+ offset + ampl
    \\         * (1.0 - ammodindex * cos(`M_TWO_PI * ammodfreq * ($abstime - td)
    \\                                   - ammodphase))
    \\         * (1.0 - damp * ($abstime - td))
    \\         * cos(`M_TWO_PI * freq
    \\               * (1.0 - fmmodindex * cos(`M_TWO_PI * fmmodfreq
    \\                                         * ($abstime - td)))
    \\               * ($abstime - td) - sinephase);
    \\endmodule
    \\
    \\// tline | t1, b1, t2, b2 | z0, td, f, nl | (Behavior column EMPTY)
    \\//
    \\// Interface only. The table gives no equations for this row, and a
    \\// transmission line is the one passive whose behaviour is not derivable
    \\// from its parameter names: z0 with td is a delay line, z0 with f and nl is
    \\// the same line specified by electrical length at a frequency, and the
    \\// table says which of the two a given instance means nowhere. E.2 makes
    \\// that choice implementation-dependent; guessing it here would put a
    \\// specific simulator's convention in a shipped standard file.
    \\module tline(t1, b1, t2, b2);
    \\   inout t1, b1, t2, b2;
    \\   electrical t1, b1, t2, b2;
    \\   parameter real z0 = 50.0;
    \\   parameter real td = 0.0;
    \\   parameter real f = 0.0;
    \\   parameter real nl = 0.0;
    \\endmodule
    \\
    \\// vccs | sink, src, ps, ns | gm | I(sink, src) = gm*V(ps, ns)
    \\module vccs(sink, src, ps, ns);
    \\   inout sink, src, ps, ns;
    \\   electrical sink, src, ps, ns;
    \\   parameter real gm = 1.0;
    \\   analog
    \\      I(sink, src) <+ gm * V(ps, ns);
    \\endmodule
    \\
    \\// vcvs | p, n, ps, ns | gain | V(p, n) = gain*V(ps, ns)
    \\module vcvs(p, n, ps, ns);
    \\   inout p, n, ps, ns;
    \\   electrical p, n, ps, ns;
    \\   parameter real gain = 1.0;
    \\   analog
    \\      V(p, n) <+ gain * V(ps, ns);
    \\endmodule
    \\
    \\// The five semiconductor rows. Behavior column EMPTY for every one of them,
    \\// and E.2: "all aspects of SPICE primitives are implementation dependent".
    \\// A SPICE netlist gives these their equations through a .MODEL card whose
    \\// parameters Table E.1 does not list and E.1.2's fourth axis says differ
    \\// between simulators; E.3's last paragraph is how Verilog-AMS supplies them
    \\// instead — "in Verilog-AMS they may be used directly in a paramset
    \\// statement" (§6.4), which is a paramset over the interface below.
    \\
    \\// diode | a, c | area
    \\module diode(a, c);
    \\   inout a, c;
    \\   electrical a, c;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// bjt | c, b, e, s | area
    \\module bjt(c, b, e, s);
    \\   inout c, b, e, s;
    \\   electrical c, b, e, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// mosfet | d, g, s, b | w, l, ad, as, pd, ps, nrd, nrs
    \\module mosfet(d, g, s, b);
    \\   inout d, g, s, b;
    \\   electrical d, g, s, b;
    \\   parameter real w = 1.0;
    \\   parameter real l = 1.0;
    \\   parameter real ad = 0.0;
    \\   parameter real as = 0.0;
    \\   parameter real pd = 0.0;
    \\   parameter real ps = 0.0;
    \\   parameter real nrd = 0.0;
    \\   parameter real nrs = 0.0;
    \\endmodule
    \\
    \\// jfet | d, g, s | area
    \\module jfet(d, g, s);
    \\   inout d, g, s;
    \\   electrical d, g, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// mesfet | d, g, s | area
    \\module mesfet(d, g, s);
    \\   inout d, g, s;
    \\   electrical d, g, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
;

/// How many module declarations `spice_primitives` holds, COUNTED FROM THE TEXT
/// so the number cannot drift from the prelude it describes.
///
/// This is how a consumer tells a shipped primitive from a user's module without
/// a byte offset threaded through four stages: the prelude is prepended verbatim
/// whenever `Options.std_defs` is set, its modules therefore occupy exactly the
/// first `spice_module_count` entries of `Ast.SourceFile.modules` (the parser
/// appends in source order), and `Ast.SourceFile.builtin_modules` is set to this.
/// E.3.3's "a module defined in the Verilog-AMS will always be selected in
/// favor of a SPICE primitive using exactly the same name" is then a search
/// order, and §6.2.2's top can never be a primitive.
pub const spice_module_count = blk: {
    @setEvalBranchQuota(200_000);
    // ponytail: count the fixed, non-overlapping header spelling with stdlib;
    // use tokens if the embedded source ever needs a general declaration count.
    break :blk @as(u32, @intCast(std.mem.count(u8, spice_primitives, "\nmodule ")));
};

/// annex D.3 — driver_access.vams, verbatim. Twelve masks naming the bit each
/// §7 driver flag occupies. Self-guarded, and NOT preloaded: nothing in the
/// analog subset reads a driver, so a design has to `include it.
pub const driver_access_vams =
    \\// Copyright(c) 2009-2014 Accellera Systems Initiative Inc.
    \\// Verbatim copies of the material in annex D may be used and distributed
    \\// without restriction. VAMS-2023.
    \\`ifdef DRIVER_ACCESS_VAMS
    \\`else
    \\`define DRIVER_ACCESS_VAMS  1
    \\`define DRIVER_UNKNOWN      32'b00000000000    // No information
    \\`define DRIVER_DELAYED      32'b00000000001    // driver has fixed delay
    \\`define DRIVER_GATE         32'b00000000010    // driver is a primitive
    \\`define DRIVER_UDP          32'b00000000100    // driver is a user defined primitive
    \\`define DRIVER_ASSIGN       32'b00000001000    // driver is a continuous assignment
    \\`define DRIVER_BEHAVIORAL   32'b00000010000    // driver is a reg
    \\`define DRIVER_SDF          32'b00000100000    // driver is from backannotated code
    \\`define DRIVER_NODELETE     32'b00001000000    // events won't be deleted
    \\`define DRIVER_NOPREEMPT    32'b00010000000    // events won't be preempted
    \\`define DRIVER_KERNEL       32'b00100000000    // added by kernel (wor/wand)
    \\`define DRIVER_WOR          32'b01000000000    // driver is on a wor net
    \\`define DRIVER_WAND         32'b10000000000    // driver is on a wand net
    \\`endif
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Preprocess without the std-def prelude, on an arena backed by the testing
/// allocator; the result is duped so the arena can be torn down (leak-checked).
fn runTest(src: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = try process(arena_state.allocator(), src, .{ .std_defs = false, .bag = &bag });
    return testing.allocator.dupe(u8, text);
}

fn expectPp(expected: []const u8, src: []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// The line-number contract: nothing this stage deletes may change the count.
fn expectPreserved(src: []const u8, present: []const []const u8, absent: []const []const u8) !void {
    const got = try runTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqual(
        std.mem.count(u8, src, "\n"),
        std.mem.count(u8, got, "\n"),
    );
    for (present) |s| try testing.expect(std.mem.indexOf(u8, got, s) != null);
    for (absent) |s| try testing.expect(std.mem.indexOf(u8, got, s) == null);
}

/// Fails with `code`, and the span it reports lands inside the file it names.
fn expectFail(src: []const u8, code: diag.Code) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    try testing.expectError(error.PreprocessFailed, process(
        arena_state.allocator(),
        src,
        .{ .std_defs = false, .bag = &bag },
    ));
    try testing.expectEqual(@as(usize, 1), bag.count());
    const e = bag.at(0);
    try testing.expectEqual(code, e.code);
    try testing.expect(bag.failed());
    // A preprocess span is file-local: it must index the file it names.
    try testing.expect(e.file != null);
    try testing.expect(e.span.end <= bag.fileText(e.file.?).len);
    // The title carries the condition; the message may not repeat it.
    try testing.expect(std.mem.indexOf(u8, e.message, "LRM") == null);
}

test "findStop agrees with the scalar loop it replaced, at every tail boundary" {
    // The reference: the loop `scan` and `stripComments` used to run inline,
    // one byte at a time. `findStop`'s vector block must never disagree with it.
    const scalar = struct {
        fn find(text: []const u8, from: usize, comptime stops: []const u8) usize {
            var i = from;
            while (i < text.len) : (i += 1) {
                for (stops) |s| if (text[i] == s) return i;
            }
            return i;
        }
    }.find;

    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    // Every length from the empty slice through three full vectors, so both
    // tail boundaries and the no-vector-iteration case are covered.
    var buf: [3 * 64 + 1]u8 = undefined;
    for (0..3 * lanes + 1) |len| {
        for (0..64) |_| {
            // A byte set that hits the stops often enough to land one in every
            // lane position, and rarely enough to leave long ordinary runs.
            for (buf[0..len]) |*b| b.* = switch (rand.uintLessThan(u8, 10)) {
                0 => '"',
                1 => '\\',
                2 => '`',
                3 => '/',
                4 => '\n',
                else => 'a' + rand.uintLessThan(u8, 26),
            };
            const text = buf[0..len];
            // Sweep `from` too: `scan` never calls this at offset 0 only.
            for (0..len + 1) |from| {
                try testing.expectEqual(scalar(text, from, scan_stops), findStop(text, from, scan_stops));
                try testing.expectEqual(scalar(text, from, "\"\\/"), findStop(text, from, "\"\\/"));
            }
        }
    }
}

test "putNewlines emits exactly the newlines the byte loop it replaced did" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    var prng: std.Random.DefaultPrng = .init(0xf00d);
    const rand = prng.random();
    var buf: [200]u8 = undefined;
    for (0..buf.len + 1) |len| {
        for (buf[0..len]) |*b| b.* = if (rand.uintLessThan(u8, 4) == 0) '\n' else 'x';
        const span = buf[0..len];

        // The reference: `for (span) |c| if (c == '\n') append('\n');`
        var want: usize = 0;
        for (span) |c| want += @intFromBool(c == '\n');

        var pp: Pp = .{ .arena = arena, .opts = .{ .bag = &bag } };
        try pp.putNewlines(span);
        try testing.expectEqual(want, pp.out.items.len);
        for (pp.out.items) |c| try testing.expectEqual(@as(u8, '\n'), c);
    }
}

test "§2.4 comments vanish, newlines do not — but the separator survives" {
    try expectPp("a\n\nb\n", "a// gone\n/* two\n   lines */b\n");
    try expectPp("\"// not a comment\"\n", "\"// not a comment\"\n");
    // §2.4 block comments do not nest: the first `*/` closes it.
    try expectPp("x   y\n", "x /* a /* b */ y\n");
    try expectFail("x\n/* never closed\n", .E0102);

    // §2.2 makes a comment a token SEPARATOR, so a comment with no newline in
    // it still has to leave one byte of whitespace behind. Dropping it welded
    // the neighbours: these two used to reach the lexer as the integer `12` and
    // as the single operator `<=`, and both compiled without a word.
    try expectPp("1 2", "1/*c*/2");
    try expectPp("a < = b", "a </*c*/= b");
    // A multi-line comment already separates via its newlines; it must not gain
    // a spurious extra space.
    try expectPp("1\n2", "1/*\n*/2");
}

test "§10.4 object-like and function-like macros" {
    try expectPp("\n3.0*v", "`define GAIN 3.0\n`GAIN*v");
    try expectPp("\n((v)*(v))", "`define SQ(x) ((x)*(x))\n`SQ(v)");
    // Nested expansion (fixture ch10 07_nested_macros).
    try expectPp(
        "\n\n(((v)*(v)) + (v))",
        "`define I(x) ((x)*(x))\n`define O(x) (`I(x) + (x))\n`O(v)",
    );
    // Multi-line macro text (fixture ch10 06_define_multiline).
    try expectPp("\n\n(1 + 2)", "`define P (1 + \\\n2)\n`P");
    // A formal is only substituted as a whole identifier, and never inside a
    // string or after a '`'.
    try expectPp("\n\"x\" ax 1", "`define M(x) \"x\" ax x\n`M(1)");
    // Commas inside nested parens do not split arguments.
    try expectPp("\n(max(a,b))+(c)", "`define A(p,q) (p)+(q)\n`A(max(a,b), c)");
    try expectFail("`define SQ(x) x\n`SQ\n", .E0116);
    try expectFail("`define SQ(x) x\n`SQ(1,2)\n", .E0117);
    // A formal spelled INSIDE a §2.8.1 escaped identifier is part of that
    // identifier, not a use of the formal — `substitute` treats `\…` as opaque
    // exactly as `scan` and `stripComments` do.
    try expectPp("\nreal \\sig-x ;", "`define M(x) real \\sig-x ;\n`M(1)");
}

test "§10.4 macro argument brackets must match their openers" {
    // Matched nesting of all three bracket kinds is opaque to the comma split.
    try expectPp("\n{[(a)],b}", "`define SQ(x) x\n`SQ({[(a)],b})");
    // One shared depth counter let ANY of `)]}` close the list — `` `SQ(2.0] ``
    // compiled clean and crossed nestings mis-sliced the arguments. A closer
    // that does not match its opener is E0120: the `(` it abandons really is
    // unterminated.
    try expectFail("`define SQ(x) x\n`SQ(2.0]\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ({a)}\n", .E0120);
    try expectFail("`define SQ(x) x\n`SQ([1,2)]\n", .E0120);
}

test "§10.4 a nested invocation in an actual argument is not recursion" {
    // §10.4 hands text macros to IEEE Std 1364, whose recursion rule is about
    // the macro's TEXT referring to itself — a property of the DEFINITION.
    // `MAX`'s text refers only to its formals; the nested use sits in the CALL,
    // and arguments are fully expanded before substitution (fixture ch10 49).
    // The old splice-then-rescan model reported E0118 "MAX -> MAX" here.
    try expectPp(
        "\n((((1.0)>(2.0)?(1.0):(2.0)))>(3.0)?(((1.0)>(2.0)?(1.0):(2.0))):(3.0))",
        "`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`MAX(1.0,2.0),3.0)",
    );
    // An object-like use inside an argument expands there too, and a
    // function-like macro nested in ANOTHER macro's argument keeps working.
    try expectPp(
        "\n\n((7.0)>(2.0)?(7.0):(2.0))",
        "`define A 7.0\n`define MAX(a,b) ((a)>(b)?(a):(b))\n`MAX(`A,2.0)",
    );
    // Genuine self-reference in the TEXT is still the E0118 the rule is about:
    // object-like, function-like, and mutual (indirect).
    try expectFail("`define R `R\n`R\n", .E0118);
    try expectFail("`define F(x) `F(x)\n`F(1)\n", .E0118);
    try expectFail("`define A(x) `B(x)\n`define B(y) `A(y)\n`A(1)\n", .E0118);

    // E0119's ceiling now counts argument pre-expansion too: nested same-macro
    // calls never repeat a name on `expanding`, so the DEPTH is what bounds
    // the native stack.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "`define M(x) (x)\n");
    for (0..max_expansion_depth + 1) |_| try src.appendSlice(testing.allocator, "`M(");
    try src.appendSlice(testing.allocator, "1");
    for (0..max_expansion_depth + 1) |_| try src.appendSlice(testing.allocator, ")");
    try src.appendSlice(testing.allocator, "\n");
    try expectFail(src.items, .E0119);
}

test "escaped identifiers reach `undef, the conditionals and `default_discipline" {
    // Syntax 10-3 / A.9.3: every directive whose operand is an `identifier`
    // takes the §2.8.1 spelling, not just `define (fixture ch10 50).
    try expectPreserved("`define \\M-X 1\n`ifdef \\M-X\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    try expectPreserved("`define \\M-X 1\n`undef \\M-X\n`ifndef \\M-X\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved("`define \\M-X 1\n`ifdef NOPE\na\n`elsif \\M-X\nb\n`else\nc\n`endif\n", &.{"b"}, &.{ "a", "c" });

    // §10.2: annex D.1's `discipline \logic ;` is only nameable this way, and
    // §2.8.1 makes the recorded name the bare bytes between `\` and the space.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    var defs: []const DefaultDiscipline = &.{};
    _ = try process(arena_state.allocator(), "`default_discipline \\logic\n", .{
        .std_defs = false,
        .defaults = &defs,
        .bag = &bag,
    });
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("logic", defs[0].discipline);
}

test "§10.4 undef, and IEEE 1364 conditionals" {
    try expectPreserved(
        "`define A\n`undef A\n`ifdef A\ntaken\n`else\nother\n`endif\n",
        &.{"other"},
        &.{"taken"},
    );
    try expectPreserved(
        "`define S\n`ifdef F\n1\n`elsif S\n2\n`else\n3\n`endif\n",
        &.{"2"},
        &.{ "1", "3" },
    );
    try expectPreserved(
        "`define O\n`define I\n`ifdef O\n`ifdef I\nsix\n`else\ntwo\n`endif\n`else\none\n`endif\n",
        &.{"six"},
        &.{ "two", "one" },
    );
    try expectPreserved("`ifndef NOPE\nyes\n`else\nno\n`endif\n", &.{"yes"}, &.{"no"});
    // An undefined macro inside a dead arm is not an error.
    try expectPreserved("`ifdef NOPE\n`MISSING\n`endif\n", &.{}, &.{"MISSING"});
    try expectFail("`ifdef A\nx\n", .E0101);
    try expectFail("`endif\n", .E0108);
    try expectFail("`ifdef A\n`else\n`else\n`endif\n", .E0106);
}

test "§10.5 predefined macros survive undef and resetall" {
    try expectPreserved("`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
    try expectPreserved(
        "`undef __VAMS_ENABLE__\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n",
        &.{"yes"},
        &.{},
    );
    // ... but user macros do not (fixture ch10 20_resetall_clears_macro).
    try expectFail("`define V 2.0\n`resetall\n`V\n", .E0115);
    try expectPreserved("`resetall\n`ifdef __VAMS_ENABLE__\nyes\n`endif\n", &.{"yes"}, &.{});
}

test "§9.15 Table 9-27 reads `timescale back, in seconds" {
    const T = struct {
        /// The published timescale for `src`, which is the whole §9.15 surface:
        /// it contributes nothing to the output text (the first row pins that).
        fn ts(src: []const u8) !?Timescale {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            var out: ?Timescale = null;
            _ = try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .timescale = &out,
                .bag = &bag,
            });
            return out;
        }
    };
    // Table 9-27's units column is "s", not ticks.
    const t = (try T.ts("`timescale 1ns/1ps\n")).?;
    try testing.expectEqual(@as(f64, 1e-9), t.unit);
    try testing.expectEqual(@as(f64, 1e-12), t.precision);
    // Every magnitude on IEEE 1364 Table 19-1's grid, and the coarsest unit.
    const t2 = (try T.ts("`timescale 100us / 10 ns\n")).?;
    try testing.expectEqual(@as(f64, 100e-6), t2.unit);
    try testing.expectEqual(@as(f64, 10e-9), t2.precision);
    // No directive is NOT a default: §9.15 says "as specified in `timescale",
    // and with nothing specified the parameter is not known (E0811).
    try testing.expectEqual(@as(?Timescale, null), try T.ts("module m; endmodule\n"));
    // §19.6 `resetall returns it to that state.
    try testing.expectEqual(@as(?Timescale, null), try T.ts("`timescale 1ns/1ps\n`resetall\n"));
    // Off Table 19-1 in each of the three ways, plus §19.9's ordering rule.
    for ([_][]const u8{
        "`timescale 2ns/1ps\n", // magnitude
        "`timescale 1sec/1ps\n", // unit name
        "`timescale 1ns 1ps\n", // no slash
        "`timescale 1ps/1ns\n", // precision coarser than the unit
    }) |src| try testing.expectEqual(@as(?Timescale, null), try T.ts(src));
    // The last one in the stream is the one in force (one elaborated module).
    try testing.expectEqual(@as(f64, 1e-3), (try T.ts("`timescale 1ns/1ps\n`timescale 1ms/1us\n")).?.unit);
}

test "accepted-and-ignored directives, and rejected ones" {
    try expectPp(
        "\n\n\n\n",
        "`timescale 1ns/1ps\n`default_nettype wire\n`celldefine\n`pragma f harmless\n",
    );
    try expectPp("\n\n", "`default_discipline electrical\n`default_transition 1n\n");
    // §10.6 is the exception: passed through verbatim for the parser, which is
    // the only stage that knows where a design element starts.
    try expectPp(
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
        "`begin_keywords \"VAMS-2023\"\n`end_keywords\n",
    );
    // ... but still dies with an inactive `ifdef arm, like any other directive.
    try expectPp("\n\n\n", "`ifdef NOPE\n`begin_keywords \"VAMS-2.3\"\n`endif\n");
    try expectFail("`MISSING\n", .E0115); // fixture ch10 23
    try expectFail("`nosuchdirective_or_macro\n", .E0115);
    try expectFail("`define R `R\n`R\n", .E0118); // cycle guard
}

test "§10.7 `__FILE__ and `__LINE__" {
    // fixtures ch10 21, 22. The default `Options.file_name` is "<source>".
    try expectPp("\"<source>\"\n", "`__FILE__\n");
    // PHYSICAL lines, counted through the comment the stripper deleted and
    // through a directive that collapsed to its newline.
    try expectPp("\n\n\n4 4\n", "// c\n`define X 1\n\n`__LINE__ `__LINE__\n");
    // fixture ch10 44: IEEE 1364 §19.7 numbers the line AFTER the directive.
    try expectPp("\n100\n101\n", "`line 100 \"virtual.va\" 0\n`__LINE__\n`__LINE__\n");
    try expectPp("\n\"virtual.va\"\n", "`line 100 \"virtual.va\" 0\n`__FILE__\n");
    try expectFail("`line\n", .E0128);
    try expectFail("`line nope\n", .E0128);
}

test "§10.2 `default_discipline Syntax 10-1" {
    try expectPp("\n\n\n", "`default_discipline\n`default_discipline electrical\n`default_discipline electrical wire\n");
    // fixture ch10 45: a discipline name is not one of the fifteen qualifiers.
    try expectFail("`default_discipline electrical electrical\n", .E0127);
    try expectFail("`default_discipline electrical wire junk\n", .E0127);
}

test "§10.3 `default_transition Syntax 10-2" {
    // The published §10.3 events for `src`, which is the whole surface §4.5.8
    // consumes: the value, and the output offset it takes effect from.
    const T = struct {
        fn ev(src: []const u8) ![]const DefaultTransition {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var bag: diag.Bag = .init(arena_state.allocator());
            var out: []const DefaultTransition = &.{};
            _ = try process(arena_state.allocator(), src, .{
                .std_defs = false,
                .transitions = &out,
                .bag = &bag,
            });
            return testing.allocator.dupe(DefaultTransition, out);
        }
    };

    const one = try T.ev("`default_transition 4n\n");
    defer testing.allocator.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(f64, 4e-9), one[0].time);

    // §10.3's supersession sentence: BOTH are published, in text order, so the
    // consumer can pick "the directive which immediately precedes" a call
    // rather than being handed one latched value.
    const two = try T.ev("`default_transition 8n\n`default_transition 4n\n");
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqual(@as(f64, 8e-9), two[0].time);
    try testing.expectEqual(@as(f64, 4e-9), two[1].time);
    try testing.expect(two[0].at < two[1].at);

    // Every §2.6.2 spelling of the same time, since the operand is read in a
    // text stage and not by the number lexer proper.
    for ([_][]const u8{ "4n\n", "4e-9\n", "0.000000004\n", "4_000p\n" }) |t| {
        const src = try std.fmt.allocPrint(testing.allocator, "`default_transition {s}", .{t});
        defer testing.allocator.free(src);
        const e = try T.ev(src);
        defer testing.allocator.free(e);
        try testing.expectEqual(@as(f64, 4e-9), e[0].time);
    }

    // fixture ch10 48: the operand is not bracketed in Syntax 10-2, so it is
    // mandatory — and the bare form is NOT a request for the simulator default.
    try expectFail("`default_transition\n", .E0129);
    try expectFail("`default_transition    \n", .E0129);
    try expectFail("`default_transition electrical\n", .E0129);
    try expectFail("`default_transition -4n\n", .E0129);
    try expectFail("`default_transition 4n junk\n", .E0129);
}

test "`include resolves the built-in annex D files" {
    // fixture ch10 18_include_constants
    const got = try runTest("`include \"constants.vams\"\n`P_CELSIUS0 `P_K\n");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "273.15") != null);
    try testing.expect(std.mem.indexOf(u8, got, "1.3806503e-23") != null);
    try expectFail("`include \"no_such_file.vams\"\n", .E0126);
    try expectFail("`include nonsense\n", .E0122);

    // annex D.3 is shipped too, and is NOT preloaded: it has to be asked for.
    const d3 = try runTest("`include \"driver_access.vams\"\n`DRIVER_WAND\n");
    defer testing.allocator.free(d3);
    try testing.expect(std.mem.indexOf(u8, d3, "32'b10000000000") != null);
}

test "§10.4 the NAME may be escaped and the TEXT may not begin with __VAMS_" {
    // Syntax 10-3: text_macro_identifier ::= identifier, and A.9.3 makes that
    // simple OR escaped. §2.8.1 drops the `\` and the terminating white space,
    // so the definition and the use key on the same bytes.
    try expectPp("\n3.0 *v", "`define \\MY-GAIN 3.0\n`\\MY-GAIN *v");
    // An escaped name can only be object-like, and that falls out of the two
    // rules rather than being a restriction of its own: §2.8.1 ends the name at
    // the first white space, while §10.4 requires the formal list's `(` to
    // TOUCH the name — so `\SQ!(x)` is one nine-character name, not a call.
    try expectPp("\n1", "`define \\SQ!(x) 1\n`\\SQ!(x)");
    // §10.4: the macro TEXT shall not begin with __VAMS_ ...
    try expectFail("`define MY_ENABLE __VAMS_ENABLE__\n", .E0139);
    // ... and the NAME is unrestricted, which is the other half of the pair.
    try expectPp("\n7.0", "`define __VAMS_USER 7.0\n`__VAMS_USER");
}

test "annex D prelude is deterministic and self-guarded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n1: u32 = 0;
    var n2: u32 = 0;
    const src = "`include \"disciplines.vams\"\nmodule m; endmodule\n";
    // One bag per run: the compilation unit must be the FIRST file registered.
    var bag1: diag.Bag = .init(arena);
    var bag2: diag.Bag = .init(arena);
    const a = try process(arena, src, .{ .prelude_len = &n1, .bag = &bag1 });
    const b = try process(arena, src, .{ .prelude_len = &n2, .bag = &bag2 });
    try testing.expectEqualStrings(a, b); // determinism == cache identity
    try testing.expectEqual(n1, n2);

    // annex D.1 reached the output exactly once, annex D.2 defined its macros.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, a, "discipline electrical;"),
    );
    try testing.expect(std.mem.indexOf(u8, a[0..n1], "nature Voltage;") != null);
    // The re-`include collapses to just the newlines it consumed (line numbers
    // inside an included file are preserved even when its guard empties it).
    try testing.expectEqualStrings(
        "module m; endmodule\n",
        std.mem.trimStart(u8, a[n1..], "\n"),
    );
}

// The snapshot's whole correctness condition: replaying it must leave `Pp` in
// the state `runStdDefs` leaves it in. This runs the long way ONCE more, by
// hand, and compares all four things `Prelude` carries — anything a future
// prelude file writes into `Pp` and `Prelude` does not capture fails here, in
// `zig build test`, rather than in a diagnostic nobody reads.
test "the prelude snapshot replays exactly what running annex D.2/D.1/E.1 produces" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Same starting state `process` and `buildPrelude` both establish.
    var bag: diag.Bag = .init(arena);
    var pp: Pp = .{ .arena = arena, .opts = .{ .bag = &bag } };
    _ = try bag.addFile("<source>", "");
    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }
    try pp.runStdDefs();

    const p = try preludeSnapshot();
    try testing.expectEqualStrings(pp.out.items, p.text);
    try testing.expectEqual(pp.segs.items.len, p.segs.len);
    for (pp.segs.items, p.segs) |a, b| {
        try testing.expectEqual(a.out_start, b.out_start);
        try testing.expectEqual(a.in_start, b.in_start);
        try testing.expectEqual(a.file, b.file);
    }
    // The macro sets agree, both ways: `+2` is §10.5's predefined pair, which
    // the snapshot deliberately does not carry.
    try testing.expectEqual(pp.macros.count(), p.macros.len + 2);
    for (p.macros) |d| {
        const live = pp.macros.get(d.name) orelse return error.MissingMacro;
        try testing.expectEqualStrings(live.body, d.macro.body);
        try testing.expectEqual(live.is_func, d.macro.is_func);
        try testing.expectEqual(live.params.len, d.macro.params.len);
    }
    // And the three file registrations the segments index by position — the
    // strip marks included, or a replayed file renders columns differently
    // from a freshly run one.
    for (p.files, 1..) |f, id| {
        try testing.expectEqualStrings(f.name, bag.fileName(@enumFromInt(id)));
        try testing.expectEqualStrings(f.stripped, bag.fileText(@enumFromInt(id)));
        try testing.expectEqualSlices(diag.StripMark, f.marks, bag.fileMarks(@enumFromInt(id)));
    }
}

// The token snapshot's correctness condition, and it needs its OWN long way
// round: `tokenizeSeeded` and `tokenize` are two code paths over one buffer, so
// this lexes the whole preprocessed text from offset 0 — touching no snapshot —
// and compares every token of it against the seeded result. A snapshot that
// dropped a token, kept the `.eof`, or recorded a relative offset diverges here.
//
// Two inputs, because the seam moves: with an annex E.2 netlist the prelude is
// followed by synthesized modules and only THEN the user's source, and the seed
// length must still be the std-defs prefix alone.
test "the prelude token snapshot lexes exactly what lexing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = try process(arena,
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  analog I(p, n) <+ V(p, n) / r;
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist });

        // THE LONG WAY: no seed, one scan of the whole buffer.
        const long = try Lexer.Lexer.tokenize(arena, text);
        const seeded = try Lexer.Lexer.tokenizeSeeded(arena, text, try preludeTokens(true));

        try testing.expectEqual(long.len, seeded.len);
        try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
        try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));

        // The premise the seam rests on, checked rather than asserted in prose:
        // the snapshot's bytes ARE a prefix of the text, at offset 0.
        const p = try preludeSnapshot();
        try testing.expect(std.mem.startsWith(u8, text, p.text));
        // ...and the snapshot stops one token short of `.eof`, which belongs to
        // whatever buffer is actually being lexed.
        try testing.expect(p.tags.len != 0 and p.tags[p.tags.len - 1] != .eof);
    }
}

test "`--no-std-defs` gets no seed, and lexes the same either way" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);
    const text = try process(arena, "module m; endmodule\n", .{ .std_defs = false, .bag = &bag });

    try testing.expectEqual(@as(?Lexer.Lexer.Seed, null), try preludeTokens(false));
    try testing.expectEqual(@as(?*const Parser.Parser.Seed, null), try preludeAst(false));
    const long = try Lexer.Lexer.tokenize(arena, text);
    const seeded = try Lexer.Lexer.tokenizeSeeded(arena, text, try preludeTokens(false));
    try testing.expectEqualSlices(token.Tag, long.items(.tag), seeded.items(.tag));
    try testing.expectEqualSlices(u32, long.items(.start), seeded.items(.start));
}

/// Structural equality by REFLECTION, not by a hand-written field list: the AST
/// declaration types are ~20 structs of slices, and a hand-written comparator is
/// a second surface that goes stale the day someone adds a field — the exact
/// failure the test below exists to prevent. Slices of `u8` compare by CONTENT,
/// deliberately: the snapshot's names borrow the process-lifetime prelude text
/// and a fresh parse's borrow the compilation's copy of the same bytes, so
/// identical pointers are not the claim and identical bytes are.
fn expectDeepEqual(comptime T: type, a: T, b: T) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            if (p.child == u8) return testing.expectEqualStrings(a, b);
            try testing.expectEqual(a.len, b.len);
            for (a, b) |x, y| try expectDeepEqual(p.child, x, y);
        },
        .@"struct" => |s| inline for (s.fields) |f| {
            try expectDeepEqual(f.type, @field(a, f.name), @field(b, f.name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            try testing.expectEqual(@as(Tag, a), @as(Tag, b));
            inline for (u.fields) |f| {
                if (@as(Tag, a) == @field(Tag, f.name))
                    try expectDeepEqual(f.type, @field(a, f.name), @field(b, f.name));
            }
        },
        .optional => |o| {
            try testing.expectEqual(a == null, b == null);
            if (a) |x| try expectDeepEqual(o.child, x, b.?);
        },
        else => try testing.expectEqual(a, b),
    }
}

// The AST snapshot's correctness condition, and like the token one it needs its
// OWN long way round. The determinism test at the top of this file CANNOT grade
// a cache: after this change both of its runs take the cached path, so a
// snapshot that dropped a declaration is byte-identical in both and passes.
//
// So this parses the whole preprocessed text from token 0 with NO seed and
// compares the result against the seeded parse in FULL — the interner's contents
// AND its ids AND its map, every column of every `ExprStore` row, the statement
// pool, all four declaration arrays to their leaves, and the parser state that
// is not in the `SourceFile` at all (`access_names`, `pos`, `gen_construct`).
//
// Two inputs, for the same reason the token test has two: with an annex E.2
// netlist the prelude is followed by synthesized modules, so the declarations
// landing immediately after the seam are not the user's.
test "the prelude AST snapshot parses exactly what parsing the whole text produces" {
    const cases = [_][]const u8{ "", ".MODEL nn npn\n.SUBCKT amp in out\nR1 in out 1k\n.ENDS\n" };
    for (cases) |netlist| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bag: diag.Bag = .init(arena);
        const text = try process(arena,
            \\nature Pressure;
            \\  units = "Pa"; access = Pr; abstol = 1e-6;
            \\endnature
            \\discipline fluid; potential Pressure; enddiscipline
            \\module res(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real r = 1000.0 from (0.0:inf);
            \\  real acc[0:2];
            \\  analog begin : body
            \\    integer k;
            \\    for (k = 0; k < 3; k = k + 1) acc[k] = k * 2.0;
            \\    I(p, n) <+ V(p, n) / r + acc[1];
            \\  end
            \\endmodule
        , .{ .bag = &bag, .spice_netlist = netlist });

        var toks = try Lexer.Lexer.tokenize(arena, text);
        const tags = toks.items(.tag);
        const starts = toks.items(.start);

        // THE LONG WAY: no seed, one parse of every token from 0.
        var lbag: diag.Bag = .init(arena);
        var lp = Parser.Parser.init(arena, text, tags, starts, &lbag);
        const long = try lp.parseSourceFile();

        var sbag: diag.Bag = .init(arena);
        const seed = (try preludeAst(true)).?;
        var sp = try Parser.Parser.initSeeded(arena, text, tags, starts, &sbag, seed);
        // The seed is doing something: the resumed parse starts deep in the file.
        try testing.expect(sp.pos > 2000 and sp.pos < tags.len - 1);
        const seeded = try sp.parseSourceFile();

        // --- the interner: same strings, at the same ids, and the same map ---
        try testing.expectEqual(long.strings.strings.items.len, seeded.strings.strings.items.len);
        try testing.expectEqual(long.strings.map.size, seeded.strings.map.size);
        for (long.strings.strings.items, seeded.strings.strings.items, 0..) |x, y, i| {
            try testing.expectEqualStrings(x, y);
            // The id is the claim, not just the membership: everything below the
            // parser addresses a name by its `StrId`.
            const id = seeded.strings.find(y) orelse return error.NameNotInMap;
            try testing.expectEqual(i, @intFromEnum(id));
        }

        // --- the expression store: every column of every row, and the three
        // side tables the rows index ---
        try testing.expectEqual(long.exprs.nodes.len, seeded.exprs.nodes.len);
        for (0..long.exprs.nodes.len) |i| {
            try expectDeepEqual(
                @TypeOf(long.exprs.nodes.get(0)),
                long.exprs.nodes.get(i),
                seeded.exprs.nodes.get(i),
            );
        }
        try testing.expectEqualSlices(u32, long.exprs.pool.items, seeded.exprs.pool.items);
        try testing.expectEqualSlices(f64, long.exprs.reals.items, seeded.exprs.reals.items);
        try testing.expectEqualSlices(i64, long.exprs.ints.items, seeded.exprs.ints.items);

        // --- statements ---
        try testing.expectEqualSlices(u32, long.stmt_toks.items, seeded.stmt_toks.items);
        try expectDeepEqual(@TypeOf(long.stmts.items), long.stmts.items, seeded.stmts.items);

        // --- all four declaration arrays, to their leaves ---
        try expectDeepEqual(@TypeOf(long.modules), long.modules, seeded.modules);
        try expectDeepEqual(@TypeOf(long.disciplines), long.disciplines, seeded.disciplines);
        try expectDeepEqual(@TypeOf(long.natures), long.natures, seeded.natures);
        try expectDeepEqual(@TypeOf(long.paramsets), long.paramsets, seeded.paramsets);

        // --- the parser state that is not in the SourceFile ---
        // A dropped access name turns a §4.4.1 branch probe into a §4.7 function
        // call silently, so the set is compared both ways.
        try testing.expectEqual(lp.access_names.size, sp.access_names.size);
        var it = lp.access_names.keyIterator();
        while (it.next()) |k| try testing.expect(sp.access_names.contains(k.*));
        try testing.expectEqual(lp.pos, sp.pos);
        try testing.expectEqual(lp.gen_construct, sp.gen_construct);
        try testing.expectEqual(lp.failed, sp.failed);
        try testing.expectEqual(@as(usize, 0), lbag.list.items.len + sbag.list.items.len);
    }
}

test "an ABSTOL override reaches annex D.1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var bag: diag.Bag = .init(arena_state.allocator());
    const text = try process(
        arena_state.allocator(),
        "`define CURRENT_ABSTOL 1e-15\n`include \"disciplines.vams\"\n",
        .{ .std_defs = false, .bag = &bag },
    );
    try testing.expect(std.mem.indexOf(u8, text, "abstol      = 1e-15;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "abstol      = 1e-12;") == null);
}

test "a span inside an `include resolves to the included file's own line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "module m;\n`include \"disciplines.vams\"\nendmodule\n";
    const out = try process(arena, src, .{ .std_defs = false, .bag = &bag });

    // A byte that came from the included file.
    const needle = "discipline electrical;";
    const at: u32 = @intCast(std.mem.indexOf(u8, out, needle).?);
    const r = bag.map.resolve(at);
    try testing.expectEqualStrings("disciplines.vams", bag.fileName(r.file));
    try testing.expect(r.file != .root);

    // ... at ITS line number, not one measured in the preprocessed text.
    const want = std.mem.count(
        u8,
        disciplines_vams[0..std.mem.indexOf(u8, disciplines_vams, needle).?],
        "\n",
    ) + 1;
    const idx = try diag.LineIndex.build(arena, bag.fileText(r.file));
    try testing.expectEqual(@as(u32, @intCast(want)), idx.loc(r.offset).line);
    try testing.expectEqualStrings(
        needle,
        bag.fileText(r.file)[r.offset..][0..needle.len],
    );

    // ... while the top-level file still resolves to itself, at line 1.
    const top = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "module m;").?));
    try testing.expectEqual(diag.FileId.root, top.file);
    try testing.expectEqual(@as(u32, 0), top.offset);
    // ... and so does what follows the `include, despite the splice.
    const after = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "endmodule").?));
    try testing.expectEqual(diag.FileId.root, after.file);
    try testing.expectEqualStrings("endmodule\n", src[after.offset..]);
}

test "a diagnostic after a comment renders the ORIGINAL line at the ORIGINAL column" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bag: diag.Bag = .init(arena);

    // The error token sits AFTER a block comment on its line. Its span indexes
    // the STRIPPED text (the comment is one space there, so the '`' is at
    // stripped column 3); before the strip map, rendering printed the stripped
    // line — a line that appears nowhere in the file — and measured the column
    // in it. The map puts the caret on the line the user wrote, at column 25.
    const src = "/* a leading comment */ `NOPE\n";
    try testing.expectError(
        error.PreprocessFailed,
        process(arena, src, .{ .std_defs = false, .bag = &bag }),
    );
    try testing.expectEqual(@as(usize, 1), bag.count());
    try testing.expectEqual(diag.Code.E0115, bag.at(0).code);

    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    defer buf = aw.toArrayList();
    try diag.render(&bag, &aw.writer, .{ .explain_hint = false, .summary = false });
    const out = aw.writer.buffered();

    // The line drawn is the user's, comment included ...
    try testing.expect(std.mem.indexOf(u8, out, "| /* a leading comment */ `NOPE") != null);
    // ... the column is measured in it — the '`' is byte 24, column 25 ...
    try testing.expect(std.mem.indexOf(u8, out, ":1:25") != null);
    // ... and the caret row is indented to match: 24 spaces, then the span.
    try testing.expect(std.mem.indexOf(u8, out, "|                         ^^^^^") != null);
}

test "a span inside a macro expansion resolves to the invocation site" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bag: diag.Bag = .init(arena);
    const src = "`define SQ(x) ((x)*(x))\ny = `SQ(v) + 1;\n";
    const out = try process(arena, src, .{ .std_defs = false, .bag = &bag });

    // Bytes that exist only in the expansion have no counterpart in the file;
    // the honest answer is the `SQ that produced them.
    const inside: u32 = @intCast(std.mem.indexOfScalar(u8, out, '*').?);
    const r = bag.map.resolve(inside);
    try testing.expectEqual(diag.FileId.root, r.file);
    try testing.expect(std.mem.startsWith(u8, src[r.offset..], "`SQ(v)"));
    try testing.expectEqualStrings("SQ", bag.map.segs[r.seg].macro);

    // ... and the text after the expansion is verbatim again.
    const after = bag.map.resolve(@intCast(std.mem.indexOf(u8, out, "+ 1").?));
    try testing.expectEqualStrings("+ 1;\n", src[after.offset..]);
}
