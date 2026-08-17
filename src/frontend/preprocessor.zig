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
//! macro name (cold — touched only at directive sites, not per-token).
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

pub const Options = struct {
    /// Searched in order for `include, before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Used in diagnostics only.
    file_name: []const u8 = "<source>",
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams.
    std_defs: bool = true,
    /// Out-param: byte length of the prepended std-def prelude, so a caller
    /// mapping an output offset back to a user source line can subtract it.
    prelude_len: ?*u32 = null,
    /// Out-param: every §10.2 `default_discipline event, in text-stream order,
    /// for §7.4 discipline resolution to consult. Arena-owned like the output.
    defaults: ?*[]const DefaultDiscipline = null,
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

    // Accepted but intentionally ignored (consumed to end of line).
    .{ "default_transition", .ignored }, // §10.3  GAP: default rise/fall not retained
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
        // annex D.2 first: disciplines.vams reads `*_ABSTOL overrides, and the
        // constants are pure directives (they contribute only newlines here).
        try pp.runFile(constants_vams, "constants.vams", null);
        try pp.runFile(disciplines_vams, "disciplines.vams", null);
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
    /// `include stack, innermost last. Its depth IS the include depth.
    includes: std.ArrayList([]const u8) = .empty,
    /// Provenance of the output so far. Appended to only, so it stays sorted
    /// by `out_start` and `SourceMap.resolve` can binary-search it.
    segs: std.ArrayList(diag.Segment) = .empty,
    /// §10.2 events, in text-stream order. Published via `Options.defaults`.
    defaults: std.ArrayList(DefaultDiscipline) = .empty,
    /// IEEE 1364 §19.9. Last one wins rather than a positional event list like
    /// `defaults`: the directive scopes to the design elements that FOLLOW it,
    /// and VerA elaborates exactly one module, so the last `timescale before
    /// end of stream is the one in force for it.
    // ponytail: make it an event list the day VerA compiles two modules at once.
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

    fn put(pp: *Pp, bytes: []const u8) Error!void {
        try pp.out.appendSlice(pp.arena, bytes);
    }

    fn putNewlines(pp: *Pp, span: []const u8) Error!void {
        for (span) |c| if (c == '\n') try pp.out.append(pp.arena, '\n');
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

    /// §10.7 `__FILE__`: "the name of the current input file". The clause makes
    /// the spelling "implementation dependent" and says a `line directive may
    /// replace it, so the override wins when there is one.
    fn currentFileName(pp: *const Pp) []const u8 {
        return pp.file_override orelse pp.opts.bag.fileName(pp.cur_file_id);
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
        // repointed: every offset after this indexes the stripped text.
        const text = try stripComments(pp, raw);
        pp.opts.bag.setFileText(id, text);

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

/// Replace `//`- and `/* */`-comments with nothing, keeping every newline they
/// contained so line numbers survive. String literals (§2.7) are opaque.
/// Block comments do NOT nest (§2.4) — `/* a /* b */` ends at the first `*/`.
fn stripComments(pp: *Pp, src: []const u8) Error![]const u8 {
    // Fast path: most sources shrink, none grow.
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, src.len);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const start = i;
            i += 1;
            // §2.7: an unterminated literal is the lexer's error to report; stop
            // at the newline so the rest of the file still preprocesses.
            while (i < src.len and src[i] != '"' and src[i] != '\n') {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
                i += 1;
            }
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
            while (i < src.len and src[i] != '\n') i += 1;
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
            var lines: usize = 0;
            for (src[start..i]) |b| {
                if (b != '\n') continue;
                out.appendAssumeCapacity('\n');
                lines += 1;
            }
            if (lines == 0) out.appendAssumeCapacity(' ');
            i += 2;
            continue;
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Main scan
// ---------------------------------------------------------------------------

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
            i += 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
                i += 1;
            }
            if (i < text.len and text[i] == '"') i += 1;
            if (pp.emitting()) {
                try pp.put(text[start..i]);
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
            if (pp.emitting()) try pp.put(text[start..i]);
            continue;
        }

        if (c == '`') {
            i = try directive(pp, text, i);
            try pp.resync(i);
            continue;
        }

        if (!pp.emitting()) {
            if (c == '\n') try pp.out.append(pp.arena, '\n');
            i += 1;
            continue;
        }
        try pp.out.append(pp.arena, c);
        i += 1;
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
        // IEEE 1364 `resetall: back to the initial directive state. Only macros
        // are stateful here, and §10.5 predefined ones are not user state.
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
        .line => try handleLine(pp, text[j..end], at, j),
        .timescale => handleTimescale(pp, text[j..end]),
        .ignored => {},
        // §10.6: passed through instead of being blanked out, so the lexer and
        // parser see it. The slice carries its own newlines, so the
        // line-number contract in the file header holds unchanged.
        .keywords => {
            try pp.put(text[at..end]);
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
            const macro = r.ident() orelse
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
                const macro = r.ident() orelse
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
    const name = r.ident() orelse return pp.fail(pp.spanAt(at, off), .E0113, "", .{});
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
            try pp.put(std.fmt.bufPrint(&buf, "{d}", .{pp.currentLine(at)}) catch unreachable);
            return after_name;
        }
        if (std.mem.eql(u8, name, "__FILE__")) {
            // "in the form of a string literal" — §2.7, so the quotes are part
            // of the expansion and a '"' or '\' in the path has to be escaped
            // or the literal ends early (Windows paths are full of the latter).
            try pp.put("\"");
            for (pp.currentFileName()) |c| {
                if (c == '"' or c == '\\') try pp.put("\\");
                try pp.out.append(pp.arena, c);
            }
            try pp.put("\"");
            return after_name;
        }
        var b = pp.failWith(sp, .E0115);
        b.msg("`{s}", .{name});
        if (diag.didYouMeanMap(pp.arena, name, pp.macros)) |near| {
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
    if (pp.expanding.items.len >= max_expansion_depth)
        return pp.fail(sp, .E0119, "limit is {d}", .{max_expansion_depth});

    const body = if (m.is_func) try substitute(pp, m.body, m.params, args) else m.body;

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

const MacroArgs = struct { args: []const []const u8, end: usize };

/// Splits a top-level comma list starting at the '(' at `lparen`. Nested
/// (), [], {} and string literals are opaque.
fn macroArgs(pp: *Pp, text: []const u8, lparen: usize, at: usize, name: []const u8) Error!MacroArgs {
    var args: std.ArrayList([]const u8) = .empty;
    var depth: u32 = 0;
    var i = lparen;
    var arg_start = lparen + 1;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"' and text[i] != '\n') {
                    if (text[i] == '\\' and i + 1 < text.len) i += 1;
                    i += 1;
                }
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) {
                    try args.append(pp.arena, std.mem.trim(u8, text[arg_start..i], " \t\r\n"));
                    return .{ .args = args.items, .end = i + 1 };
                }
            },
            ',' => if (depth == 1) {
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
    // Both operands are optional; the bare form WITHDRAWS the default.
    const disc = r.ident() orelse "";
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
    /// Next §2.8.1 escaped identifier, skipping leading whitespace. Null (and
    /// the cursor untouched) if the next character is not a backslash. Neither
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
            k += 1;
            continue;
        }
        if (text[k] == '\n') return k;
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
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// ---------------------------------------------------------------------------
// Annex D standard definitions (transcribed verbatim from docs/VAMS-LRM/annex-d-stddefs.html)
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
