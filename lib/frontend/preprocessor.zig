//! Preprocessor: raw source text and include dirs in, preprocessed text out,
//! with comments stripped (newlines kept), macros expanded, `include inlined,
//! and each directive whose state outlives its line published as an event list.
//! LRM §2.4, §10.1-§10.7, annex D; IEEE 1364 §19.1-§19.10.
//! Every deleted byte leaves its newlines behind, and a `diag.SourceMap` maps
//! each output offset back to its file, include or macro origin.

const std = @import("std");
pub const Allocator = std.mem.Allocator;
const diag = @import("diag");
/// Annex E.2 `.MODEL`/`.SUBCKT` reader; its modules follow the prelude.
const spice_cards = @import("spice_cards.zig");

/// Inputs to `process`. Every slice is borrowed for the call.
pub const Options = struct {
    /// Searched in order for `include, before the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Name the compilation unit is registered under; `__FILE__` expands to it.
    file_name: []const u8 = "<source>",
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams.
    std_defs: bool = true,
    /// Annex E.2 SPICE netlist text, one card per line. Each `.MODEL` and
    /// `.SUBCKT` becomes a module appended after the Table E.1 prelude; empty
    /// appends nothing. Read only with `std_defs`, because a model card's
    /// interface comes from a Table E.1 primitive.
    spice_netlist: []const u8 = "",
    /// Receives diagnostics, the file table and the source map.
    bag: *diag.Bag,
};

/// `PreprocessFailed` means the diagnostic is already in `Options.bag`.
pub const Error = Allocator.Error || error{PreprocessFailed};

/// What `process` publishes. Every slice is owned by the caller's arena.
pub const Output = struct {
    /// The preprocessed bytes, the lexer's input.
    text: []const u8,
    /// How many modules `Options.spice_netlist` contributed. E.2.1's
    /// case-insensitive fallback applies to this tail of the prelude only.
    netlist_modules: u32 = 0,
    directives: Directives = .{},
};

/// Every directive whose state outlives its own line, as `Region` event lists
/// in text-stream order. Only a later stage can apply them, so each consumer
/// looks up its own output offset.
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

    /// Returns the `timescale in force at the end of the stream, or null if
    /// none is. Read by §9.15 Table 9-27's "timeUnit" and "timePrecision".
    ///
    /// ponytail: the last one wins, so every module of one file shares it,
    /// although the directive scopes to the design elements that follow it.
    /// Look the module's own offset up with `TimescaleEvent.inForce` once a
    /// fixture puts a `timescale between two modules.
    pub fn timescale(self: Directives) ?Timescale {
        return if (self.timescales.len == 0) null else self.timescales[self.timescales.len - 1].value;
    }
};

/// Nesting limits; exceeding one is a diagnostic (E0125, E0119), not a panic.
pub const max_include_depth = 32;
pub const max_expansion_depth = 128;
/// Largest `include file read, in bytes.
pub const max_include_bytes = 1 << 24;

/// Directives handled here. LRM §10 Table 10-1.
pub const Directive = enum {
    define, // §10.4
    undef, // §10.4
    ifdef, // IEEE 1364 §19.4
    ifndef, // IEEE 1364 §19.4
    elsif, // IEEE 1364 §19.4
    @"else", // IEEE 1364 §19.4
    endif, // IEEE 1364 §19.4
    include, // IEEE 1364 §19.5
    resetall, // IEEE 1364 §19.6: directive state only; §19.3 keeps macros
    keywords, // §10.6: emitted verbatim, handled by the parser
    default_discipline, // §10.2: parsed here, applied by discipline resolution
    default_transition, // §10.3: parsed here, applied by §4.5.8 codegen
    line, // IEEE 1364 §19.7: remaps §10.7 `__LINE__` / `__FILE__`
    timescale, // IEEE 1364 §19.9: read back by §9.15 Table 9-27
    default_nettype, // IEEE 1364 §19.2: read by implicit-net creation
    celldefine, // IEEE 1364 §19.1: cell membership, `endcelldefine closes it
    endcelldefine,
    unconnected_drive, // IEEE 1364 §19.10: read by §6.2.2 port binding
    nounconnected_drive,
    pragma, // IEEE 1364 §19.10: no effect, except §28's `protect` (E0146)
};

/// §10.2 Syntax 10-1:
///
///   default_discipline_directive ::=
///       `default_discipline [ discipline_identifier [ qualifier ] ]
///   qualifier ::= integer | real | reg | wreal | wire | tri | wand | triand
///               | wor | trior | trireg | tri0 | tri1 | supply0 | supply1
///
/// A closed list of fifteen names, so anything else in that slot is a syntax
/// error, not a second discipline (E0127).
pub const Qualifier = enum { integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1 };

/// One `default_discipline, or the `resetall or bare form that withdraws one.
/// §10.2 applies it "to all discrete signals without a discipline declaration
/// that appear in the text stream following the use of the directive", so §7.4
/// discipline resolution looks each net's declaration offset up against the
/// events.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub const DefaultDiscipline = struct {
    at: u32,
    /// Syntax 10-1's optional qualifier; null when the directive named none.
    qualifier: ?Qualifier,
    /// "" withdraws every default in force from `at` on. §10.2: "In addition
    /// to `resetall, if this directive is used without a discipline name,
    /// discipline resolution will not use a default discipline for nets
    /// declared after this directive is encountered in the text stream."
    discipline: []const u8,
};

/// One §10.3 `` `default_transition ``. `value` is the transition time in
/// seconds, used for both rise and fall; null after `resetall. A filter takes
/// its default from "the directive which immediately precedes the transition
/// filter" (§10.3), which is `Region.inForce` at the filter's offset.
pub const DefaultTransition = Region(?f64);

/// One IEEE 1364 §19.9 `` `timescale <unit> / <precision> ``; null after
/// `resetall. Nothing rescales time (§9.10 `$abstime` is always seconds); the
/// operands exist to be read back by §9.15 Table 9-27.
pub const TimescaleEvent = Region(?Timescale);

/// A `timescale's two operands, in seconds.
pub const Timescale = struct {
    unit: f64,
    precision: f64,
};

/// One positional directive event: the output offset where its value changed,
/// and the new value.
///
/// §10.1: "The scope of compiler directives extends from the point where it is
/// processed, across all files processed, to the point where another compiler
/// directive supersedes it or the processing completes." So nothing resets at
/// a file boundary, and only another directive (including `resetall, which
/// writes an event like any other) ends a region.
///
/// `at` is an offset into the preprocessed output, the unit every later stage
/// reports in, so it compares directly against a token start.
pub fn Region(comptime T: type) type {
    return struct {
        at: u32,
        value: T,

        /// Returns the value in force at output offset `off`, or `initial` (IEEE
        /// 1364 §19.6's default value) before the first event. O(events).
        ///
        /// ponytail: backwards linear scan, one entry per directive occurrence;
        /// `std.sort.upperBound` over `at` if a generated file carries thousands.
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

/// IEEE 1364 §19.2 `default_nettype_value`, a closed list. `supply0` and
/// `supply1` are net types but not ones §19.2 lets an implicit net have.
/// `.none` withdraws implicit nets, so an undeclared identifier used as a net
/// is an error instead of a new wire.
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

/// IEEE 1364 §19.1 `` `celldefine ``/`` `endcelldefine ``: whether the design
/// elements at this point are cell modules. The tag is metadata only; it does
/// not change what a module means.
pub const CellRegion = Region(bool);

/// IEEE 1364 §19.10 `` `unconnected_drive pull1 | pull0 `` and
/// `` `nounconnected_drive ``: how an unconnected input port of a module
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

/// Directive name, without its backtick, to kind.
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

    // §10.6: which annex B words are reserved, and whether the directive sits
    // "outside of a design element", are parse-time questions. Emitted verbatim
    // so the lexer can tag them (`dir_begin_keywords`) and the parser can act.
    .{ "begin_keywords", .keywords },
    .{ "end_keywords", .keywords },

    // §10.2 and IEEE 1364 §19.7: both carry state past their own line, so both
    // are parsed here and published (`Directives`, `Pp.line_*`).
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },
    .{ "default_transition", .default_transition }, // §10.3, read by §4.5.8

    .{ "timescale", .timescale }, // IEEE 1364 §19.9, read back by §9.15

    // The three IEEE 1364 directives that, like §10.2's, carry state past their
    // own line: §19.2 decides whether an undeclared name may become a net at
    // all, §19.1 tags the modules that follow, §19.10 drives their unconnected
    // inputs. All three are published as `Region` event lists.
    .{ "default_nettype", .default_nettype },
    .{ "celldefine", .celldefine },
    .{ "endcelldefine", .endcelldefine },
    .{ "unconnected_drive", .unconnected_drive },
    .{ "nounconnected_drive", .nounconnected_drive },

    // §10.1 lists `pragma and IEEE 1364 §19.10 leaves its content to the tool.
    // VerA defines no pragma, and §19.10 says an unrecognized one "shall have
    // no effect".
    .{ "pragma", .pragma },
});

/// LRM §10.5. Defined for every compilation; `undef on these has no effect.
pub const predefined_macros = [_][]const u8{
    "__VAMS_ENABLE__",
    "__VAMS_COMPACT_MODELING__",
    // §10.5: "Verilog-AMS simulators shall also provide a predefined macro so
    // that the module can conditionally include (or exclude) portions of the
    // source text specific to a particular simulator." The spelling is ours;
    // it avoids the `__VAMS_` prefix §10.4 reserves.
    "__VERA__",
};

/// Built-in annex D files, resolvable by `include even with no include_dirs.
/// All three are self-guarded, so an explicit `include after the prelude
/// expands to nothing. Only D.1 and D.2 are preloaded (see `process`); D.3
/// driver_access.vams must be included.
pub const builtin_includes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "constants.vams", pp_annex_d.constants_vams },
    .{ "disciplines.vams", pp_annex_d.disciplines_vams },
    .{ "driver_access.vams", pp_annex_e.driver_access_vams },
});

/// Preprocesses `source`: strips comments (§2.4, newlines kept), runs the
/// conditionals, expands macros (§10.4), inlines `include, and prepends the
/// annex D and Table E.1 definitions when `opts.std_defs` is set.
///
/// Registers `source` as the bag's `.root` file, so the bag must be empty.
/// Sets `opts.bag.map`. Returns arena-owned output; on failure the diagnostic
/// is in `opts.bag` and the error is `error.PreprocessFailed`.
pub fn process(arena: Allocator, source: []const u8, opts: Options) Error!Output {
    var pp: Pp = .{ .arena = arena, .opts = opts };

    // First, so the compilation unit is `.root`. The prelude files register
    // after it, even though they are processed before it.
    const root = try opts.bag.addFile(opts.file_name, source);

    for (predefined_macros) |name| {
        try pp.macros.put(arena, name, .{ .body = "1", .predefined = true });
    }

    var netlist_modules: u32 = 0;
    if (opts.std_defs) {
        // Replayed from the process-lifetime snapshot (`Prelude`), which
        // pp/test.zig checks against a fresh `runStdDefs`.
        try pp.replayStdDefs();
        // Annex E.2 after Table E.1: a `.MODEL` wrapper instantiates the
        // primitive its type names, so the primitive has to be declared first.
        const cards = try spice_cards.synthesize(arena, opts.spice_netlist);
        if (cards.modules != 0) {
            try pp.runFile(cards.text, "spice_netlist.vams", null);
            netlist_modules = cards.modules;
        }
    }

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
    opts.bag.map = .{ .segs = try pp.segs.toOwnedSlice(arena) };
    return .{
        .text = try pp.out.toOwnedSlice(arena),
        .netlist_modules = netlist_modules,
        .directives = directives,
    };
}

// The annex D/E prelude, preprocessed once per process (pp/prelude.zig).
const pp_prelude = @import("pp/prelude.zig");
pub const preludeTokens = pp_prelude.preludeTokens;
pub const preludeAst = pp_prelude.preludeAst;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// One `define (§10.4).
pub const Macro = struct {
    /// Empty and `is_func == false` means an object-like macro.
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
    /// Some arm of this level was taken, so later `elsif/`else are dead.
    taken: bool,
    seen_else: bool = false,
    /// The `ifdef that opened this level, for E0101's label.
    span: diag.Span = .{},
    file: diag.FileId = .root,
};

/// Preprocessor state for one compilation. Everything is allocated on `arena`.
pub const Pp = struct {
    arena: Allocator,
    opts: Options,
    out: std.ArrayList(u8) = .empty,
    macros: std.StringHashMapUnmanaged(Macro) = .empty,
    conds: std.ArrayList(Cond) = .empty,
    /// Macro-expansion cycle guard (§10.4): names currently being expanded.
    expanding: std.ArrayList([]const u8) = .empty,
    /// Live `expand` calls, argument pre-expansion included. E0119 bounds this
    /// and not `expanding.items.len`, because pre-expansion runs before the
    /// name is pushed and `` `M(`M(`M(... `` would otherwise recurse unbounded.
    expand_depth: u32 = 0,
    /// `include stack, innermost last; its length is the include depth.
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
    /// IEEE 1364 §19.7 `line remap for §10.7 `__LINE__`; `line_to` is null when
    /// the current file is numbered naturally. `line_from` is the physical
    /// 1-based line after the directive and `line_to` the number §19.7 gives
    /// it, so a later line L reports `to + (L - from)`. Per file: `runFile`
    /// saves and restores both, as §10.7 requires at the end of an `include.
    line_from: u32 = 0,
    line_to: ?u32 = null,
    /// The `line directive's file name, which §10.7 lets replace `__FILE__`.
    /// Null means the current file's real name.
    file_override: ?[]const u8 = null,
    /// The file the current offsets belong to.
    cur_file_id: diag.FileId = .root,
    /// The outermost invocation's offset while a macro body is rescanned.
    /// Offsets inside a body index no file, so diagnostics there report here.
    expand_site: ?u32 = null,

    /// Returns whether every enclosing conditional arm is active.
    pub fn emitting(pp: *const Pp) bool {
        const n = pp.conds.items.len;
        return n == 0 or pp.conds.items[n - 1].active;
    }

    /// Appends an event to `list` at the current output length, which is where
    /// the directive's own collapsed text ends and its region begins.
    pub fn mark(pp: *Pp, list: anytype, value: anytype) Allocator.Error!void {
        try list.append(pp.arena, .{ .at = @intCast(pp.out.items.len), .value = value });
    }

    /// Emits only the newlines in `span`, so dropped text (a dead `ifdef arm,
    /// a collapsed directive) keeps the output's line count.
    pub fn putNewlines(pp: *Pp, span: []const u8) Error!void {
        // Count-then-fill: a one-byte-needle `std.mem.count` is vectorized.
        try pp.out.appendNTimes(pp.arena, '\n', std.mem.count(u8, span, "\n"));
    }

    /// Returns a file-local span for `[start, end)` of the text being scanned,
    /// or the invocation site inside a macro body.
    pub fn spanAt(pp: *const Pp, start: usize, end: usize) diag.Span {
        if (pp.expand_site) |s| return .at(s);
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    /// Returns the physical 1-based line of `at` in the current file, or of the
    /// invocation site inside a macro body. O(offset): counts newlines.
    pub fn physicalLine(pp: *const Pp, at: usize) u32 {
        const off = pp.expand_site orelse @as(u32, @intCast(at));
        const text = pp.opts.bag.fileText(pp.cur_file_id);
        return @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n"));
    }

    /// Returns §10.7 `__LINE__` at `at`: the physical line, remapped by an
    /// IEEE 1364 §19.7 `line when one is in force.
    pub fn currentLine(pp: *const Pp, at: usize) u32 {
        const phys = pp.physicalLine(at);
        const to = pp.line_to orelse return phys;
        // Saturating: a `line whose operand is smaller than the offset it
        // corrects for cannot produce a line 0, let alone a negative one.
        return if (phys >= pp.line_from) to + (phys - pp.line_from) else to;
    }

    /// Starts a diagnostic in the current file. Preprocessor spans are
    /// file-local, since no preprocessed text exists yet to map them through.
    pub fn failWith(pp: *Pp, span: diag.Span, code: diag.Code) diag.Builder {
        var b = pp.opts.bag.build(.preprocess, code, span);
        b.inFile(pp.cur_file_id);
        return b;
    }

    /// Emits `code` at `span` and returns `error.PreprocessFailed` to propagate.
    pub fn fail(pp: *Pp, span: diag.Span, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        var b = pp.failWith(span, code);
        b.msg(fmt, args);
        try b.emit();
        return error.PreprocessFailed;
    }

    /// Records that the output continues from `at` in the current file. Called
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

    /// Preprocesses annex D.2, D.1 and Table E.1 into `pp`. Called once per
    /// process by `buildPrelude`, and by the snapshot equivalence test.
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

    /// Copies `runStdDefs`' result out of the process-lifetime snapshot. Must
    /// leave `pp` in exactly the state `runStdDefs` would.
    fn replayStdDefs(pp: *Pp) Error!void {
        const p = try pp_prelude.preludeSnapshot();
        for (p.files, 1..) |f, want_id| {
            const id = try pp.opts.bag.addFile(f.name, f.raw);
            // `Prelude.segs` names files by index, so the three must land at
            // 1, 2, 3: only the compilation unit (`.root`) is registered yet.
            std.debug.assert(@intFromEnum(id) == want_id);
            // Same state `runFile` leaves: spans index the stripped text and the
            // renderer maps back to the raw text through the marks.
            pp.opts.bag.setStrippedText(id, f.stripped, f.marks);
        }
        try pp.out.appendSlice(pp.arena, p.text);
        try pp.segs.appendSlice(pp.arena, p.segs);
        for (p.macros) |d| try pp.macros.put(pp.arena, d.name, d.macro);
    }

    /// Registers `raw`, strips its comments and scans it. Saves and restores
    /// the file context, so an error inside an `include names the right file.
    /// `existing` is the id of an already-registered file (the compilation
    /// unit), or null to register a new one.
    pub fn runFile(pp: *Pp, raw: []const u8, file: []const u8, existing: ?diag.FileId) Error!void {
        const saved_id = pp.cur_file_id;
        defer pp.cur_file_id = saved_id;

        // §10.7: at the end of an included file "the expansions of `__FILE__
        // and `__LINE__ revert to the values they had before the `include".
        // `__LINE__` derives from a physical offset, so restoring the remap is
        // all that takes.
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

        // Registered raw first so a stripComments failure resolves, then
        // repointed: every later offset indexes the stripped text.
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

    /// Returns `stack` and `last` joined as `A -> B -> C`, arena-owned.
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

// §2.4 comment stripping (pp/comments.zig).
const pp_comments = @import("pp/comments.zig");

// ---------------------------------------------------------------------------
// Main scan
// ---------------------------------------------------------------------------

/// The three bytes `scan` branches on: a §2.7 string, a §2.8.1 escaped
/// identifier, and a §10 directive or macro use. Everything else is ordinary.
pub const scan_stops = "\"\\`";

/// Returns the first index at or after `from` whose byte is in `stops`, else
/// `text.len`.
pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
    // `std.mem.indexOfAnyPos` is a scalar loop per (byte, needle); only
    // single-needle searches are vectorized in std. So: splat each stop and OR
    // the compare masks. Most scanned bytes sit in runs of 32 or more, so this
    // pays even though the median run is shorter. The scalar loop below is the
    // tail, the no-vector fallback, and the reference pp/test.zig checks.
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

/// Copies comment-stripped `text` to `pp.out`, handling directives (§10) and
/// macro uses (§10.4). An inactive conditional arm emits only its newlines.
pub fn scan(pp: *Pp, text: []const u8) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // §2.7 strings are opaque to macro expansion and to directives.
        if (c == '"') {
            const start = i;
            i = stringStop(text, i);
            const closed = i < text.len and text[i] == '"';
            if (closed) i += 1;
            if (pp.emitting()) {
                try pp.out.appendSlice(pp.arena, text[start..i]);
            } else {
                // IEEE 1364 §19.4: an ignored group "shall still follow the
                // Verilog HDL lexical conventions"; an emitted one is the
                // lexer's to check.
                // ponytail: of those conventions, only §3.6's one-line string
                // is checked here.
                if (!closed) return pp.fail(pp.spanAt(start, i), .E0138, "", .{});
                try pp.putNewlines(text[start..i]);
            }
            continue;
        }

        // §2.8.1 escaped identifiers are opaque too (they may contain '`').
        if (c == '\\') {
            const start = i;
            i = escapedEnd(text, i + 1);
            if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[start..i]);
            continue;
        }

        if (c == '`') {
            i = try directive(pp, text, i);
            try pp.resync(i);
            continue;
        }

        // Ordinary text up to the next byte the branches above care about.
        // '\n' is not a stop: `putNewlines` counts it in a dead arm. '/' is
        // not either, since no comment survives `stripComments`.
        const end = findStop(text, i, scan_stops);
        if (pp.emitting()) try pp.out.appendSlice(pp.arena, text[i..end]) else try pp.putNewlines(text[i..end]);
        // `text[i]` is none of the three, so `end > i`: the loop always moves.
        i = end;
    }
}

/// Handles the directive or macro use whose '`' is at `at`. Returns the offset
/// to resume scanning from.
pub fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize {
    const name_start = at + 1;
    var j = name_start;

    // §2.8.1 escaped identifier: `\` then printable ASCII, ended by white
    // space, with neither the backslash nor the terminator part of the name.
    // Syntax 10-3 makes text_macro_identifier an `identifier` (A.9.3: simple
    // or escaped), so a use may be spelled `` `\MY-GAIN ``. No compiler
    // directive is spelled with a backslash, so this can only be a macro use
    // and goes straight to `expand`.
    if (j < text.len and text[j] == '\\') {
        const body = j + 1;
        j = escapedEnd(text, body);
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

    // Conditionals run even inside an inactive arm, because they nest.
    switch (kind) {
        .ifdef, .ifndef, .elsif, .@"else", .endif => return conditional(pp, text, at, j, kind),
        else => {}, // else: the line-oriented directives, below
    }

    // Everything else dies with the arm it sits in. A directive with no
    // operand (IEEE 1364 §19.1, §19.6, §19.10) is its word alone; the rest
    // take their operands to the end of the line.
    const end = switch (kind) {
        .celldefine, .endcelldefine, .nounconnected_drive, .resetall => j,
        else => logicalLineEnd(text, j), // else: every other directive reads its operand from the rest of the line
    };
    if (!pp.emitting()) {
        try pp.putNewlines(text[at..end]);
        return end;
    }
    switch (kind) {
        .define => try pp_macro.handleDefine(pp, text[j..end], at, j),
        .undef => try pp_macro.removeDefine(pp, text[j..end], at, j),
        .include => try pp_directive.handleInclude(pp, text[j..end], at, j),
        .resetall => {
            // IEEE 1364 §19.3: "The text macro facility is not affected by the
            // compiler directive `resetall." Macros are left alone.
            // §10.2 opens its reset sentence with "In addition to `resetall",
            // which makes the global reset the second way to withdraw the
            // default discipline. An empty `discipline` is that withdrawal.
            try pp.defaults.append(pp.arena, .{
                .at = @intCast(pp.out.items.len),
                .qualifier = null,
                .discipline = "",
            });
            // IEEE 1364 §19.6: `resetall returns every directive to its default.
            // `timescale's is "none specified", which §9.15 reads as not known.
            try pp.mark(&pp.timescale_events, null);
            // Events, not cleared lists: a mid-file `resetall must not unsay
            // what earlier directives did to the text above it.
            try pp.mark(&pp.nettypes, NetType.default);
            try pp.mark(&pp.cells, false);
            try pp.mark(&pp.drives, Drive.default);
            // §10.3's default is "controlled by the simulator": no directive.
            try pp.mark(&pp.transitions, null);
            // IEEE 1364 §19.6: "It shall be illegal for the `resetall directive
            // to be specified within a module or UDP declaration." Only the
            // parser knows where a module is, so the word is passed through,
            // like §10.6's pair below, for it to judge.
            try pp.out.appendSlice(pp.arena, text[at..j]);
            return j;
        },
        .default_discipline => try pp_directive.handleDefaultDiscipline(pp, text[j..end], j),
        .default_transition => try pp_directive.handleDefaultTransition(pp, text[j..end], j),
        .line => try pp_directive.handleLine(pp, text[j..end], at, j),
        .timescale => try pp_directive.handleTimescale(pp, text[j..end], j),
        // Applied here, and the word passed through, as `resetall's is, for
        // the parser to refuse inside a module (IEEE 1364 §19.2, §19.9).
        .default_nettype, .unconnected_drive, .nounconnected_drive => {
            switch (kind) {
                .default_nettype => try pp_directive.handleDefaultNettype(pp, text[j..end], j),
                .unconnected_drive => try pp_directive.handleUnconnectedDrive(pp, text[j..end], j),
                else => try pp.mark(&pp.drives, .float), // else: `nounconnected_drive, the one other arm of this prong
            }
            try pp.out.appendSlice(pp.arena, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        // IEEE 1364 §19.1's pair takes no operand.
        .celldefine => try pp.mark(&pp.cells, true),
        .endcelldefine => try pp.mark(&pp.cells, false),
        // `protect` is not unrecognized: IEEE 1364 §28 reserves it, and §28.2
        // obliges decryption that VerA does not do.
        .pragma => {
            var r: Rest = .{ .s = text[j..end] };
            const pragma_name = r.ident() orelse return pp.fail(pp.spanAt(at, j), .E0147, "", .{});
            if (std.mem.eql(u8, pragma_name, "protect"))
                return pp.fail(pp.spanAt(at, j), .E0146, "", .{});
        },
        // §10.6: passed through instead of being blanked out, so the lexer and
        // parser see it. The slice carries its own newlines, so the
        // line-number contract in the file header holds unchanged.
        .keywords => {
            try pp.out.appendSlice(pp.arena, text[at..end]);
            return end;
        },
        .ifdef, .ifndef, .elsif, .@"else", .endif => unreachable, // returned above
    }
    try pp.putNewlines(text[at..end]);
    return end;
}

/// `ifdef / `ifndef / `elsif / `else / `endif (IEEE 1364 §19.4).
fn conditional(pp: *Pp, text: []const u8, at: usize, after_name: usize, kind: Directive) Error!usize {
    // The operand, if any, is on the directive's line; the text after it is
    // ordinary source (IEEE 1364 §19.4 Syntax 19-5 has no line break).
    var r: Rest = .{ .s = text[after_name..logicalLineEnd(text, after_name)] };
    // The directive word itself: `ifdef, `else, ...
    const sp = pp.spanAt(at, after_name);

    switch (kind) {
        .ifdef, .ifndef => {
            // The operand is a text_macro_identifier (Syntax 10-3), simple or
            // escaped (A.9.3), so `` `ifdef \M-X `` tests what
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
    const end = after_name + r.i;
    try pp.putNewlines(text[at..end]);
    return end;
}

// §10.4 `define, `undef and macro expansion (pp/macro.zig).
const pp_macro = @import("pp/macro.zig");

// `include (IEEE 1364 §19.5), §10.2/§10.3 defaults and the IEEE 1364 §19
// directives with operands (pp/directive.zig).
const pp_directive = @import("pp/directive.zig");

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Returns the index of the closing quote, an unescaped newline, or EOF;
/// `start` is the opening quote.
pub fn stringStop(text: []const u8, start: usize) usize {
    // ponytail: the lexer and `substitute` have their own string scans. The
    // lexer rejects escaped newlines and `substitute` crosses bare ones; share
    // one scan only if those rules converge.
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
    /// Returns the next §2.8.1 escaped identifier, skipping leading white
    /// space, or null without consuming anything but that space. Neither
    /// the backslash nor the terminating white space is part of the name, so
    /// the macro is keyed on the same bytes a `` `\name `` use produces.
    pub fn escapedIdent(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or r.s[r.i] != '\\') return null;
        const start = r.i + 1;
        const k = escapedEnd(r.s, start);
        if (k == start) return null;
        r.i = k;
        return r.s[start..k];
    }
    /// Returns the next identifier (§2.8), skipping leading white space.
    pub fn ident(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or !isIdentStart(r.s[r.i])) return null;
        const start = r.i;
        while (r.i < r.s.len and isIdentChar(r.s[r.i])) r.i += 1;
        return r.s[start..r.i];
    }
};

/// Returns the end of the logical line at `i`: the next unescaped newline, or EOF.
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

/// Returns the index of the first element of `haystack` equal to `needle`.
pub fn indexOfString(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |s, k| {
        if (std.mem.eql(u8, s, needle)) return k;
    }
    return null;
}

pub const isSpace = @import("lexer.zig").isSpace;
pub const isIdentChar = @import("lexer.zig").isIdentChar;
pub const escapedEnd = @import("lexer.zig").escapedEnd;
pub fn isIdentStart(c: u8) bool {
    // ponytail: stdlib ASCII classes; `_` and `$` are Verilog's extensions.
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

// Annex D standard definition files (pp/annex_d.zig).
const pp_annex_d = @import("pp/annex_d.zig");

// Annex E Table E.1 SPICE primitives as modules (pp/annex_e.zig).
const pp_annex_e = @import("pp/annex_e.zig");
pub const spice_primitives = pp_annex_e.spice_primitives;
pub const spice_module_count = pp_annex_e.spice_module_count;

// Preprocessor tests (pp/test.zig).
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
