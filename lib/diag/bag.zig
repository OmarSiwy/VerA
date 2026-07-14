//! The bag: every diagnostic of one compilation, collected, deduplicated and
//! sorted. In: `Builder` commits from every stage. Out: an ordered table of
//! `Record` rows whose text lives in one string pool.

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

/// Every diagnostic of one compilation: one `Record` row each, their text in
/// one string pool. Appended to across stages 1–6, then read by the renderer.
pub const Bag = struct {
    arena: Allocator,
    /// Every diagnostic string, NUL-terminated: headlines, caret text, label
    /// text, note bodies, fix replacements. Byte 0 is a sentinel NUL so that
    /// `String` 0 can mean "none".
    string_bytes: std.ArrayList(u8) = .empty,
    /// One row per diagnostic, in emission order until `sort` reorders it.
    records: std.ArrayList(diag_entry.Record) = .empty,
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
    /// NOT IN THE POOL, deliberately. A `File.text` is the whole source —
    /// hundreds of kilobytes for a foundry model — BORROWED from the arena and
    /// re-pointed by `setStrippedText` once comments are stripped. Interning it
    /// into `string_bytes` would copy every byte of every file on the path
    /// where no diagnostic is ever produced, to save one `dupe` in `detach`.
    files: std.ArrayList(diag_location.File) = .empty,
    /// Preprocessed offset → file. Empty until the preprocessor splices
    /// something, which is exactly when it means "offsets are source offsets".
    map: diag_location.SourceMap = .empty,

    /// Dropped because the cap was reached — reported as a trailer so a
    /// truncated run never looks like a complete one.
    suppressed: u32 = 0,
    /// Dropped because an identical (code, file, span.start) was already present.
    deduped: u32 = 0,
    err_count: u32 = 0,
    warn_count: u32 = 0,

    pub fn init(arena: Allocator) Bag {
        return .{ .arena = arena };
    }

    // -- the string pool ----------------------------------------------------

    /// `Bag.init` is infallible and a compilation that reports nothing must
    /// not allocate, so the first string written pays for the sentinel NUL.
    fn addString(self: *Bag, s: []const u8) Allocator.Error!diag_entry.String {
        return self.printString("{s}", .{s});
    }

    /// Formats straight into the pool; see `addString` for the sentinel.
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
    /// the same.
    pub fn str(self: *const Bag, index: diag_entry.String) []const u8 {
        if (index == 0) return "";
        const bytes = self.string_bytes.items;
        const end = std.mem.indexOfScalarPos(u8, bytes, index, 0) orelse bytes.len;
        return bytes[index..end];
    }

    // -- reading ------------------------------------------------------------

    pub fn count(self: *const Bag) usize {
        return self.records.items.len;
    }

    /// The i'th diagnostic, in `sort` order once `sort` has run.
    pub fn at(self: *const Bag, i: usize) diag_entry.Entry {
        const m = self.records.items[i];
        return .{
            .index = @intCast(i),
            .code = m.code,
            .severity = m.severity,
            .stage = m.stage,
            .span = m.span,
            .file = m.file,
            .message = self.str(m.message),
            .point = self.str(m.point),
            .n_labels = m.n_labels,
            .n_notes = m.n_notes,
        };
    }

    /// Returns `e`'s secondary labels, decoded into `buf`; the slice is valid
    /// while `buf` and the bag are. `buf` always fits: `Builder` caps labels at
    /// `max_children`.
    pub fn labels(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Label) []const diag_entry.Label {
        const m = &self.records.items[e.index];
        for (m.labels[0..m.n_labels], buf[0..m.n_labels]) |r, *out|
            out.* = .{ .span = r.span, .text = self.str(r.text) };
        return buf[0..m.n_labels];
    }

    /// Returns `e`'s notes and help lines, decoded into `buf` as `labels` does.
    pub fn notes(self: *const Bag, e: diag_entry.Entry, buf: *[diag_entry.max_children]diag_entry.Note) []const diag_entry.Note {
        const m = &self.records.items[e.index];
        for (m.notes[0..m.n_notes], buf[0..m.n_notes]) |r, *out| out.* = .{
            .kind = r.kind,
            .text = self.str(r.text),
            .fix = if (r.fix_repl == 0) null else .{ .span = r.fix_span, .replacement = self.str(r.fix_repl) },
        };
        return buf[0..m.n_notes];
    }

    /// Registers a file and returns its id. `text` is borrowed, not copied.
    /// The first file registered is `.root`, so the preprocessor must open the
    /// top-level compilation unit before any `include.
    pub fn addFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!diag_location.FileId {
        const id: diag_location.FileId = @fromBackingInt(@intCast(@as(u16, @intCast(self.files.items.len))));
        try self.files.append(self.arena, .{ .name = name, .text = text });
        return id;
    }

    /// Points a registered file at its comment-stripped bytes, which every span
    /// from here on indexes. The original stays for rendering and `marks` maps
    /// stripped offsets back into it. An unknown `id` is ignored.
    pub fn setStrippedText(self: *Bag, id: diag_location.FileId, stripped: []const u8, marks: []const diag_location.StripMark) void {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return;
        const f = &self.files.items[i];
        f.raw = f.text;
        f.text = stripped;
        f.to_src = marks;
    }

    pub fn fileName(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "<source>";
        return self.files.items[i].name;
    }

    pub fn fileText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "";
        return self.files.items[i].text;
    }

    /// What RENDERING shows: the file as the user wrote it, comments and all.
    /// Falls back to `text` for a file nothing was stripped from.
    pub fn sourceText(self: *const Bag, id: diag_location.FileId) []const u8 {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return "";
        const f = self.files.items[i];
        return if (f.raw.len != 0) f.raw else f.text;
    }

    pub fn fileMarks(self: *const Bag, id: diag_location.FileId) []const diag_location.StripMark {
        const i = @backingInt(id);
        if (i >= self.files.items.len) return &.{};
        return self.files.items[i].to_src;
    }

    /// Span-currency (stripped) offset → offset in `sourceText`. Identity when
    /// nothing was stripped from `id`.
    pub fn toSourceOffset(self: *const Bag, id: diag_location.FileId, off: u32) u32 {
        const marks = self.fileMarks(id);
        if (marks.len == 0 or off < marks[0].out) return off;
        // Last mark with out <= off; linear from there (see `StripMark`).
        const lo = std.sort.partitionPoint(diag_location.StripMark, marks, off, struct {
            fn f(o: u32, m: diag_location.StripMark) bool {
                return m.out <= o;
            }
        }.f) - 1;
        return marks[lo].src + (off - marks[lo].out);
    }

    /// The no-include, no-macro case: spans index straight into `text`.
    pub fn setSingleFile(self: *Bag, name: []const u8, text: []const u8) Allocator.Error!void {
        _ = try self.addFile(name, text);
        self.map = .empty;
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
        return self.records.items.len == 0;
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

    /// Deep-copies every arena-owned or borrowed byte (rows, string pool, file
    /// names and texts, macro names) into `gpa`, so the bag outlives the
    /// compilation arena. The caller then owns it and releases it with
    /// `deinit(gpa)`. On `OutOfMemory` nothing is allocated and the bag is
    /// unchanged, still on its arena.
    ///
    /// An empty bag is detached too: codegen runs after this and may still
    /// report (E0515), and its snippet needs the file text.
    pub fn detach(self: *Bag, gpa: Allocator) Allocator.Error!void {
        var string_bytes: std.ArrayList(u8) = .empty;
        errdefer string_bytes.deinit(gpa);
        try string_bytes.appendSlice(gpa, self.string_bytes.items);
        var records: std.ArrayList(diag_entry.Record) = .empty;
        errdefer records.deinit(gpa);
        try records.appendSlice(gpa, self.records.items);

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
        self.records = records;
        self.files = files;
        self.map = .{ .segs = segs };
        self.arena = gpa;
    }

    /// Releases a bag that has been through `detach`. Precondition: detached;
    /// a bag still on its arena is freed with the arena instead.
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
        self.records.deinit(gpa);
        self.files.deinit(gpa);
        // NOT `levels`: it is CONFIGURATION the caller owns and copied in
        // (`bag.levels = opts.lint`). Freeing it here double-frees the
        // caller's list the moment it deinits its own.
        self.* = .{ .arena = gpa };
    }

    /// Source order, then code, so a run's output is stable and diffable no
    /// matter which stage produced what. Stages already run in order, but a
    /// proof error can precede a lower error in the text. Invalidates every
    /// `Entry.index` taken before it.
    pub fn sort(self: *Bag) void {
        std.mem.sort(diag_entry.Record, self.records.items, {}, lessThan);
    }

    fn lessThan(_: void, x: diag_entry.Record, y: diag_entry.Record) bool {
        if (x.span.start != y.span.start) return x.span.start < y.span.start;
        if (x.span.end != y.span.end) return x.span.end < y.span.end;
        return @backingInt(x.code) < @backingInt(y.code);
    }
};

/// Accumulates one diagnostic's parts, then commits with `emit`.
///
/// Methods return void: an allocation failure is latched in `oom` and reported
/// by `emit`, the only fallible call. Text is interned into the bag's pool as
/// it is built. Labels and notes beyond `max_children` are dropped.
pub const Builder = struct {
    // ponytail: no rollback index. A dropped diagnostic (allowed, deduped,
    // over the cap) leaves its strings in the pool; the cap bounds the waste.
    // Add a mark-and-truncate in `emit` if a bag outlives its compilation.
    bag: *Bag,
    stage: diag_entry.Stage,
    code: Code,
    span: diag_location.Span,
    file: ?diag_location.FileId = null,
    message: diag_entry.String = 0,
    point_text: diag_entry.String = 0,
    labels: [diag_entry.max_children]diag_entry.LabelRec = undefined,
    n_labels: u8 = 0,
    notes: [diag_entry.max_children]diag_entry.NoteRec = undefined,
    n_notes: u8 = 0,
    oom: bool = false,

    /// Sets the headline printed after `Info.title`.
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

    /// Adds a secondary span with its own text.
    pub fn label(self: *Builder, span: diag_location.Span, comptime fmt: []const u8, args: anytype) void {
        if (self.n_labels == self.labels.len) return;
        const text = self.bag.printString(fmt, args) catch {
            self.oom = true;
            return;
        };
        self.labels[self.n_labels] = .{ .span = span, .text = text };
        self.n_labels += 1;
    }

    pub fn note(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.note, null, fmt, args);
    }

    pub fn help(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        self.pushNote(.help, null, fmt, args);
    }

    /// Adds a help line with a machine-applicable rewrite. The renderer shows the
    /// patched line under the help text.
    pub fn suggest(
        self: *Builder,
        fix: diag_entry.Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.pushNote(.help, fix, fmt, args);
    }

    /// Adds a help line that rewrites the primary span, the did-you-mean shape
    /// of every "unknown name" diagnostic.
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
            .fix_span = if (fix) |f| f.span else .{ .start = 0, .end = 0 },
        };
        self.n_notes += 1;
    }

    /// Commits the diagnostic. Honours the lint level, the cap and the dedupe
    /// set; a dropped diagnostic is counted, never silent. Returns
    /// `OutOfMemory` if any earlier builder call failed to allocate.
    pub fn emit(self: *Builder) Allocator.Error!void {
        if (self.oom) return error.OutOfMemory;
        const bag = self.bag;

        const level = bag.levels.get(self.code);
        if (level == .allow) return;

        if (bag.records.items.len >= max_entries) {
            bag.suppressed += 1;
            return;
        }

        // `file` is in the key because a preprocessor span is file-local.
        // ponytail: linear scan, bounded by `max_entries`.
        for (bag.records.items) |m| {
            if (m.code == self.code and m.span.start == self.span.start and m.file == self.file) {
                bag.deduped += 1;
                return;
            }
        }

        const severity: Severity = switch (level) {
            .allow => unreachable,
            .warn => severityOf(self.code),
            // `--deny=W0650` promotes the warning to a hard error.
            .deny, .forbid => .err,
        };

        try bag.records.append(bag.arena, .{
            .code = self.code,
            .severity = severity,
            .stage = self.stage,
            .file = self.file,
            .span = self.span,
            .message = self.message,
            .point = self.point_text,
            .n_labels = self.n_labels,
            .n_notes = self.n_notes,
            .labels = self.labels,
            .notes = self.notes,
        });

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
/// No allocation: names longer than `cap` are not the ones a typo suggestion
/// helps with.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    const cap = 64;
    if (a.len > cap or b.len > cap) return limit + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > b.len + limit or b.len > a.len + limit) return limit + 1;

    // `u8` cells: an edit distance never exceeds the longer input (<= cap), so
    // the widest intermediate any `@min` sees is cap + 1.
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

/// Returns the candidate nearest to `name`, or null when nothing is close
/// enough. Ties break on the name, lexicographically, so the answer does not
/// depend on candidate order (callers often feed hash-map iterators).
pub fn didYouMean(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var n: Nearest = .init(name);
    for (candidates) |c| n.offer(c);
    return n.best;
}

/// `didYouMean` over the keys of any `StringHashMapUnmanaged`, streamed
/// without allocating.
pub fn didYouMeanMap(name: []const u8, map: anytype) ?[]const u8 {
    var n: Nearest = .init(name);
    var it = map.keyIterator();
    while (it.next()) |k| n.offer(k.*);
    return n.best;
}

/// The running minimum of `(editDistance(name, c), c)` under the lexicographic
/// order on that pair. Order-independent by construction, which is what lets the
/// map form above avoid materialising the candidate set.
const Nearest = struct {
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
