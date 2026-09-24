//! Class 1 — Preprocessing & compiler directives.
//! LRM ch10 (§10.4 `define/`undef, §10.5 predefined macros, §10.7 `__FILE__/
//! `__LINE__ and the IEEE 1364 `line that remaps them, §10.2
//! `default_discipline), §2.4 (comments), §2.8.4 (directives), annex D.1
//! (disciplines.vams), annex D.2 (constants.vams).
//!
//! §10.1's Table 10-1 carry-overs live here too, and the ones with state past
//! their own line are published as `Region` event lists rather than applied:
//! IEEE 1364 §19.2 `default_nettype, §19.1 `celldefine, §19.9 `timescale and
//! §19.10 `unconnected_drive. What each one governs — whether a name may become
//! a net, whether a module is a cell, how a blank port connection is driven —
//! is a question only a later stage can ask, so this file parses the directive,
//! refuses a malformed one, and records WHERE it took effect.
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
//! gets the prelude length back via `Output.prelude_len` to compensate.
//!
//! PROVENANCE. The line-number contract above only ever held per file. This
//! stage therefore also publishes a `diag.SourceMap`: one `Segment` every time
//! the ORIGIN of the output changes (entering a file, returning from an
//! `include, starting a macro expansion) plus one after every directive,
//! because a directive that collapses to its newlines shortens the output
//! relative to its file and breaks the linear mapping the segment assumes.

const std = @import("std");
pub const Allocator = std.mem.Allocator;
const diag = @import("diag");
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
    /// Where diagnostics go, and where the file table and the source map are
    /// published. Required: preprocessing that nobody can hear is not useful.
    bag: *diag.Bag,
};

pub const Error = Allocator.Error || error{PreprocessFailed};

/// What `process` publishes. Arena-owned, like the text.
pub const Output = struct {
    /// The preprocessed bytes: the cache identity and the lexer's input.
    text: []const u8,
    /// Byte length of the prepended std-def prelude, so a caller mapping an
    /// output offset back to a user source line can subtract it.
    prelude_len: u32 = 0,
    /// How many modules `Options.spice_netlist` contributed, so the caller can
    /// tell the netlist-derived tail of the prelude from Table E.1's own rows —
    /// E.2.1's case-insensitive fallback applies to the tail only.
    netlist_modules: u32 = 0,
    directives: Directives = .{},
};

/// Every directive whose state outlives its own line, as the POSITIONAL event
/// list `Region` explains, in text-stream order. The text stage cannot apply
/// any of them — each governs a question only a later stage can ask — so it
/// says WHERE each took effect and the consumer looks its own offset up.
pub const Directives = struct {
    /// §10.2 `default_discipline, for §7.4 discipline resolution.
    disciplines: []const DefaultDiscipline = &.{},
    /// §10.3 `default_transition, for §4.5.8's rise/fall defaulting.
    transitions: []const DefaultTransition = &.{},
    /// IEEE 1364 §19.9 `timescale; a null value is §19.6's `resetall.
    timescales: []const TimescaleEvent = &.{},
    /// IEEE 1364 §19.2 `default_nettype, for §3.6.5 implicit-net creation
    /// (`Lower.rejectImplicitNet`).
    nettypes: []const NetTypeRegion = &.{},
    /// IEEE 1364 §19.1 `celldefine/`endcelldefine (`Mir.is_cell`).
    cells: []const CellRegion = &.{},
    /// IEEE 1364 §19.10 `unconnected_drive/`nounconnected_drive, for §6.2.2's
    /// blank port connections (`Lower.applyUnconnectedDrive`).
    drives: []const DriveRegion = &.{},

    /// The `timescale in force at the END of the stream, or null if none is.
    /// Read by §9.15 Table 9-27's "timeUnit" and "timePrecision", the only two
    /// rows of that table whose value comes out of the SOURCE.
    ///
    /// ponytail: the last one wins, so every module of one file shares it,
    /// although the directive scopes to the design elements that FOLLOW it.
    /// No fixture pins two modules with a `timescale between them (§9.6's tick
    /// has no analog kernel behind it — see E0908's note); look the module's
    /// own offset up with `TimescaleEvent.inForce` the day one does.
    pub fn timescale(self: Directives) ?Timescale {
        return if (self.timescales.len == 0) null else self.timescales[self.timescales.len - 1].value;
    }
};

/// Depth caps. Blown caps are reported as normal diagnostics, never panics.
pub const max_include_depth = 32;
pub const max_expansion_depth = 128;
/// `include file size cap.
pub const max_include_bytes = 1 << 24;

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
    default_nettype, // IEEE 1364 §19.2 — read by implicit-net creation
    celldefine, // IEEE 1364 §19.1 — cell membership, `endcelldefine closes it
    endcelldefine,
    unconnected_drive, // IEEE 1364 §19.10 — read by §6.2.2 port binding
    nounconnected_drive,
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
pub const Qualifier = enum { integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1 };

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
    /// Syntax 10-1's optional qualifier; null when the directive named none.
    qualifier: ?Qualifier,
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
///
/// `value` is seconds: §10.3's transition_time, used for BOTH the rise and the
/// fall.
pub const DefaultTransition = Region(?f64);

/// IEEE Std 1364 §19.9 `` `timescale <unit> / <precision> ``, in SECONDS.
///
/// The analog kernel has no tick — §9.10 `$abstime` is seconds whatever this
/// directive says, which ch10_directives/19 pins — so nothing here rescales a
/// time base. The directive is parsed for exactly one reason: §9.15 Table 9-27
/// makes both operands readable, "Time unit as specified in `timescale, in
/// seconds", and they are the only two rows of that table that are a property
/// of the SOURCE rather than of a simulator's preference file.
pub const TimescaleEvent = Region(?Timescale);

pub const Timescale = struct {
    unit: f64,
    precision: f64,
};

/// One POSITIONAL compiler directive: the point at which its value changed, and
/// the value it changed to.
///
/// §10.1 states the scope of EVERY directive in one sentence — "The scope of
/// compiler directives extends from the point where it is processed, across all
/// files processed, to the point where another compiler directive supersedes it
/// or the processing completes". "Across all files processed" is why nothing
/// here is reset at a file boundary: an `` `include `` is inlined into this
/// stream, so a directive inside one keeps acting on the text after it, and the
/// only thing that undoes it is another directive (or `` `resetall ``, which
/// writes a reset event like any other).
///
/// That sentence is why a single latched value is the wrong shape: it answers
/// the first directive or the last, never "the nearest one above THIS
/// declaration". `DefaultDiscipline` and `DefaultTransition` publish their own
/// version of this for the same reason; `DefaultTransition`, `TimescaleEvent`
/// and the three IEEE 1364 directives below are this one.
///
/// `at` is an offset into the PREPROCESSED output, the currency every later
/// stage reports in, so it compares directly against a token start.
pub fn Region(comptime T: type) type {
    return struct {
        at: u32,
        value: T,

        /// What this directive said at output offset `off`; `initial` is its
        /// value before the stream writes one (IEEE 1364 §19.6's "default
        /// value", the one `` `resetall `` returns it to).
        ///
        /// A backwards linear scan, not a binary search: the list holds one
        /// entry per directive OCCURRENCE in the file — single digits in every
        /// source anyone writes — and the answer is almost always the last one.
        /// ponytail: `std.sort.upperBound` over `at` the day a generated file
        /// carries thousands of them.
        pub fn inForce(events: []const @This(), off: u32, initial: T) T {
            var i = events.len;
            while (i > 0) {
                i -= 1;
                if (events[i].at <= off) return events[i].value;
            }
            return initial;
        }
    };
}

/// IEEE Std 1364 §19.2 `default_nettype_value` — the closed alternation
///
///   wire | tri | tri0 | tri1 | wand | triand | wor | trior | trireg
///   | uwire | none
///
/// `supply0`/`supply1` are deliberately absent: they are net types, but not
/// ones §19.2 lets an IMPLICIT net have, and §10.2's `qualifier` list (which
/// does include them) is a different production for a different directive.
///
/// `.none` is the member with semantics rather than a name: it withdraws
/// implicit nets outright, so an undeclared identifier used as a net is an
/// error instead of a silently-created wire.
pub const NetType = enum {
    wire,
    tri,
    tri0,
    tri1,
    wand,
    triand,
    wor,
    trior,
    trireg,
    uwire,
    none,

    /// IEEE 1364 §19.2: "If no `default_nettype directive is present or if the
    /// `resetall directive is used, implicit nets are of type wire."
    pub const default: NetType = .wire;
};

pub const NetTypeRegion = Region(NetType);

/// IEEE Std 1364 §19.1 `` `celldefine ``/`` `endcelldefine ``: whether the
/// design elements at this point are inside a cell. The directives "tag modules
/// as cell modules" and nothing more — the tag is metadata a tool reads (a
/// timing library, a `$dumpvars` filter), not a change to what the module
/// means — so what this publishes is the membership and no behaviour.
pub const CellRegion = Region(bool);

/// IEEE Std 1364 §19.10 `` `unconnected_drive pull1 | pull0 `` and
/// `` `nounconnected_drive ``: how an UNCONNECTED input port of a module
/// declared in this region is driven.
pub const Drive = enum {
    /// `` `nounconnected_drive ``, and the state before either directive: the
    /// port is left floating.
    float,
    pull0,
    pull1,

    pub const default: Drive = .float;
};

pub const DriveRegion = Region(Drive);

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
    // are parsed here and published (`Directives`, `Pp.line_*`).
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },
    .{ "default_transition", .default_transition }, // §10.3 — read by §4.5.8

    .{ "timescale", .timescale }, // IEEE 1364 §19.9 — §9.15 reads it back

    // The three IEEE 1364 directives that, like §10.2's, carry state past their
    // own line: §19.2 decides whether an undeclared name may become a net at
    // all, §19.1 tags the modules that follow, §19.10 drives their unconnected
    // inputs. All three are published as `Region` event lists.
    .{ "default_nettype", .default_nettype },
    .{ "celldefine", .celldefine },
    .{ "endcelldefine", .endcelldefine },
    .{ "unconnected_drive", .unconnected_drive },
    .{ "nounconnected_drive", .nounconnected_drive },

    // §10.1 lists `pragma, and IEEE 1364 §19.8 makes its content
    // implementation-defined ("a pragma ... may influence the tool"). VerA
    // defines no pragma, so every one of them is a directive it does not
    // recognize — which §19.8 says a tool "shall ignore".
    .{ "pragma", .ignored },
});

/// LRM §10.5. Defined for every compilation; `undef on these has no effect.
pub const predefined_macros = [_][]const u8{
    "__VAMS_ENABLE__",
    "__VAMS_COMPACT_MODELING__",
    // §10.5's third, and the only one whose SPELLING is the implementation's to
    // choose: "Verilog-AMS simulators shall also provide a predefined macro so
    // that the module can conditionally include (or exclude) portions of the
    // source text specific to a particular simulator. This macro shall be
    // documented in the Verilog-AMS section of the simulator manual."
    //
    // `shall`, so its absence was a conformance gap and not a policy decision:
    // a model carrying a VerA-specific workaround had no way to ask whether
    // VerA was compiling it. The name does not start with `__VAMS_`, which the
    // same clause reserves against user `define.
    "__VERA__",
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
    .{ "constants.vams", pp_annex_d.constants_vams },
    .{ "disciplines.vams", pp_annex_d.disciplines_vams },
    .{ "driver_access.vams", pp_annex_e.driver_access_vams },
});

/// Main entry. LRM ch10.
/// Strips comments (§2.4, preserving newline count), runs the conditional
/// stack, expands object- and function-like macros (§10.4), inlines `include,
/// and prepends the annex D standard definitions.
/// Returns arena-owned bytes; on failure adds to `opts.bag` and returns
/// `error.PreprocessFailed`.
pub fn process(arena: Allocator, source: []const u8, opts: Options) Error!Output {
    var pp: Pp = .{ .arena = arena, .opts = opts };

    // FIRST, so the compilation unit is `.root`. The prelude files register
    // after it, even though they are processed before it.
    const root = try opts.bag.addFile(opts.file_name, source);

    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }

    var netlist_modules: u32 = 0;
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
            netlist_modules = cards.modules;
        }
    }
    const prelude_len: u32 = @intCast(pp.out.items.len);

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

    const directives: Directives = .{
        .disciplines = try pp.defaults.toOwnedSlice(arena),
        .transitions = try pp.transitions.toOwnedSlice(arena),
        .timescales = try pp.timescale_events.toOwnedSlice(arena),
        .nettypes = try pp.nettypes.toOwnedSlice(arena),
        .cells = try pp.cells.toOwnedSlice(arena),
        .drives = try pp.drives.toOwnedSlice(arena),
    };
    opts.bag.map = .{
        .segs = try pp.segs.toOwnedSlice(arena),
        // ZERO, not the prelude's newline count: `prelude_lines` corrects a
        // root line number that was measured in the PREPROCESSED text, and the
        // segments above already resolve a root offset to root's own text.
        // Subtracting twice would put every user error ~100 lines too early.
        // `Output.prelude_len` still reports the byte length for callers that
        // slice the output themselves.
        .prelude_lines = 0,
    };
    return .{
        .text = try pp.out.toOwnedSlice(arena),
        .prelude_len = prelude_len,
        .netlist_modules = netlist_modules,
        .directives = directives,
    };
}

// The prelude snapshot: the Annex D/E definitions, preprocessed once and reused — pp/prelude.zig
const pp_prelude = @import("pp/prelude.zig");
pub const preludeTokens = pp_prelude.preludeTokens;
pub const preludeAst = pp_prelude.preludeAst;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

pub const Macro = struct {
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

pub const Pp = struct {
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
    /// The `Directives` lists, filled in text-stream order.
    defaults: std.ArrayList(DefaultDiscipline) = .empty,
    transitions: std.ArrayList(DefaultTransition) = .empty,
    timescale_events: std.ArrayList(TimescaleEvent) = .empty,
    nettypes: std.ArrayList(NetTypeRegion) = .empty,
    cells: std.ArrayList(CellRegion) = .empty,
    drives: std.ArrayList(DriveRegion) = .empty,
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

    pub fn emitting(pp: *const Pp) bool {
        const n = pp.conds.items.len;
        return n == 0 or pp.conds.items[n - 1].active;
    }

    /// Record that a positional directive changed to `value` HERE. The offset
    /// is the length of the output so far, which is where the directive's own
    /// collapsed text ends and the region it governs begins.
    pub fn mark(pp: *Pp, list: anytype, value: anytype) Allocator.Error!void {
        try list.append(pp.arena, .{ .at = @intCast(pp.out.items.len), .value = value });
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
    pub fn putNewlines(pp: *Pp, span: []const u8) Error!void {
        try pp.out.appendNTimes(pp.arena, '\n', std.mem.count(u8, span, "\n"));
    }

    /// A file-local span for `[start, end)` of the text being scanned.
    pub fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span {
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
    pub fn physicalLine(pp: *const Pp, at: usize) u32 {
        const off = pp.expand_site orelse @as(u32, @intCast(at));
        const text = pp.opts.bag.fileText(pp.cur_file_id);
        return @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n"));
    }

    pub fn currentLine(pp: *const Pp, at: usize) u32 {
        const phys = pp.physicalLine(at);
        const to = pp.line_to orelse return phys;
        // Saturating: a `line whose operand is smaller than the offset it
        // corrects for cannot produce a line 0, let alone a negative one.
        return if (phys >= pp.line_from) to + (phys - pp.line_from) else to;
    }

    /// Start a diagnostic. Preprocessor offsets are FILE-LOCAL — this stage
    /// fails before there is a preprocessed text to map them through.
    pub fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder {
        var b = pp.opts.bag.build(.preprocess, code, span);
        b.inFile(pp.cur_file_id);
        return b;
    }

    pub fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
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
    pub fn runStdDefs(pp: *Pp) Error!void {
        // annex D.2 first: disciplines.vams reads `*_ABSTOL overrides, and the
        // constants are pure directives (they contribute only newlines here).
        try pp.runFile(pp_annex_d.constants_vams, "constants.vams", null);
        try pp.runFile(pp_annex_d.disciplines_vams, "disciplines.vams", null);
        // Annex E after annex D.1: the primitives' ports are `electrical`, which
        // disciplines.vams declares, and the source rows read `M_TWO_PI, which
        // constants.vams defines. Before the user's source, so nothing the user
        // `defines can reach into a shipped standard file.
        try pp.runFile(pp_annex_e.spice_primitives, "spice_primitives.vams", null);
    }

    /// `runStdDefs`' result, `@memcpy`d out of the process-lifetime snapshot.
    /// Must leave `pp` in exactly the state `runStdDefs` would have.
    fn replayStdDefs(pp: *Pp) Error!void {
        const p = try pp_prelude.preludeSnapshot();
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
    pub fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: ?diag.FileId) Error!void {
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
        const s = try pp_comments.stripComments(pp, raw);
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
    pub fn joinChain(pp: *Pp, stack: []const []const u8, last: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (stack) |s| {
            try out.appendSlice(pp.arena, s);
            try out.appendSlice(pp.arena, " -> ");
        }
        try out.appendSlice(pp.arena, last);
        return out.items;
    }
};

// §2.4 comments: `//` and `/* */` removed, newlines kept — pp/comments.zig
const pp_comments = @import("pp/comments.zig");

// ---------------------------------------------------------------------------
// Main scan
// ---------------------------------------------------------------------------

/// The three bytes `scan` branches on: a §2.7 string, a §2.8.1 escaped
/// identifier, and a §10 directive or macro use. Everything else is ordinary.
pub const scan_stops = "\"\\`";

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
pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
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
pub fn scan(pp: *Pp, text: []const u8) Error!void {
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
pub fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize {
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
        return pp_macro.expand(pp, text, at, j, text[body..j]);
    }

    while (j < text.len and isIdentChar(text[j])) j += 1;
    if (j == name_start) {
        if (!pp.emitting()) return at + 1;
        return pp.fail(pp.spanAt(at, at + 1), .E0103, "", .{});
    }
    const name = text[name_start..j];

    const kind = directive_map.get(name) orelse return pp_macro.expand(pp, text, at, j, name);

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
        .define => try pp_macro.handleDefine(pp, text[j..end], at, j),
        .undef => try pp_macro.removeDefine(pp, text[j..end], at, j),
        .include => try pp_directive.handleInclude(pp, text[j..end], at, j),
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
                .qualifier = null,
                .discipline = "",
            });
            // IEEE 1364 §19.6: `resetall returns every directive to its default
            // value, and `timescale's default is "none specified" — which is
            // what §9.15 answers "not known" for.
            try pp.mark(&pp.timescale_events, null);
            // The same §19.6 sentence, for the three directives that publish a
            // `Region`. Written as ordinary events rather than by clearing the
            // lists, because the lists are POSITIONAL: a `resetall halfway down
            // a file must not unsay what the directive above it did to the text
            // above it. IEEE 1364 spells each default out — §19.2 "implicit
            // nets are of type wire", §19.1's tag applies only between the pair,
            // §19.10's pull only until `nounconnected_drive.
            try pp.mark(&pp.nettypes, NetType.default);
            try pp.mark(&pp.cells, false);
            try pp.mark(&pp.drives, Drive.default);
        },
        .default_discipline => try pp_directive.handleDefaultDiscipline(pp, text[j..end], j),
        .default_transition => try pp_directive.handleDefaultTransition(pp, text[j..end], j),
        .line => try pp_directive.handleLine(pp, text[j..end], at, j),
        .timescale => try pp_directive.handleTimescale(pp, text[j..end], j),
        .default_nettype => try pp_directive.handleDefaultNettype(pp, text[j..end], j),
        .unconnected_drive => try pp_directive.handleUnconnectedDrive(pp, text[j..end], j),
        // IEEE 1364 §19.1 and §19.10's closing half take no operand at all, so
        // there is nothing to parse and nothing to get wrong. Anything written
        // after them is on the directive's own line and collapses with it.
        .celldefine => try pp.mark(&pp.cells, true),
        .endcelldefine => try pp.mark(&pp.cells, false),
        .nounconnected_drive => try pp.mark(&pp.drives, .float),
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

// §10.4 `define, `undef and macro expansion — pp/macro.zig
const pp_macro = @import("pp/macro.zig");

// `include (§10.3), §10.2 `default_discipline and friends, IEEE 1364 §19.7 `line — pp/directive.zig
const pp_directive = @import("pp/directive.zig");

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Stop on a closing quote, an unescaped newline, or EOF; `start` is the opener.
// ponytail: share the three identical scans. The lexer rejects escaped newlines
// and `substitute` crosses bare ones; reuse either only if those rules converge.
pub fn stringStop(text: []const u8, start: usize) usize {
    var i = start + 1;
    while (i < text.len and text[i] != '"' and text[i] != '\n') {
        if (text[i] == '\\' and i + 1 < text.len) i += 1;
        i += 1;
    }
    return i;
}

/// Cursor over the tail of a directive line.
pub const Rest = struct {
    s: []const u8,
    i: usize = 0,

    pub fn peek(r: *const Rest) ?u8 {
        return if (r.i < r.s.len) r.s[r.i] else null;
    }
    pub fn skipSpace(r: *Rest) void {
        while (r.i < r.s.len and isSpace(r.s[r.i])) r.i += 1;
    }
    /// Next §2.8.1 escaped identifier, skipping leading whitespace. Neither
    /// the backslash nor the terminating white space is part of the name, so
    /// the macro is keyed on the same bytes a `` `\name `` use produces.
    pub fn escapedIdent(r: *Rest) ?[]const u8 {
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
    pub fn ident(r: *Rest) ?[]const u8 {
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

pub fn indexOfString(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |s, k| {
        if (std.mem.eql(u8, s, needle)) return k;
    }
    return null;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c;
}
pub fn isIdentStart(c: u8) bool {
    // ponytail: stdlib ASCII classes; `_` and `$` are Verilog's extensions.
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// Annex D standard definitions: disciplines.vams and constants.vams, transcribed verbatim — pp/annex_d.zig
const pp_annex_d = @import("pp/annex_d.zig");

// Annex E Table E.1: the SPICE primitives, as ordinary Verilog-A modules — pp/annex_e.zig
const pp_annex_e = @import("pp/annex_e.zig");
pub const spice_primitives = pp_annex_e.spice_primitives;
pub const spice_module_count = pp_annex_e.spice_module_count;

// Preprocessor self-checks: source in, expanded text and diagnostics out — pp/test.zig
const pp_test = @import("pp/test.zig");

test {
    _ = pp_prelude;
    _ = pp_comments;
    _ = pp_macro;
    _ = pp_directive;
    _ = pp_annex_d;
    _ = pp_annex_e;
    _ = pp_test;
}
