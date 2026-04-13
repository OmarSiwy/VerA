//! The bag: every diagnostic of one compilation, collected, deduplicated and sorted.
//!
//! In: `err`/`warn`/`note` calls from every stage. Out: an ordered entry table; one run
//! reports many errors.
//!
//! Cut verbatim from `diag.zig`. Functions take `self: *diag` and are called
//! directly, `diag_bag.f(self, ...)`; `diag.zig` aliases only what other modules call.

const std = @import("std");
const diag = @import("../diag.zig");
const diag_entry = @import("entry.zig");
const diag_location = @import("location.zig");
const Allocator = diag.Allocator;
const Code = diag.Code;
const Severity = diag.Severity;
const severityOf = diag.severityOf;
const Levels = diag.Levels;

// ---------------------------------------------------------------------------
// The bag
// ---------------------------------------------------------------------------

/// Stop after this many entries in one run. A single broken expression
/// otherwise reports a cascade that buries the first, real error.
pub const max_entries: u32 = 64;

/// Every diagnostic of one compilation, in Zig's two-pool wire format.
///
/// A BUILDER, NOT A FROZEN BUNDLE. Zig splits the two: `ErrorBundle.Wip`
/// accumulates and `toOwnedBundle` freezes (ErrorBundle.zig:337, :370). It has
/// to — a `Compilation` merges bundles from several threads and stores them
/// across incremental updates. A `Bag` is appended to across stages 1–6 of one
/// compilation and then read by exactly one consumer, the renderer below, so a
/// second frozen type would be a shim that only ever wrapped the same two
/// slices. This IS the Wip, and it is read in place the way `Wip.tmpBundle`
/// (ErrorBundle.zig:406) reads one. `detach` is our `toOwnedBundle`: it does
/// not change the shape, only who owns the bytes.
pub const Bag = struct {
    arena: Allocator,
    /// Every diagnostic string, NUL-terminated: headlines, caret text, label
    /// text, note bodies, fix replacements. Byte 0 is a sentinel NUL so that
    /// `String` 0 can mean "none" (ErrorBundle.zig:353).
    string_bytes: std.ArrayList(u8) = .empty,
    /// `Message` records, each followed by its `LabelRec`s and `NoteRec`s.
    extra: std.ArrayList(u32) = .empty,
    /// One handle per diagnostic, in emission order until `sort` reorders it.
    /// Zig keeps the same list (`Wip.root_list`, ErrorBundle.zig:342) and
    /// appends it to `extra` when it freezes; we never freeze, so it stays.
    /// Sorting now moves 4-byte handles instead of 56-byte rows.
    list: std.ArrayList(diag_entry.MessageIndex) = .empty,
    levels: Levels = .empty,
    /// Every file that took part in the compilation, in the order the
    /// preprocessor opened them. `FileId` indexes this.
    ///
    /// It lives on the Bag rather than inside `SourceMap` because BOTH
    /// provenance paths need it: a lower/parse/proof span is an offset in the
    /// preprocessed text and reaches a file through `map`, while a preprocess
    /// span is ALREADY a file-local offset (the preprocessor fails before an
    /// output text exists) and names its file directly via `Entry.file`.
    ///
    /// NOT IN THE POOLS, deliberately. A `File.text` is the whole source —
    /// hundreds of kilobytes for a foundry model — BORROWED from the arena and
    /// re-pointed by `setStrippedText` once comments are stripped. Interning it
    /// into `string_bytes` would copy every byte of every file on the path
    /// where no diagnostic is ever produced, to save one `dupe` in `detach`.
    /// Zig dodges the question by interning only the single `source_line` it
    /// renders (ErrorBundle.zig:64); our renderer draws several lines per
    /// diagnostic plus a patched fix line, so it needs the text itself.
    files: std.ArrayList(diag_location.File) = .empty,
    /// Preprocessed offset → file. Empty until the preprocessor splices
    /// something, which is exactly when it means "offsets are source offsets".
    map: diag_location.SourceMap = .empty,

    /// Dropped because the cap was reached — reported as a trailer so a
    /// truncated run never looks like a complete one.
    suppressed: u32 = 0,
    /// Dropped because an identical (code, span) was already present.
    deduped: u32 = 0,
    err_count: u32 = 0,
    warn_count: u32 = 0,

    /// (code, span.start) pairs already emitted. Lazily created: a clean
    /// compilation never allocates it.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(arena: Allocator) Bag {
        return .{ .arena = arena };
    }

    // -- the string pool ----------------------------------------------------

    /// Zig writes the sentinel NUL in `Wip.init` (ErrorBundle.zig:353). We
    /// cannot: `Bag.init` is infallible on purpose, and a compilation that
    /// reports nothing must not allocate. The first string written pays for it
    /// instead — same invariant, still nothing on the happy path.
    fn addString(self: *Bag, s: []const u8) Allocator.Error!diag_entry.String {
        if (self.string_bytes.items.len == 0)
            try self.string_bytes.append(self.arena, 0);
        const index: diag_entry.String = @intCast(self.string_bytes.items.len);
        try self.string_bytes.ensureUnusedCapacity(self.arena, s.len + 1);
        self.string_bytes.appendSliceAssumeCapacity(s);
        self.string_bytes.appendAssumeCapacity(0);
        return index;
    }

    /// Formats straight into the pool. This is where the old
    /// `std.fmt.allocPrint` per message, per label and per note went.
    fn printString(self: *Bag, comptime fmt: []const u8, args: anytype) Allocator.Error!diag_entry.String {
        if (self.string_bytes.items.len == 0)
            try self.string_bytes.append(self.arena, 0);
        const index: diag_entry.String = @intCast(self.string_bytes.items.len);
        try self.string_bytes.print(self.arena, fmt, args);
        try self.string_bytes.append(self.arena, 0);
        return index;
    }

    /// `String` → bytes. 0 is "none" and decodes to the empty string, which is
    /// also what the renderer wants: an absent `point` and an empty one print
    /// the same. `ErrorBundle.nullTerminatedString` (ErrorBundle.zig:150).
    pub fn str(self: *const Bag, index: diag_entry.String) []const u8 {
        if (index == 0) return "";
        const bytes = self.string_bytes.items;
        const end = std.mem.indexOfScalarPos(u8, bytes, index, 0) orelse bytes.len;
        return bytes[index..end];
    }

    // -- the extra pool -----------------------------------------------------

    /// One word per field, in declaration order. `ErrorBundle.Wip.addExtra`
    /// (ErrorBundle.zig:728), widened to any u32-sized field type so a packed
    /// `Head` rides along with the plain offsets.
    fn addExtra(self: *Bag, rec: anytype) Allocator.Error!u32 {
        const fields = @typeInfo(@TypeOf(rec)).@"struct".fields;
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.ensureUnusedCapacity(self.arena, fields.len);
        inline for (fields) |f| self.extra.appendAssumeCapacity(diag_entry.toWord(@field(rec, f.name)));
        return index;
    }

    /// The record at `index`, plus the index just past it — where its trailing
    /// records begin. `ErrorBundle.extraData` (ErrorBundle.zig:130).
    fn extraData(self: *const Bag, comptime T: type, index: u32) struct { data: T, end: u32 } {
        var i = index;
        var out: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            @field(out, f.name) = diag_entry.fromWord(f.type, self.extra.items[i]);
            i += 1;
        }
        return .{ .data = out, .end = i };
    }

    // -- reading ------------------------------------------------------------

    /// Every diagnostic, in `sort` order once `sort` has run.
    /// `ErrorBundle.getMessages` (ErrorBundle.zig:104).
    pub fn messages(self: *const Bag) []const diag_entry.MessageIndex {
        return self.list.items;
    }

    pub fn count(self: *const Bag) usize {
        return self.list.items.len;
    }

    /// Decode one diagnostic. `ErrorBundle.getErrorMessage`
    /// (ErrorBundle.zig:109).
    pub fn get(self: *const Bag, mi: diag_entry.MessageIndex) diag_entry.Entry {
        const m = self.extraData(diag_entry.Message, @intFromEnum(mi)).data;
        return .{
            .index = mi,
            .code = m.head.code,
            .severity = m.head.severity,
            .stage = m.head.stage,
            .span = .{ .start = m.span_start, .end = m.span_end },
            .file = if (m.src_file == 0) null else @enumFromInt(m.src_file - 1),
            .message = self.str(m.msg),
            .point = self.str(m.point),
            .n_labels = m.counts.labels_len,
            .n_notes = m.counts.notes_len,
        };
    }

    /// The i'th diagnostic in list order.
    pub fn at(self: *const Bag, i: usize) diag_entry.Entry {
        return self.get(self.list.items[i]);
    }

    /// Decodes into `buf` rather than allocating: `max_children` is a hard cap
    /// the `Builder` enforces, so the caller's array is always big enough.
    pub fn labels(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Label) []const diag_entry.Label {
        var i = @intFromEnum(e.index) + diag_entry.wordCount(diag_entry.Message);
        for (buf[0..e.n_labels]) |*out| {
            const r = self.extraData(diag_entry.LabelRec, i);
            i = r.end;
            out.* = .{
                .span = .{ .start = r.data.span_start, .end = r.data.span_end },
                .text = self.str(r.data.text),
            };
        }
        return buf[0..e.n_labels];
    }

    /// `ErrorBundle.getNotes` (ErrorBundle.zig:118) — except the notes are the
    /// records themselves, sitting after the labels rather than behind an
    /// index each.
    pub fn notes(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Note) []const diag_entry.Note {
        var i = @intFromEnum(e.index) + diag_entry.wordCount(diag_entry.Message) + e.n_labels * diag_entry.wordCount(diag_entry.LabelRec);
        for (buf[0..e.n_notes]) |*out| {
            const r = self.extraData(diag_entry.NoteRec, i);
            i = r.end;
            out.* = .{
                .kind = r.data.kind,
                .text = self.str(r.data.text),
                .fix = if (r.data.fix_repl == 0) null else .{
                    .span = .{ .start = r.data.fix_start, .end = r.data.fix_end },
                    .replacement = self.str(r.data.fix_repl),
                },
            };
        }
        return buf[0..e.n_notes];
    }

    /// Register a file and get the id that names it. The FIRST file
    /// registered is `.root`, so the preprocessor must open the top-level
    /// compilation unit before any `include.
    pub fn addFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!diag_location.FileId {
        const id: diag_location.FileId = @enumFromInt(@as(u16, @intCast(self.files.items.len)));
        try self.files.append(self.arena, .{ .name = name, .text = text });
        return id;
    }

    /// Point an already-registered file at its comment-STRIPPED bytes — what
    /// every span from here on indexes. The registered ORIGINAL is kept and
    /// `marks` maps stripped offsets back into it, so the renderer can print
    /// the line the user WROTE with the caret still under the right column.
    pub fn setStrippedText(self: *Bag, id: diag_location.FileId, stripped: []const u8, marks: []const diag_location.StripMark) void {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return;
        const f = &self.files.items[i];
        f.raw = f.text;
        f.text = stripped;
        f.to_src = marks;
    }

    pub fn fileName(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return "<source>";
        return self.files.items[i].name;
    }

    pub fn fileText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return "";
        return self.files.items[i].text;
    }

    /// What RENDERING shows: the file as the user wrote it, comments and all.
    /// Falls back to `text` for a file nothing was stripped from.
    pub fn sourceText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return "";
        const f = self.files.items[i];
        return if (f.raw.len != 0) f.raw else f.text;
    }

    pub fn fileMarks(self: *const Bag, id: diag_location.FileId) []const diag_location.StripMark {
        const i = @intFromEnum(id);
        if (i >= self.files.items.len) return &.{};
        return self.files.items[i].to_src;
    }

    /// Span-currency (stripped) offset → offset in `sourceText`. Identity when
    /// nothing was stripped from `id`.
    pub fn toSourceOffset(self: *const Bag, id: diag_location.FileId, off: u32) u32 {
        const marks = self.fileMarks(id);
        if (marks.len == 0 or off < marks[0].out) return off;
        // Last mark with out <= off; linear from there (see `StripMark`).
        var lo: usize = 0;
        var hi: usize = marks.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (marks[mid].out <= off) lo = mid else hi = mid;
        }
        return marks[lo].src + (off - marks[lo].out);
    }

    /// The no-include, no-macro case: spans index straight into `text`.
    pub fn setSingleFile(
        self: *Bag,
        name: []const u8,
        text: []const u8,
        prelude_lines: u32,
    ) Allocator.Error!void {
        _ = try self.addFile(name, text);
        self.map = .{ .segs = &.{}, .prelude_lines = prelude_lines };
    }

    /// Where a span really points. `Entry.file` short-circuits the segment
    /// search for a preprocess diagnostic, whose offset is file-local already.
    pub fn locate(self: *const Bag, span: diag_location.Span, file: ?diag_location.FileId) diag_location.SourceMap.Resolved {
        if (file) |f| return .{ .file = f, .offset = span.start, .seg = diag_location.Segment.no_parent };
        return self.map.resolve(span.start);
    }

    /// Did anything at `deny`/`forbid` level land? This, not `entries.len`, is
    /// what decides whether the compilation failed — a bag holding only
    /// warnings is a successful compilation.
    pub fn failed(self: *const Bag) bool {
        return self.err_count != 0;
    }

    pub fn isEmpty(self: *const Bag) bool {
        return self.list.items.len == 0;
    }

    /// Would a diagnostic with this code be collected at all? Stages call it
    /// to skip building an expensive message for an allowed lint.
    pub fn enabled(self: *const Bag, c: Code) bool {
        return self.levels.get(c) != .allow;
    }

    /// Start one diagnostic. See `Builder`.
    pub fn build(self: *Bag, stage: diag_entry.Stage, c: Code, span: diag_location.Span) Builder {
        return .{ .bag = self, .stage = stage, .code = c, .span = span };
    }

    /// The whole diagnostic in one call, for the common case with no labels
    /// and no notes.
    pub fn add(
        self: *Bag,
        stage: diag_entry.Stage,
        c: Code,
        span: diag_location.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        var b = self.build(stage, c, span);
        b.msg(fmt, args);
        return b.emit();
    }

    /// Deep-copy every borrowed byte into `gpa`, so the bag outlives the
    /// compilation arena. Our `Wip.toOwnedBundle` (ErrorBundle.zig:370),
    /// except that the shape does not change — only the owner.
    ///
    /// THE OWNERSHIP BOUNDARY. During compilation the bag allocates from the
    /// per-compilation arena — no frees, no bookkeeping, and the file texts are
    /// borrowed rather than copied. But a failed compilation frees its arena on
    /// the way out and the caller still wants to render, so exactly one place
    /// pays for a copy: here.
    ///
    /// The diagnostics themselves are now three `appendSlice`s, because the
    /// pools hold no pointers: there is nothing to fix up after the copy. What
    /// is left is the provenance sidecar — file names, file texts and the
    /// macro names in `map.segs` — which is borrowed and does need duping.
    ///
    /// An EMPTY bag is detached too, provenance and all. It used to drop the
    /// borrowed tables and return, on the grounds that a bag with no messages
    /// can never need to render one — which stopped being true when codegen
    /// became a diagnostic-producing stage (E0515): that runs after `detach`,
    /// and a model whose only diagnostic is a codegen one would have rendered
    /// with no file text and therefore no source snippet. The cost is one copy
    /// of the source per clean compile, which is what every compile that emits
    /// a single warning already paid.
    ///
    /// After this the bag must be released with `deinit(gpa)`. On
    /// `OutOfMemory` nothing is allocated and the bag is unchanged, still on
    /// its arena.
    pub fn detach(self: *Bag, gpa: Allocator) Allocator.Error!void {
        var string_bytes: std.ArrayList(u8) = .empty;
        errdefer string_bytes.deinit(gpa);
        try string_bytes.appendSlice(gpa, self.string_bytes.items);
        var extra: std.ArrayList(u32) = .empty;
        errdefer extra.deinit(gpa);
        try extra.appendSlice(gpa, self.extra.items);
        var list: std.ArrayList(diag_entry.MessageIndex) = .empty;
        errdefer list.deinit(gpa);
        try list.appendSlice(gpa, self.list.items);

        var files: std.ArrayList(diag_location.File) = .empty;
        errdefer files.deinit(gpa);
        try files.appendSlice(gpa, self.files.items);
        var files_done: usize = 0;
        errdefer for (files.items[0..files_done]) |f| {
            gpa.free(f.name);
            gpa.free(f.text);
            gpa.free(f.raw);
            gpa.free(f.to_src);
        };
        for (files.items) |*f| {
            const name = try gpa.dupe(u8, f.name);
            errdefer gpa.free(name);
            const text = try gpa.dupe(u8, f.text);
            errdefer gpa.free(text);
            const raw = try gpa.dupe(u8, f.raw);
            errdefer gpa.free(raw);
            f.to_src = try gpa.dupe(diag_location.StripMark, f.to_src);
            f.name = name;
            f.text = text;
            f.raw = raw;
            files_done += 1;
        }

        const segs = try gpa.dupe(diag_location.Segment, self.map.segs);
        errdefer gpa.free(segs);
        var segs_done: usize = 0;
        errdefer for (segs[0..segs_done]) |sg| gpa.free(sg.macro);
        for (segs) |*sg| {
            sg.macro = try gpa.dupe(u8, sg.macro);
            segs_done += 1;
        }

        self.string_bytes = string_bytes;
        self.extra = extra;
        self.list = list;
        self.files = files;
        self.map = .{ .segs = segs, .prelude_lines = self.map.prelude_lines };
        // The dedupe set was arena memory and has done its job.
        self.seen = .empty;
        self.arena = gpa;
    }

    /// Release a bag that has been through `detach`. A bag that never was is
    /// freed with its arena instead — do not call this on one.
    pub fn deinit(self: *Bag, gpa: Allocator) void {
        for (self.files.items) |f| {
            gpa.free(f.name);
            gpa.free(f.text);
            gpa.free(f.raw);
            gpa.free(f.to_src);
        }
        for (self.map.segs) |sg| gpa.free(sg.macro);
        gpa.free(self.map.segs);
        self.string_bytes.deinit(gpa);
        self.extra.deinit(gpa);
        self.list.deinit(gpa);
        self.files.deinit(gpa);
        // `detach` emptied the dedupe set and moved the bag onto `gpa`, so
        // anything in it now was allocated by a POST-detach `emit` — a codegen
        // diagnostic. Empty for every bag that never took one.
        self.seen.deinit(gpa);
        // NOT `levels`: it is CONFIGURATION the caller owns and copied in
        // (`bag.levels = opts.lint`). Freeing it here double-frees the
        // caller's list the moment it deinits its own.
        self.* = .{ .arena = gpa };
    }

    /// Source order, then code, so a run's output is stable and diffable no
    /// matter which stage produced what. Stages already run in order, but a
    /// proof error can precede a lower error in the text.
    ///
    /// Only `list` moves — the records stay where they were written, so a
    /// `MessageIndex` handed out before a sort is still valid after one.
    pub fn sort(self: *Bag) void {
        std.mem.sort(diag_entry.MessageIndex, self.list.items, @as(*const Bag, self), lessThan);
    }

    fn lessThan(self: *const Bag, a: diag_entry.MessageIndex, b: diag_entry.MessageIndex) bool {
        const x = self.extraData(diag_entry.Message, @intFromEnum(a)).data;
        const y = self.extraData(diag_entry.Message, @intFromEnum(b)).data;
        if (x.span_start != y.span_start) return x.span_start < y.span_start;
        if (x.span_end != y.span_end) return x.span_end < y.span_end;
        return @intFromEnum(x.head.code) < @intFromEnum(y.head.code);
    }
};

/// Accumulates one diagnostic's parts, then commits.
///
/// Methods return void rather than `*Builder`, and an allocation failure is
/// latched in `oom` instead of propagating: chaining `try` through a fluent
/// interface in Zig reads worse than it builds. `emit` is the only fallible
/// call.
///
/// Text is interned into the bag's pool AS IT IS BUILT, so nothing here is a
/// pointer: the builder holds `String` indices and the records it will commit.
/// A diagnostic that is then dropped (allowed, deduped, over the cap) leaves
/// its strings behind in the pool — exactly as the old code left its
/// `allocPrint`s on the arena.
/// ponytail: no rollback index. The cap bounds the waste at a few kilobytes of
/// arena on a run that is already failing; add a mark-and-truncate in `emit`
/// if a bag ever outlives its compilation for long enough to matter.
///
/// Labels and notes live in fixed inline arrays — more than `max_children` of
/// either is not clearer for it, and this keeps the builder from touching
/// `extra` until it commits.
pub const Builder = struct {
    bag: *Bag,
    stage: diag_entry.Stage,
    code: Code,
    span: diag_location.Span,
    file: ?diag_location.FileId = null,
    message: diag_entry.String = 0,
    point_text: diag_entry.String = 0,
    labels: [diag_entry.max_children]diag_entry.LabelRec = undefined,
    n_labels: u16 = 0,
    notes: [diag_entry.max_children]diag_entry.NoteRec = undefined,
    n_notes: u16 = 0,
    oom: bool = false,

    pub fn msg(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.message = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
    }

    /// Preprocessor only: this diagnostic's offsets are inside `id`'s own
    /// text, not inside the preprocessed output. See `Entry.file`.
    pub fn inFile(self: *Builder, id: diag_location.FileId) void {
        self.file = id;
    }

    /// Short text beside the PRIMARY caret. Use it when the caret needs to say
    /// something the headline does not — otherwise leave it unset.
    pub fn point(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.point_text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
    }

    pub fn label(self: *Builder, span: diag_location.Span, comptime fmt: []const u8, args: anytype) void {
        if (self.n_labels == self.labels.len) return;
        const text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
        self.labels[self.n_labels] = .{
            .span_start = span.start,
            .span_end = span.end,
            .text = text,
        };
        self.n_labels += 1;
    }

    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// A help line WITH a machine-applicable rewrite. The renderer shows the
    /// patched line under the help text.
    pub fn suggest(
        self: *Builder,
        fix: diag_entry.Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// The did-you-mean shape: rewrite the PRIMARY span. Every "unknown name"
    /// diagnostic has it — the misspelled identifier is exactly what the caret
    /// is already under — so the alternative is thirteen call sites each
    /// restating `.span = b.span`, and one of them eventually getting it wrong.
    pub fn suggestHere(self: *Builder, replacement: []const u8) void {
        self.suggest(
            .{ .span = self.span, .replacement = replacement },
            "did you mean `{s}`?",
            .{replacement},
        );
    }

    fn pushNote(
        self: *Builder,
        kind: diag_entry.Note.Kind,
        fix: ?diag_entry.Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (self.n_notes == self.notes.len) return;
        const text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
        // `addString`, not 0, even for an empty replacement: 0 is what says
        // "no fix", and a fix that replaces a span with nothing is a deletion.
        const repl: diag_entry.String = if (fix) |f| self.bag.addString(f.replacement) catch {
            self.oom = true;
            return;
        } else 0;
        self.notes[self.n_notes] = .{
            .kind = kind,
            .text = text,
            .fix_repl = repl,
            .fix_start = if (fix) |f| f.span.start else 0,
            .fix_end = if (fix) |f| f.span.end else 0,
        };
        self.n_notes += 1;
    }

    /// Commit. Honours the lint level, the cap and the dedupe set; a dropped
    /// diagnostic is counted, never silent.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.oom) return error.OutOfMemory;
        const bag = self.bag;

        const level = bag.levels.get(self.code);
        if (level == .allow) return;

        if (bag.list.items.len >= max_entries) {
            bag.suppressed += 1;
            return;
        }

        const key = (@as(u64, @intFromEnum(self.code)) << 32) | self.span.start;
        const gop = try bag.seen.getOrPut(bag.arena, key);
        if (gop.found_existing) {
            bag.deduped += 1;
            return;
        }

        const severity: Severity = switch (level) {
            .allow => unreachable,
            .warn => severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        // The message header first, then its trailing records: the reader
        // walks them by stride from the header, so the order is the format.
        const mi: diag_entry.MessageIndex = @enumFromInt(try bag.addExtra(diag_entry.Message{
            .head = .{ .code = self.code, .severity = severity, .stage = self.stage },
            .counts = .{ .labels_len = self.n_labels, .notes_len = self.n_notes },
            .msg = self.message,
            .point = self.point_text,
            .src_file = if (self.file) |f| @as(u32, @intFromEnum(f)) + 1 else 0,
            .span_start = self.span.start,
            .span_end = self.span.end,
        }));
        for (self.labels[0..self.n_labels]) |l| _ = try bag.addExtra(l);
        for (self.notes[0..self.n_notes]) |n| _ = try bag.addExtra(n);
        try bag.list.append(bag.arena, mi);

        switch (severity) {
            .err => bag.err_count += 1,
            .warning => bag.warn_count += 1,
        }
    }
};

// ---------------------------------------------------------------------------
// "did you mean"
// ---------------------------------------------------------------------------

/// Optimal string alignment distance (Damerau-Levenshtein restricted to
/// adjacent transpositions), capped at `limit` so a hopeless pair exits early.
///
/// Bounded stack, no allocation: names longer than this are not the ones a
/// typo suggestion helps with.
///
/// The rows are `u8` because the `cap` guard three lines down is the proof: an
/// edit distance never exceeds the longer input, so no cell can exceed 64, and
/// the widest intermediate any `@min` sees is `cell + 1 == 65`. Three `usize`
/// rows were 1.5 KB of frame for a value that fits in a byte — and the rotation
/// was two 520-byte struct copies per input character. Rotating three pointers
/// over one `[3][cap + 1]u8` is 195 bytes and no copy at all.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    const cap = 64;
    if (a.len > cap or b.len > cap) return limit + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    var rows: [3][cap + 1]u8 = undefined;
    var prev2: *[cap + 1]u8 = &rows[0];
    var prev: *[cap + 1]u8 = &rows[1];
    var cur: *[cap + 1]u8 = &rows[2];

    for (0..b.len + 1) |j| prev[j] = @intCast(j);

    for (a, 0..) |ca, i| {
        cur[0] = @intCast(i + 1);
        var row_min = cur[0];
        for (b, 0..) |cb, j| {
            const cost: u8 = if (ca == cb) 0 else 1;
            var v = @min(
                @min(cur[j] + 1, prev[j + 1] + 1),
                prev[j] + cost,
            );
            if (i > 0 and j > 0 and ca == b[j - 1] and a[i - 1] == cb)
                v = @min(v, prev2[j - 1] + 1);
            cur[j + 1] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return limit + 1;
        // `cur` takes over the row nobody reads again, so the three never alias.
        const spent = prev2;
        prev2 = prev;
        prev = cur;
        cur = spent;
    }
    return prev[b.len];
}

/// Nearest candidate to `name`, or null when nothing is close enough.
///
/// DETERMINISM: callers feed this from `StringHashMap` iterators, whose order
/// is unspecified. Ties therefore break on the NAME, lexicographically — never
/// on "whichever the iterator yielded first", which would make the same source
/// produce different suggestions across runs and the fixture suite flaky.
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var n: Nearest = .init(name);
    for (candidates) |c| n.offer(c);
    return n.best;
}

/// `didYouMean` over the keys of any `StringHashMapUnmanaged`, which is the
/// shape every symbol table in lower.zig has.
///
/// It streams the iterator. The version before this one collected the keys into
/// the arena first, and its comment said that was needed "so the deterministic
/// tie-break sees every candidate" — but `Nearest` is a running minimum of the
/// pair `(distance, name)`, which is a total order, so it sees every candidate
/// either way and the answer cannot depend on arrival order. The test below
/// ("ties break lexicographically, not by input order") is that claim, asserted.
/// The collect was one arena allocation per emitted suggestion for nothing.
pub fn didYouMeanMap(name: []const u8, map: anytype) ?[]const u8 {
    var n: Nearest = .init(name);
    var it = map.keyIterator();
    while (it.next()) |k| n.offer(k.*);
    return n.best;
}

/// The running minimum of `(editDistance(name, c), c)` under the lexicographic
/// order on that pair. Order-independent by construction, which is what lets the
/// map form above avoid materialising the candidate set.
pub const Nearest = struct {
    name: []const u8,
    limit: usize,
    best: ?[]const u8 = null,
    best_d: usize,

    fn init(name: []const u8) Nearest {
        // One edit per three characters, and always at least one, so `vd` still
        // suggests `vds` but `a` suggests nothing.
        const limit = @max(@as(usize, 1), name.len / 3);
        return .{ .name = name, .limit = limit, .best_d = limit + 1 };
    }

    fn offer(self: *Nearest, c: []const u8) void {
        if (std.mem.eql(u8, c, self.name)) return;
        const d = editDistance(self.name, c, self.limit);
        if (d > self.limit) return;
        if (self.best == null or d < self.best_d or
            (d == self.best_d and std.mem.lessThan(u8, c, self.best.?)))
        {
            self.best = c;
            self.best_d = d;
        }
    }
};
